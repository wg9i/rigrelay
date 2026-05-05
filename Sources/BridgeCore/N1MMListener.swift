import Foundation
import Network

/// Listens on a UDP multicast group for N1MM / RUMLogNG RadioInfo XML broadcasts.
public actor N1MMListener {

    public private(set) var state: ConnectionState = .disconnected
    public var onStateChange: (@Sendable (ConnectionState) -> Void)?
    public var onRadioInfo: (@Sendable (RadioInfo) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "n1mm-udp", qos: .userInitiated)

    public init() {}

    // MARK: - Lifecycle

    public func start(host: String, port: Int) async throws {
        stop()

        // NWListener for UDP
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        // Join multicast group if address starts with 224. or 239. etc.
        let isMulticast = host.hasPrefix("224.") || host.hasPrefix("239.")
        if isMulticast {
            // NWListener automatically handles multicast join when we bind to the group address
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port))
            )
        } else {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host == "0.0.0.0" ? "::" : host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port))
            )
        }

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task {
                await self.handleListenerState(newState)
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { await self.handleConnection(conn) }
        }

        listener.start(queue: queue)

        // Wait for ready
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if case .connected = state { return }
            if case .failed = state   { throw NSError(domain: "N1MMListener", code: 1, userInfo: [NSLocalizedDescriptionKey: state.label]) }
        }
    }

    private func handleListenerState(_ s: NWListener.State) {
        switch s {
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

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveData(from: conn)
    }

    private func receiveData(from conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty, let info = RadioInfoParser.parse(data) {
                Task { await self.dispatchRadioInfo(info) }
            }
            if error == nil {
                Task { await self.receiveData(from: conn) }
            }
        }
    }

    private func dispatchRadioInfo(_ info: RadioInfo) {
        onRadioInfo?(info)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        state = .disconnected
        onStateChange?(.disconnected)
    }
}
