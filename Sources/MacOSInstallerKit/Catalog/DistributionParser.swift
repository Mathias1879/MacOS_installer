import Foundation

public struct DistributionInfo: Equatable, Sendable {
    public let title: String
    public let version: OSVersion
    public let build: String
}

public enum DistributionParseError: Error, Equatable {
    case malformedXML(String)
    case missingTitle
    case missingVersion
    case missingBuild
    case unparsableVersion(String)
}

/// Reads Apple's `.dist` files. These are `installer-gui-script` XML documents
/// carrying a `<title>` and an `<auxinfo>` dictionary with VERSION and BUILD.
public enum DistributionParser {
    public static func parse(_ data: Data) throws -> DistributionInfo {
        let delegate = DistributionXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw DistributionParseError.malformedXML(reason)
        }

        guard let title = delegate.title, !title.isEmpty else {
            throw DistributionParseError.missingTitle
        }
        guard let versionString = delegate.auxInfo["VERSION"] else {
            throw DistributionParseError.missingVersion
        }
        guard let build = delegate.auxInfo["BUILD"] else {
            throw DistributionParseError.missingBuild
        }
        guard let version = OSVersion(versionString) else {
            throw DistributionParseError.unparsableVersion(versionString)
        }

        return DistributionInfo(title: title, version: version, build: build)
    }
}

/// Collects `<title>` and the flat `<auxinfo>` key/string pairs. The auxinfo
/// dict is plist-shaped: alternating `<key>` and `<string>` elements.
private final class DistributionXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var title: String?
    private(set) var auxInfo: [String: String] = [:]

    private var inAuxInfo = false
    private var buffer = ""
    private var pendingKey: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        buffer = ""
        if elementName == "auxinfo" { inAuxInfo = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "title" where !inAuxInfo:
            if title == nil { title = text }
        case "auxinfo":
            inAuxInfo = false
        case "key" where inAuxInfo:
            pendingKey = text
        case "string" where inAuxInfo:
            if let key = pendingKey {
                auxInfo[key] = text
                pendingKey = nil
            }
        case "dict":
            break
        default:
            // An unexpected element type inside auxinfo must not leave a key
            // dangling to be mis-paired with a later <string>.
            if inAuxInfo { pendingKey = nil }
        }

        buffer = ""
    }
}
