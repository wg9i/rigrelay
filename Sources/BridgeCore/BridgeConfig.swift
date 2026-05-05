import Foundation
import Combine

/// All configurable parameters for the bridge, persisted via UserDefaults.
public final class BridgeConfig: ObservableObject {

    // MARK: Commander
    @Published public var commanderHost: String {
        didSet { UserDefaults.standard.set(commanderHost, forKey: "commanderHost") }
    }
    @Published public var commanderPort: Int {
        didSet { UserDefaults.standard.set(commanderPort, forKey: "commanderPort") }
    }

    // MARK: N1MM / RUMLogNG UDP
    @Published public var n1mmHost: String {
        didSet { UserDefaults.standard.set(n1mmHost, forKey: "n1mmHost") }
    }
    @Published public var n1mmPort: Int {
        didSet { UserDefaults.standard.set(n1mmPort, forKey: "n1mmPort") }
    }

    // MARK: flrig XML-RPC server
    @Published public var flrigHost: String {
        didSet { UserDefaults.standard.set(flrigHost, forKey: "flrigHost") }
    }
    @Published public var flrigPort: Int {
        didSet { UserDefaults.standard.set(flrigPort, forKey: "flrigPort") }
    }
    @Published public var flrigPower: Int {
        didSet { UserDefaults.standard.set(flrigPower, forKey: "flrigPower") }
    }
    @Published public var flrigBandwidth: String {
        didSet { UserDefaults.standard.set(flrigBandwidth, forKey: "flrigBandwidth") }
    }
    @Published public var flrigNotch: String {
        didSet { UserDefaults.standard.set(flrigNotch, forKey: "flrigNotch") }
    }

    // MARK: Startup
    @Published public var startAtLaunch: Bool {
        didSet { UserDefaults.standard.set(startAtLaunch, forKey: "startAtLaunch") }
    }

    // MARK: Debug logging
    @Published public var logFilter: LogFilter {
        didSet { UserDefaults.standard.set(logFilter.rawValue, forKey: "logFilterLevel") }
    }
    @Published public var logBufferSize: Int {
        didSet { UserDefaults.standard.set(logBufferSize, forKey: "logBufferSize") }
    }

    // MARK: Rig name returned to flrig clients
    @Published public var rigName: String {
        didSet { UserDefaults.standard.set(rigName, forKey: "rigName") }
    }

    // MARK: Mode mappings  (N1MM mode → flrig mode)
    @Published public var modeMappings: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(modeMappings) {
                UserDefaults.standard.set(data, forKey: "modeMappings")
            }
        }
    }

    // MARK: Mode mappings  (flrig mode → Commander mode)
    @Published public var commanderModeMappings: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(commanderModeMappings) {
                UserDefaults.standard.set(data, forKey: "commanderModeMappings")
            }
        }
    }

    public static let defaultN1MMToFlrig: [String: String] = [
        "USB": "USB",
        "LSB": "LSB",
        "CW": "CW",
        "RTTY": "RTTY",
        "CW-R": "CW-R",
        "RTTY-R": "RTTY-R",
        "DATA-U": "USB-D",
        "DATA-L": "LSB-D",
        "AM": "AM",
        "FM": "FM",
    ]

    public static let defaultFlrigToCommander: [String: String] = [
        "USB": "USB",
        "LSB": "LSB",
        "CW": "CW",
        "RTTY": "RTTY",
        "CW-R": "CW-R",
        "RTTY-R": "RTTY-R",
        "USB-D": "DATA-U",
        "LSB-D": "DATA-L",
        "AM": "AM",
        "FM": "FM",
    ]

    public init() {
        let ud = UserDefaults.standard
        commanderHost = ud.string(forKey: "commanderHost") ?? "127.0.0.1"
        commanderPort = ud.integer(forKey: "commanderPort").nonzero ?? 50000
        n1mmHost = ud.string(forKey: "n1mmHost") ?? "0.0.0.0"
        n1mmPort = ud.integer(forKey: "n1mmPort").nonzero ?? 12060
        flrigHost = ud.string(forKey: "flrigHost") ?? "0.0.0.0"
        flrigPort = ud.integer(forKey: "flrigPort").nonzero ?? 12345
        flrigPower = ud.integer(forKey: "flrigPower").nonzero ?? 100
        flrigBandwidth = ud.string(forKey: "flrigBandwidth") ?? "0"
        flrigNotch = ud.string(forKey: "flrigNotch") ?? "0"
        startAtLaunch = ud.object(forKey: "startAtLaunch") as? Bool ?? false
        logFilter = LogFilter(rawValue: ud.string(forKey: "logFilterLevel") ?? "") ?? .all
        logBufferSize = ud.integer(forKey: "logBufferSize").nonzero ?? 1000
        rigName = ud.string(forKey: "rigName") ?? "IC-7300"

        if let data = ud.data(forKey: "modeMappings"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            modeMappings = decoded
        } else {
            modeMappings = BridgeConfig.defaultN1MMToFlrig
        }

        if let data = ud.data(forKey: "commanderModeMappings"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            commanderModeMappings = decoded
        } else {
            commanderModeMappings = BridgeConfig.defaultFlrigToCommander
        }
    }

    public func resetModeMappings() {
        modeMappings = BridgeConfig.defaultN1MMToFlrig
        commanderModeMappings = BridgeConfig.defaultFlrigToCommander
    }
}

private extension Int {
    var nonzero: Int? { self == 0 ? nil : self }
}
