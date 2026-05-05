import Foundation

/// Parsed N1MM / RUMLogNG RadioInfo UDP broadcast.
public struct RadioInfo: Sendable {
    public var freq: String = ""        // dezahertz (daHz) — multiply × 10 for Hz
    public var txFreq: String = ""
    public var mode: String = ""
    public var isTransmitting: String = "" // "True" / "False"

    public init() {}

    /// Receive frequency in Hz, or nil if unavailable.
    public var freqHz: Int64? {
        guard let daHz = Int64(freq) else { return nil }
        return daHz * 10
    }

    /// TX frequency in Hz, or nil if unavailable.
    public var txFreqHz: Int64? {
        guard let daHz = Int64(txFreq) else { return nil }
        return daHz * 10
    }

    public var transmitting: Bool {
        isTransmitting.lowercased() == "true"
    }
}

/// SAX-style XML parser for RadioInfo packets.
public final class RadioInfoParser: NSObject, XMLParserDelegate {
    private var result = RadioInfo()
    private var currentElement = ""
    private var currentValue = ""

    public static func parse(_ data: Data) -> RadioInfo? {
        let p = RadioInfoParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        guard parser.parse() else { return nil }
        // Only accept if the root was RadioInfo
        return p.seenRoot ? p.result : nil
    }

    private var seenRoot = false

    public func parser(_ parser: XMLParser,
                       didStartElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?,
                       attributes attributeDict: [String: String] = [:]) {
        if elementName == "RadioInfo" { seenRoot = true }
        currentElement = elementName
        currentValue = ""
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    public func parser(_ parser: XMLParser,
                       didEndElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?) {
        let v = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Freq":           result.freq = v
        case "TXFreq":         result.txFreq = v
        case "Mode":           result.mode = v
        case "IsTransmitting": result.isTransmitting = v
        default: break
        }
    }
}
