import AppKit
import Foundation
import Combine

/// Log entry for the console view.
public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let message: String
    public let level: Level

    public enum Level: Sendable { case info, debug, warning, error }

    public init(_ message: String, level: Level = .info) {
        self.timestamp = Date()
        self.message = message
        self.level = level
    }
}

public enum LogFilter: String, CaseIterable, Sendable {
    case all             = "All"
    case infoAndAbove    = "Info+"
    case warningsAndErrors = "Warnings"

    public func matches(_ level: LogEntry.Level) -> Bool {
        switch self {
        case .all:              return true
        case .infoAndAbove:     return level != .debug
        case .warningsAndErrors: return level == .warning || level == .error
        }
    }
}

/// Central coordinator: owns the Commander client, N1MM listener, and XML-RPC server.
/// Published properties drive the SwiftUI status UI.
@MainActor
public final class BridgeEngine: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isRunning = false
    @Published public private(set) var commanderState: ConnectionState = .disconnected
    @Published public private(set) var n1mmState: ConnectionState = .disconnected
    @Published public private(set) var serverState: ConnectionState = .disconnected
    @Published public private(set) var xmlRpcClientCount: Int = 0
    @Published public private(set) var lastRadioInfo = RadioInfo()
    @Published public private(set) var pttTransmitting: Bool = false
    @Published public private(set) var logEntries: [LogEntry] = []

    private static let bandwidthValues = [
        "50", "100", "150", "200", "250", "300", "350", "400", "450", "500",
        "600", "700", "800", "900", "1000", "1100", "1200", "1300", "1400", "1500",
        "1600", "1700", "1800", "1900", "2000", "2100", "2200", "2300", "2400", "2500",
        "2600", "2700", "2800", "2900", "3000", "3100", "3200", "3300", "3400", "3500",
        "3600"
    ]

    private static var bandwidthOptions: [String] {
        ["Bandwidth"] + bandwidthValues
    }

    // TX mode tracked locally — Commander has no query command for it.
    // Defaults to nil (follows RX mode) until explicitly set via set_modeB.
    private var txMode: String? = nil

    private var commanderRetryTask: Task<Void, Never>?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    // MARK: - Components

    private let commander = CommanderClient()
    private let n1mmListener = N1MMListener()
    private let xmlRpcServer = XmlRpcServer()

    public let config: BridgeConfig

    public init(config: BridgeConfig) {
        self.config = config
    }

    // MARK: - Start / Stop

    public func start() async {
        guard !isRunning else { return }
        log("Starting bridge…")

        isRunning = true

        // Wire up state callbacks
        await commander.setOnStateChange { [weak self] s in
            Task { @MainActor [weak self] in
                self?.commanderState = s
                await self?.handleCommanderStateChange(s)
            }
        }
        await commander.setOnLog { [weak self] message in
            guard let self else { return }
            await self.debugLog(message)
        }
        await n1mmListener.setOnStateChange { [weak self] s in
            Task { @MainActor [weak self] in self?.n1mmState = s }
        }
        await n1mmListener.setOnRadioInfo { [weak self] info in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Log changes from N1MM
                if info.freqHz != self.lastRadioInfo.freqHz {
                    self.log("N1MM: RX frequency → \(info.freqHz ?? 0) Hz", level: .info)
                }
                if info.txFreqHz != self.lastRadioInfo.txFreqHz {
                    self.log("N1MM: TX frequency → \(info.txFreqHz ?? 0) Hz", level: .info)
                }
                if info.mode != self.lastRadioInfo.mode {
                    self.log("N1MM: Mode → \(info.mode)", level: .info)
                }
                if info.transmitting != self.pttTransmitting {
                    self.log("N1MM: PTT → \(info.transmitting ? "ON" : "OFF")", level: .info)
                }

                let merged = await self.mergeN1MMRadioInfo(info)
                self.lastRadioInfo = merged
                self.pttTransmitting = info.transmitting
                self.debugLog("N1MM: \(merged.freq) daHz, mode=\(merged.mode), tx=\(info.isTransmitting)")
            }
        }
        await xmlRpcServer.setOnStateChange { [weak self] s in
            Task { @MainActor [weak self] in self?.serverState = s }
        }
        await xmlRpcServer.setOnClientCountChange { [weak self] count in
            Task { @MainActor [weak self] in
                self?.xmlRpcClientCount = count
            }
        }
        await xmlRpcServer.setOnClientConnected { [weak self] ip in
            Task { @MainActor [weak self] in
                self?.log("flrig client connected: \(ip)")
            }
        }
        await xmlRpcServer.setOnClientDisconnected { [weak self] ip in
            Task { @MainActor [weak self] in
                self?.log("flrig client disconnected: \(ip)")
            }
        }

        // Wire XML-RPC handler — hop to MainActor for each call so we can
        // access @MainActor-isolated state (lastRadioInfo, config, commander).
        await xmlRpcServer.setHandleRequest { [weak self] methodName, params in
            guard let self else { throw BridgeError.noData("engine deallocated") }
            return try await self.handleXmlRpc(method: methodName, params: params)
        }

        // Connect Commander (state-change callback handles XML-RPC server start)
        log("Connecting to Commander at \(config.commanderHost):\(config.commanderPort)…")
        await commander.connect(host: config.commanderHost, port: config.commanderPort)

        // Periodically reconnect Commander if the connection drops
        commanderRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.isRunning, !Task.isCancelled else { return }
                let s = await self.commander.state
                guard case .connected = s else {
                    await MainActor.run { self.log("Retrying Commander connection…", level: .warning) }
                    await self.commander.connect(host: self.config.commanderHost, port: self.config.commanderPort)
                    continue
                }
            }
        }

        // Start N1MM listener
        log("Starting N1MM listener on \(config.n1mmHost):\(config.n1mmPort)…")
        do {
            try await n1mmListener.start(host: config.n1mmHost, port: config.n1mmPort)
            log("N1MM listener active ✓")
        } catch {
            log("N1MM listener failed: \(error.localizedDescription)", level: .error)
        }

        // Observe sleep/wake so NWListener instances are cleanly torn down before
        // sleep and restarted after wake. Without this, listeners silently stop
        // accepting connections after a sleep/wake cycle.
        let ws = NSWorkspace.shared.notificationCenter
        sleepObserver = ws.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.handleSystemSleep() }
        }
        wakeObserver = ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.handleSystemWake() }
        }

    }

    public func stop() async {
        guard isRunning else { return }
        log("Stopping bridge…")
        commanderRetryTask?.cancel()
        commanderRetryTask = nil
        let ws = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver { ws.removeObserver(obs); sleepObserver = nil }
        if let obs = wakeObserver  { ws.removeObserver(obs); wakeObserver = nil }
        await commander.disconnect()
        await n1mmListener.stop()
        await xmlRpcServer.stop()
        xmlRpcClientCount = 0
        isRunning = false
        log("Bridge stopped.")
    }

    // MARK: - Commander state management

    private func handleCommanderStateChange(_ s: ConnectionState) async {
        switch s {
        case .connected:
            if case .connected = serverState { return }
            log("Commander connected ✓ — starting XML-RPC server on \(config.flrigHost):\(config.flrigPort)…")
            do {
                try await xmlRpcServer.start(host: config.flrigHost, port: config.flrigPort)
                log("XML-RPC server listening on \(config.flrigHost):\(config.flrigPort) ✓")
            } catch {
                log("XML-RPC server failed: \(error.localizedDescription)", level: .error)
            }
        case .disconnected, .failed:
            if case .disconnected = serverState { return }
            // Set synchronously before the await so that a .connected callback
            // dispatched concurrently cannot see stale .connected state.
            serverState = .disconnected
            log("Commander disconnected — dropping XML-RPC clients and stopping server", level: .warning)
            await xmlRpcServer.stop()
        case .connecting:
            break
        }
    }

    // MARK: - Sleep / wake

    private func handleSystemSleep() async {
        guard isRunning else { return }
        // Cancel all NWListener/NWConnection objects before the OS drops the network.
        // isRunning stays true so the wake handler knows to restart.
        serverState = .disconnected
        await xmlRpcServer.stop()
        n1mmState = .disconnected
        await n1mmListener.stop()
        commanderState = .disconnected
        await commander.disconnect()
        log("Network listeners stopped for system sleep.", level: .warning)
    }

    private func handleSystemWake() async {
        guard isRunning else { return }
        log("System resumed from sleep — restarting connections…", level: .warning)
        // Brief pause to let macOS fully restore the network stack before binding.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard isRunning else { return }
        log("Connecting to Commander at \(config.commanderHost):\(config.commanderPort)…")
        await commander.connect(host: config.commanderHost, port: config.commanderPort)
        do {
            try await n1mmListener.start(host: config.n1mmHost, port: config.n1mmPort)
            log("N1MM listener active ✓")
        } catch {
            log("N1MM listener restart failed: \(error.localizedDescription)", level: .error)
        }
        // XML-RPC server is restarted by handleCommanderStateChange(.connected).
    }

    // MARK: - XML-RPC dispatch

    private func handleXmlRpc(method: String, params: [String]) async throws -> String {
        debugLog("XML-RPC ← \(method)(\(params.joined(separator: ", ")))")

        let result: String
        do {
            result = try await dispatch(method: method, params: params)
        } catch BridgeError.unknownMethod(let m) {
            log("XML-RPC ← \(m) — unrecognized method", level: .warning)
            throw BridgeError.unknownMethod(m)
        } catch {
            debugLog("XML-RPC ✗ \(method): \(error.localizedDescription)")
            throw error
        }

        debugLog("XML-RPC → \(method): \(result)")
        return result
    }

    private func dispatch(method: String, params: [String]) async throws -> String {
        switch method {

        case "rig.get_xcvr":
            return config.rigName

        // vfoA = RX frequency, vfoB = TX frequency
        case "rig.get_freq", "rig.get_vfo", "rig.get_vfoA":
            let freq = try await commander.queryRxFreqHz()
            return "\(freq)"

        case "rig.get_vfoB":
            let freq = try await commander.queryTxFreqHz()
            return "\(freq)"

        case "rig.set_freq", "rig.set_vfo", "rig.set_vfoA":
            guard let freqHz = Double(params.first ?? "") else {
                throw BridgeError.badParam("frequency")
            }
            log(String(format: "VFO A → %.2f kHz", freqHz / 1000))
            try await setAndVerifyFrequency(freqHz)
            return ""

        case "rig.set_vfoB":
            guard let freqHz = Double(params.first ?? "") else {
                throw BridgeError.badParam("frequency")
            }
            log(String(format: "VFO B → %.2f kHz", freqHz / 1000))
            if let txMode {
                // A TX mode has been explicitly set — prime QSXMode via CmdSetFreqMode
                // (which sets Commander's QSXMode state variable), then call CmdQSXSplit
                // with SuppressModeChange:N so Commander applies it.
                guard let cmdMode = config.commanderModeMappings[txMode] else {
                    throw BridgeError.unsupportedMode(txMode)
                }
                // Use current RX freq as placeholder — CmdSetFreqMode won't change the
                // rig frequency when we immediately follow with CmdQSXSplit.
                let rxHz = try await commander.queryRxFreqHz()
                try await commander.send("CmdSetFreqMode", params: [
                    "xcvrfreq": String(format: "%.2f", Double(rxHz) / 1000.0),
                    "xcvrmode": cmdMode,
                    "preservesplitanddual": "Y"
                ])
                try await commander.send("CmdQSXSplit", params: [
                    "xcvrfreq": String(format: "%.2f", freqHz / 1000.0),
                    "SuppressDual": "Y",
                    "SuppressModeChange": "N"
                ])
            } else {
                try await commander.send("CmdQSXSplit", params: [
                    "xcvrfreq": String(format: "%.2f", freqHz / 1000.0),
                    "SuppressDual": "Y",
                    "SuppressModeChange": "Y"
                ])
            }
            return ""

        case "rig.set_verify_frequency":
            guard let freqHz = Double(params.first ?? "") else {
                throw BridgeError.badParam("frequency")
            }
            log(String(format: "Freq (verify) → %.2f kHz", freqHz / 1000))
            try await commander.send("CmdSetFreq", params: [
                "xcvrfreq": String(format: "%.2f", freqHz / 1000.0)
            ])
            return ""

        case "rig.get_mode", "rig.get_modeA":
            let cmdMode = try await commander.queryMode()
            guard !cmdMode.isEmpty else { throw BridgeError.noData("mode") }
            return config.modeMappings[cmdMode] ?? cmdMode

        case "rig.get_modeB":
            if let txMode { return txMode }
            // Fall back to RX mode when no TX mode has been set.
            let cmdMode = try await commander.queryMode()
            guard !cmdMode.isEmpty else { throw BridgeError.noData("mode") }
            return config.modeMappings[cmdMode] ?? cmdMode

        case "rig.get_sideband":
            let cmdMode = try await commander.queryMode()
            guard !cmdMode.isEmpty else { throw BridgeError.noData("sideband") }
            let flrigMode = config.modeMappings[cmdMode] ?? cmdMode
            if flrigMode.hasPrefix("LSB") { return "L" }
            if flrigMode.hasPrefix("USB") { return "U" }
            return ""

        case "rig.set_mode", "rig.set_modeA":
            guard let flrigMode = params.first, !flrigMode.isEmpty else {
                // Empty parameter: fetch current mode and re-set it to verify/sync
                let currentCmdMode = try await commander.queryMode()
                guard !currentCmdMode.isEmpty else { throw BridgeError.noData("current mode") }
                log("Mode -> (current: \(currentCmdMode))")
                txMode = nil
                return try await setAndVerifyMode(currentCmdMode)
            }
            guard let cmdMode = config.commanderModeMappings[flrigMode] else {
                throw BridgeError.unsupportedMode(flrigMode)
            }
            log("Mode -> \(flrigMode)")
            txMode = nil
            return try await setAndVerifyMode(cmdMode)

        case "rig.set_modeB":
            guard let flrigMode = params.first else { throw BridgeError.badParam("mode") }
            guard config.commanderModeMappings[flrigMode] != nil else {
                throw BridgeError.unsupportedMode(flrigMode)
            }
            log("Mode B → \(flrigMode)")
            txMode = flrigMode
            return "1"

        case "rig.get_ptt":
            return pttTransmitting ? "1" : "0"

        case "rig.set_ptt":
            let on = params.first == "1"
            try await commander.send(on ? "CmdTX" : "CmdRX")
            pttTransmitting = on
            return "0"

        case "rig.get_modes":
            // Returns a tab-delimited list which XmlRpcServer encodes as an XML-RPC array.
            return Array(config.modeMappings.values).sorted().joined(separator: "\t")

        case "rig.get_split":
            return try await commander.querySplit() ? "1" : "0"

        case "rig.set_split":
            let on = params.first == "1"
            log("Split → \(on ? "on" : "off")")
            try await commander.send("CmdSplit", params: ["1": on ? "on" : "off"])
            return "0"

        case "rig.get_power":
            return "\(config.flrigPower)"

        case "rig.get_pwrmeter":
            return "0"

        case "rig.get_pwrmeter_scale":
            // Returns 1 — the scale factor (1 unit = 1 watt), not the max watts.
            return "1"

        case "rig.get_smeter":
            return "0"

        case "rig.get_DBM":
            // Faked — noise-floor dBm so clients don't display a bogus strong signal.
            return "-120"

        case "rig.get_bw", "rig.get_bwA", "rig.get_bwB":
            // Returns [currentBW, ""] as a tab-delimited array to match flrig behavior.
            // VFO B bandwidth is faked — same value as VFO A.
            return "\(config.flrigBandwidth)\t"

        case "rig.get_bws":
            let options = Self.bandwidthOptions
                .map { "<value>\(XmlRpcServer.xmlEscape($0))</value>" }
                .joined()
            return "<array><data><value><array><data>\(options)</data></array></value></data></array>"

        case "rig.set_bw", "rig.set_bandwidth", "rig.set_bwA", "rig.set_bwB":
            guard let first = params.first else { throw BridgeError.badParam("bandwidth") }
            guard let index = Int(first), index >= 0, index < Self.bandwidthValues.count else {
                throw BridgeError.badParam("bandwidth index")
            }
            config.flrigBandwidth = Self.bandwidthValues[index]
            return "1"

        case "rig.get_notch":
            return config.flrigNotch

        case "rig.set_notch":
            guard let value = params.first else { throw BridgeError.badParam("notch") }
            config.flrigNotch = value
            return "1"

        case "rig.get_AB":
            return "A"

        case "main.get_version":
            return "2.0.10"

        case "system.listMethods":
            return [
                "main.get_version",
                "rig.get_xcvr",
                "rig.get_freq", "rig.get_vfo", "rig.get_vfoA", "rig.get_vfoB",
                "rig.set_freq", "rig.set_vfo", "rig.set_vfoA", "rig.set_vfoB",
                "rig.set_verify_frequency",
                "rig.get_mode", "rig.get_modeA", "rig.get_modeB",
                "rig.set_mode", "rig.set_modeA", "rig.set_modeB",
                "rig.get_ptt", "rig.set_ptt",
                "rig.get_split", "rig.set_split",
                "rig.get_modes", "rig.get_power",
                "rig.get_pwrmeter", "rig.get_pwrmeter_scale",
                "rig.get_smeter",
                "rig.get_DBM",
                "rig.get_bws",
                "rig.get_bw", "rig.set_bw",
                "rig.get_notch", "rig.set_notch",
                "rig.get_sideband",
                "rig.get_bwA", "rig.get_bwB",
                "rig.set_bwA", "rig.set_bwB",
                "rig.set_bandwidth",
                "rig.get_AB",
                "system.listMethods",
            ].joined(separator: "\t")

        default:
            throw BridgeError.unknownMethod(method)
        }
    }

    // MARK: - Mode setting helper

    private func setAndVerifyMode(_ cmdMode: String) async throws -> String {
        try await commander.send("CmdSetMode", params: ["1": cmdMode])
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let verifiedMode = try? await commander.queryMode(), verifiedMode == cmdMode { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return "1"
    }

    private func setAndVerifyFrequency(_ freqHz: Double) async throws {
        try await commander.send("CmdSetFreq", params: [
            "xcvrfreq": String(format: "%.2f", freqHz / 1000.0)
        ])
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let verifiedFreq = try? await commander.queryRxFreqHz(), abs(Double(verifiedFreq) - freqHz) < 1 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func mergeN1MMRadioInfo(_ info: RadioInfo) async -> RadioInfo {
        var merged = info
        merged.freq = lastRadioInfo.freq
        merged.mode = lastRadioInfo.mode

        if let rxHz = try? await commander.queryRxFreqHz() {
            merged.freq = "\(rxHz / 10)"
        }

        if let cmdMode = try? await commander.queryMode() {
            merged.mode = config.modeMappings[cmdMode] ?? cmdMode
        }

        return merged
    }

    // MARK: - Logging

    private func log(_ message: String, level: LogEntry.Level = .info) {
        guard config.logFilter.matches(level) else { return }
        let entry = LogEntry(message, level: level)
        logEntries.append(entry)
        if logEntries.count > config.logBufferSize {
            logEntries.removeFirst(logEntries.count - config.logBufferSize)
        }
        if level == .error || level == .warning {
            print("[\(level)] \(message)")
        }
    }

    private func debugLog(_ message: String) {
        guard config.logFilter == .all else { return }
        log(message, level: .debug)
    }

    public func clearLog() {
        logEntries.removeAll()
    }
}

public enum BridgeError: Error, LocalizedError {
    case noData(String)
    case badParam(String)
    case unsupportedMode(String)
    case timeout(String)
    case unknownMethod(String)

    public var errorDescription: String? {
        switch self {
        case .noData(let what):        return "No \(what) data available"
        case .badParam(let what):      return "Invalid \(what) parameter"
        case .unsupportedMode(let m):  return "Unsupported mode: \(m)"
        case .timeout(let what):       return "Timeout during \(what)"
        case .unknownMethod(let m):    return "Unknown XML-RPC method: \(m)"
        }
    }
}

// MARK: - Actor extension helpers (bridge callback wiring)

extension CommanderClient {
    func setOnStateChange(_ cb: @escaping @Sendable (ConnectionState) -> Void) async {
        onStateChange = cb
    }
    func setOnLog(_ cb: @escaping @Sendable (String) async -> Void) async {
        onLog = cb
    }
}
extension N1MMListener {
    func setOnStateChange(_ cb: @escaping @Sendable (ConnectionState) -> Void) async {
        onStateChange = cb
    }
    func setOnRadioInfo(_ cb: @escaping @Sendable (RadioInfo) -> Void) async {
        onRadioInfo = cb
    }
}
extension XmlRpcServer {
    func setOnStateChange(_ cb: @escaping @Sendable (ConnectionState) -> Void) async {
        onStateChange = cb
    }
    func setOnClientCountChange(_ cb: @escaping @Sendable (Int) -> Void) async {
        onClientCountChange = cb
    }
    func setOnClientConnected(_ cb: @escaping @Sendable (String) -> Void) async {
        onClientConnected = cb
    }
    func setOnClientDisconnected(_ cb: @escaping @Sendable (String) -> Void) async {
        onClientDisconnected = cb
    }
    func setHandleRequest(_ cb: @escaping @Sendable (String, [String]) async throws -> String) async {
        handleRequest = cb
    }
}
