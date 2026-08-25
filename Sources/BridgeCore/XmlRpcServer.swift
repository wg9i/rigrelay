import Foundation
import Network

/// Minimal XML-RPC/HTTP server built on NWListener.
///
/// HTTP request framing is handled by accumulating received Data in a
/// per-connection buffer until we have complete headers and the full body
/// indicated by Content-Length. This survives TCP segmentation correctly.
public actor XmlRpcServer {

    public private(set) var state: ConnectionState = .disconnected
    public private(set) var clientCount: Int = 0
    public var onStateChange: (@Sendable (ConnectionState) -> Void)?
    public var onClientCountChange: (@Sendable (Int) -> Void)?
    public var onClientConnected: (@Sendable (String) -> Void)?
    public var onClientDisconnected: (@Sendable (String) -> Void)?
    public var handleRequest: (@Sendable (String, [String]) async throws -> String)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "xmlrpc-server", qos: .userInitiated)
    private var savedHost: String = ""
    private var savedPort: Int = 0
    private var restartTask: Task<Void, Never>?
    private var autoRestartEnabled = false

    public init() {}

    // MARK: - Start / Stop

    public func start(host: String, port: Int) throws {
        savedHost = host
        savedPort = port
        stop()
        autoRestartEnabled = true

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        // Bind to a specific address when one is requested.
        if !host.isEmpty && host != "0.0.0.0" {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port))
            )
        }

        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(port))
        let l = try NWListener(using: params, on: nwPort)
        listener = l

        l.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task { await self.handleListenerState(newState) }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { await self.acceptConnection(conn) }
        }
        l.start(queue: queue)
    }

    public func stop() {
        autoRestartEnabled = false
        restartTask?.cancel()
        restartTask = nil
        listener?.cancel()
        listener = nil
        state = .disconnected
        clientCount = 0
        onStateChange?(.disconnected)
        onClientCountChange?(0)
    }

    // MARK: - Listener state

    private func handleListenerState(_ s: NWListener.State) {
        switch s {
        case .ready:
            state = .connected
            onStateChange?(.connected)
        case .failed(let err):
            let msg = err.localizedDescription
            state = .failed(msg)
            onStateChange?(.failed(msg))
            scheduleRestart()
        case .cancelled:
            state = .disconnected
            onStateChange?(.disconnected)
        default:
            break
        }
    }

    private func scheduleRestart() {
        guard autoRestartEnabled else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.retryStart()
        }
    }

    private func retryStart() {
        guard savedPort != 0 else { return }
        try? start(host: savedHost, port: savedPort)
    }

    // MARK: - Connection handling

    private func acceptConnection(_ conn: NWConnection) {
        let ip = remoteAddress(conn)
        clientCount += 1
        onClientCountChange?(clientCount)
        onClientConnected?(ip)
        conn.stateUpdateHandler = { [weak self] s in
            guard let self, case .cancelled = s else {
                if let self, case .failed = s { Task { await self.connectionDidEnd(ip: ip) } }
                return
            }
            Task { await self.connectionDidEnd(ip: ip) }
        }
        conn.start(queue: queue)
        accumulate(conn: conn, buffer: Data())
    }

    private func connectionDidEnd(ip: String) {
        clientCount = max(0, clientCount - 1)
        onClientCountChange?(clientCount)
        onClientDisconnected?(ip)
    }

    private func remoteAddress(_ conn: NWConnection) -> String {
        if case .hostPort(let host, _) = conn.endpoint {
            return "\(host)"
        }
        return "unknown"
    }

    /// Recursively receives chunks into `buffer` until a complete HTTP request
    /// (headers + Content-Length body) has arrived, then dispatches it.
    private func accumulate(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }

            var buf = buffer
            if let data { buf.append(data) }

            Task { await self.tryDispatch(conn: conn, buffer: buf, isComplete: isComplete, error: error) }
        }
    }

    private func tryDispatch(conn: NWConnection, buffer: Data, isComplete: Bool, error: NWError?) {
        if error != nil { conn.cancel(); return }

        // Locate end of HTTP headers.
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let lflf     = Data([0x0A, 0x0A])

        let headerEnd: Int
        if let r = buffer.range(of: crlfcrlf)  { headerEnd = r.upperBound }
        else if let r = buffer.range(of: lflf) { headerEnd = r.upperBound }
        else {
            if !isComplete { accumulate(conn: conn, buffer: buffer) }
            else { conn.cancel() }
            return
        }

        let headerStr = String(data: buffer[0..<headerEnd], encoding: .utf8) ?? ""

        if let contentLength = parseContentLength(from: headerStr) {
            let bodyEnd = headerEnd + contentLength
            guard buffer.count >= bodyEnd else {
                if !isComplete { accumulate(conn: conn, buffer: buffer) }
                else { conn.cancel() }
                return
            }
            let body = String(data: buffer[headerEnd..<bodyEnd], encoding: .utf8) ?? ""
            // Any bytes beyond this request belong to the next one.
            let remainder = Data(buffer[bodyEnd...])
            Task { await self.processRequest(body: body, conn: conn, remainder: remainder) }
        } else {
            // No Content-Length: accumulate until connection closes, then dispatch.
            if !isComplete { accumulate(conn: conn, buffer: buffer); return }
            let body = String(data: buffer[headerEnd...], encoding: .utf8) ?? ""
            Task { await self.processRequest(body: body, conn: conn, remainder: Data()) }
        }
    }

    private func processRequest(body: String, conn: NWConnection, remainder: Data) async {
        let (methodName, params) = parseXmlRpcRequest(body)

        let responseXml: String
        do {
            if let handler = handleRequest {
                let result = try await handler(methodName, params)
                responseXml = buildXmlRpcResponse(value: result, method: methodName)
            } else {
                responseXml = buildXmlRpcFault(code: -1, message: "Server not ready")
            }
        } catch {
            responseXml = buildXmlRpcFault(code: -32500, message: error.localizedDescription)
        }

        guard let responseData = buildHttpResponse(body: responseXml).data(using: .utf8) else {
            conn.cancel(); return
        }

        conn.send(content: responseData, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { conn.cancel(); return }
            // Loop back to wait for the next request on the same connection.
            Task { await self.accumulate(conn: conn, buffer: remainder) }
        })
    }

    // MARK: - HTTP framing helper

    private func parseContentLength(from headers: String) -> Int? {
        for line in headers.components(separatedBy: "\n") {
            if line.lowercased().hasPrefix("content-length:") {
                return Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }

    // MARK: - XML-RPC parsing

    private func parseXmlRpcRequest(_ xml: String) -> (String, [String]) {
        var methodName = ""
        var params: [String] = []

        if let start = xml.range(of: "<methodName>"),
           let end = xml.range(of: "</methodName>") {
            methodName = String(xml[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var search = xml[xml.startIndex...]
        while let pStart = search.range(of: "<param>"),
              let pEnd = search.range(of: "</param>") {
            let block = String(search[pStart.upperBound..<pEnd.lowerBound])
            if let v = extractValue(from: block) { params.append(v) }
            search = search[pEnd.upperBound...]
        }

        return (methodName, params)
    }

    private func extractValue(from xml: String) -> String? {
        for tag in ["string", "double", "int", "i4", "boolean"] {
            if let s = xml.range(of: "<\(tag)>"),
               let e = xml.range(of: "</\(tag)>") {
                return String(xml[s.upperBound..<e.lowerBound])
            }
        }
        if let s = xml.range(of: "<value>"),
           let e = xml.range(of: "</value>") {
            let inner = String(xml[s.upperBound..<e.lowerBound])
            if !inner.contains("<") {
                return inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    // MARK: - Response builders

    // Methods whose response should be typed as <int> on the wire.
    private static let intMethods: Set<String> = [
        "rig.get_ptt", "rig.set_ptt",
        "rig.set_verify_ptt", "rig.set_ptt_fast",
        "rig.get_split", "rig.set_split", "rig.set_verify_split",
        "rig.get_pwrmeter", "rig.get_pwrmeter_scale",
        "rig.get_notch",
        "rig.get_rfgain", "rig.get_agc", "rig.get_micgain", "rig.get_volume",
        "rig.set_rfgain", "rig.set_verify_rfgain",
        "rig.set_micgain", "rig.set_verify_micgain",
        "rig.set_volume", "rig.set_verify_volume",
        "rig.set_power", "rig.set_verify_power",
        "rig.get_DBM",
        "rig.set_mode", "rig.set_modeA", "rig.set_modeB", "rig.set_bandwidth",
        "rig.set_verify_mode", "rig.set_verify_modeA", "rig.set_verify_modeB",
        "rig.set_bwA", "rig.set_bwB",
        "rig.set_verify_bw", "rig.set_verify_bandwidth",
    ]

    // Methods whose response is an XML-RPC array.
    // The engine returns tab-delimited values for these.
    private static let arrayMethods: Set<String> = [
        "rig.get_bw", "rig.get_bwA", "rig.get_bwB",
        "rig.get_modes",
        "system.listMethods",
    ]

    private func buildXmlRpcResponse(value: String, method: String) -> String {
        let valueContent: String
        if method == "rig.get_bws" {
            valueContent = value
        } else if Self.arrayMethods.contains(method) {
            let items = value.components(separatedBy: "\t")
                .map { "<value>\(XmlRpcServer.xmlEscape($0))</value>" }
                .joined(separator: "\n        ")
            valueContent = "<array><data>\n        \(items)\n      </data></array>"
        } else if Self.intMethods.contains(method) {
            valueContent = "<i4>\(value)</i4>"
        } else {
            valueContent = XmlRpcServer.xmlEscape(value)
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <methodResponse>
          <params>
            <param>
              <value>\(valueContent)</value>
            </param>
          </params>
        </methodResponse>
        """
    }

    private func buildXmlRpcFault(code: Int, message: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <methodResponse>
          <fault>
            <value>
              <struct>
                <member>
                  <n>faultCode</n>
                  <value><int>\(code)</int></value>
                </member>
                <member>
                  <n>faultString</n>
                  <value><string>\(XmlRpcServer.xmlEscape(message))</string></value>
                </member>
              </struct>
            </value>
          </fault>
        </methodResponse>
        """
    }

    private func buildHttpResponse(body: String) -> String {
        let bodyWithCRLF = body + "\r\n"
        return "HTTP/1.1 200 OK\r\nServer: XMLRPC++ 0.8\r\nContent-Type: text/xml\r\nContent-Length: \(bodyWithCRLF.utf8.count)\r\n\r\n\(bodyWithCRLF)"
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
