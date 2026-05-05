import Foundation
import Network

/// Connection state for UI binding.
public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    public var label: String {
        switch self {
        case .disconnected:   return "Disconnected"
        case .connecting:     return "Connecting…"
        case .connected:      return "Connected"
        case .failed(let e):  return "Error: \(e)"
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// TCP client that speaks the DXLab Commander wire protocol.
/// Commands look like:  <command:N>CmdName<parameters:N><key:N>value...
public actor CommanderClient {

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "commander-tcp", qos: .userInitiated)
    private let queryQueue = DispatchQueue(label: "commander-queries", qos: .userInitiated) // Serial queue for queries

    public private(set) var state: ConnectionState = .disconnected

    // Callback so the BridgeEngine can publish state changes.
    public var onStateChange: (@Sendable (ConnectionState) -> Void)?

    // Callback so BridgeEngine can receive debug log lines.
    public var onLog: (@Sendable (String) async -> Void)?

    public init() {}

    // MARK: - Connection lifecycle

    public func connect(host: String, port: Int) async {
        disconnect()
        state = .connecting
        onStateChange?(.connecting)

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 10  // seconds before giving up
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task {
                await self.handleStateUpdate(newState)
            }
        }
        conn.start(queue: queue)

        // Wait up to 12 s (TCP timeout is 10 s, small buffer for state propagation)
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            if case .connected = state { return }
            if case .failed = state   { return }
        }
    }

    private func handleStateUpdate(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            state = .connected
            onStateChange?(.connected)
        case .failed(let err):
            let msg = err.localizedDescription
            state = .failed(msg)
            onStateChange?(.failed(msg))
        case .cancelled:
            state = .disconnected
            onStateChange?(.disconnected)
        default:
            break
        }
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        state = .disconnected
        onStateChange?(.disconnected)
    }

    // MARK: - Command sending

    /// Sends a command to Commander and does not wait for a response.
    /// Use this for all set-style commands (CmdSetFreqMode, CmdSendMode, CmdTX, CmdRX, etc.)
    /// Commander does not send a response to these commands.
    @discardableResult
    public func send(_ command: String, params: [String: String] = [:]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queryQueue.async {
                Task {
                    do {
                        let result = try await self.performSend(command: command, params: params)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func performSend(command: String, params: [String: String]) async throws -> String {
        guard let conn = connection, case .connected = state else {
            throw CommanderError.notConnected
        }

        let message = buildMessage(command: command, params: params)
        guard let data = message.data(using: .utf8) else {
            throw CommanderError.encodingError
        }

        await onLog?("Commander ← \(command)\(formatParams(params))")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { sendError in
                if let e = sendError {
                    continuation.resume(throwing: CommanderError.sendFailed(e.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
        return ""
    }

    /// Sends a command to Commander and accumulates the response until the
    /// connection delivers a complete ADIF field, then returns the field value.
    public func query(_ command: String, params: [String: String] = [:]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queryQueue.async {
                Task {
                    do {
                        let result = try await self.performQuery(command: command, params: params)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func performQuery(command: String, params: [String: String]) async throws -> String {
        guard let conn = connection, case .connected = state else {
            throw CommanderError.notConnected
        }

        let message = buildMessage(command: command, params: params)
        guard let data = message.data(using: .utf8) else {
            throw CommanderError.encodingError
        }

        if !receiveBuffer.isEmpty {
            await onLog?("Commander buffer before query: \(receiveBuffer.count) bytes")
        }
        await onLog?("Commander ← \(command)\(formatParams(params))")

        // Send, then accumulate response bytes until we can parse a complete ADIF field.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { sendError in
                if let e = sendError {
                    continuation.resume(throwing: CommanderError.sendFailed(e.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }

        let value = try await accumulate(conn: conn)
        await onLog?("Commander → \(command): \(value)")
        if !receiveBuffer.isEmpty {
            await onLog?("Commander leftover buffer after parse: \(receiveBuffer.count) bytes")
        }
        return value
    }

    private func receiveChunk(from conn: NWConnection) async throws -> Data? {
        return try await withCheckedThrowingContinuation { continuation in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, _, error in
                if let e = error {
                    continuation.resume(throwing: CommanderError.receiveFailed(e.localizedDescription))
                    return
                }
                continuation.resume(returning: content)
            }
        }
    }

    /// Receives chunks until a complete ADIF field can be parsed and preserves any leftover bytes.
    private func accumulate(conn: NWConnection) async throws -> String {
        while true {
            if let raw = String(data: receiveBuffer, encoding: .utf8),
               let parsed = self.parseAdifValue(raw) {
                receiveBuffer.removeFirst(parsed.consumedBytes)
                return parsed.value
            }
            let content = try await receiveChunk(from: conn)
            if let data = content {
                await onLog?("Commander received \(data.count) bytes")
                receiveBuffer.append(data)
            }
        }
    }

    // MARK: - Typed Commander queries

    /// Query RX frequency via CmdGetFreq. Returns Hz as Int64.
    /// Response format: <CmdFreq:N>14,010.500  (kHz, comma thousands sep)
    public func queryRxFreqHz() async throws -> Int64 {
        let raw = try await query("CmdGetFreq")
        return try parseFreqKHz(raw)
    }

    /// Query TX frequency via CmdGetTXFreq. Returns Hz as Int64.
    public func queryTxFreqHz() async throws -> Int64 {
        let raw = try await query("CmdGetTXFreq")
        return try parseFreqKHz(raw)
    }

    /// Query mode via CmdSendMode. Returns the mode string e.g. "CW".
    public func queryMode() async throws -> String {
        return try await query("CmdSendMode")
    }

    /// Query split state via CmdSendSplit. Returns true if ON.
    public func querySplit() async throws -> Bool {
        let raw = try await query("CmdSendSplit")
        return raw.uppercased() == "ON"
    }

    // MARK: - ADIF response parsing

    private func buildMessage(command: String, params: [String: String]) -> String {
        var paramBlock = ""
        for (key, value) in params {
            paramBlock += "<\(key):\(value.utf8.count)>\(value)"
        }
        var message = "<command:\(command.utf8.count)>\(command)"
        message += "<parameters:\(paramBlock.utf8.count)>\(paramBlock)"
        return message + "\r\n"
    }

    private func formatParams(_ params: [String: String]) -> String {
        guard !params.isEmpty else { return "" }
        return " " + params.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
    }

    /// Parse a single ADIF field of the form <FieldName:Length>Value and return the parsed value plus the number of bytes consumed.
    private nonisolated func parseAdifValue(_ response: String) -> (value: String, consumedBytes: Int)? {
        // Match <Name:N> then read exactly N characters.
        guard let tagEnd = response.firstIndex(of: ">") else { return nil }
        let tag = response[response.startIndex...tagEnd]          // e.g. "<CmdFreq:10>"
        guard let colonIdx = tag.lastIndex(of: ":") else { return nil }
        let lenStr = String(tag[tag.index(after: colonIdx)..<tagEnd])
        guard let len = Int(lenStr) else { return nil }
        let valueStart = response.index(after: tagEnd)
        guard response.distance(from: valueStart, to: response.endIndex) >= len else { return nil }
        let valueEnd = response.index(valueStart, offsetBy: len)
        let value = String(response[valueStart..<valueEnd])
        let consumedBytes = response.distance(from: response.startIndex, to: valueEnd)
        return (value, consumedBytes)
    }

    /// Parse a kHz frequency string with comma thousands separators into Hz.
    /// e.g. "14,010.500" → 14_010_500
    private func parseFreqKHz(_ raw: String) throws -> Int64 {
        // Strip thousands separators and parse as Double kHz.
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        guard let kHz = Double(cleaned) else {
            throw CommanderError.parseError("Invalid frequency: \(raw)")
        }
        return Int64((kHz * 1000).rounded())
    }

    // MARK: - Convenience helpers

    public func setFreqMode(freqKHz: Double, mode: String) async throws {
        try await send("CmdSetFreqMode", params: [
            "xcvrfreq": String(format: "%.2f", freqKHz),
            "xcvrmode": mode,
            "preservesplitanddual": "N"
        ])
    }

    public func setMode(_ mode: String) async throws {
        try await send("CmdSendMode", params: ["1": mode])
    }

    public func setPTT(transmit: Bool) async throws {
        try await send(transmit ? "CmdTX" : "CmdRX")
    }
}

public enum CommanderError: Error, LocalizedError {
    case notConnected
    case encodingError
    case sendFailed(String)
    case receiveFailed(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:        return "Not connected to Commander"
        case .encodingError:       return "Failed to encode command"
        case .sendFailed(let m):   return "Send failed: \(m)"
        case .receiveFailed(let m):return "Receive failed: \(m)"
        case .parseError(let m):   return "Parse error: \(m)"
        }
    }
}
