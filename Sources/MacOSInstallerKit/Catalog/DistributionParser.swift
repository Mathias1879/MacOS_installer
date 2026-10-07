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
/// Modern files use literal titles; legacy files use localization keys like SU_TITLE.
public enum DistributionParser {
    public static func parse(_ data: Data) throws -> DistributionInfo {
        let delegate = DistributionXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw DistributionParseError.malformedXML(reason)
        }

        // Resolve title: if it's a localization key, look it up; otherwise use as-is.
        var title = delegate.title ?? ""
        if isLocalizationKey(title) {
            guard let resolved = delegate.localizationStrings[title] else {
                throw DistributionParseError.missingTitle
            }
            title = resolved
        }

        guard !title.isEmpty else {
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

    private static func isLocalizationKey(_ key: String) -> Bool {
        key.range(of: "^SU_[A-Z0-9_]+$", options: .regularExpression) != nil
    }
}

/// Collects `<title>`, `<auxinfo>` key/string pairs, and localization strings.
/// The auxinfo dict is plist-shaped: alternating `<key>` and `<string>` elements.
/// Localization strings are in `<strings language="English">` blocks in the form `"KEY" = "value";`.
private final class DistributionXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var title: String?
    private(set) var auxInfo: [String: String] = [:]
    private(set) var localizationStrings: [String: String] = [:]

    private var inAuxInfo = false
    private var inLocalizationStrings = false
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
        if elementName == "auxinfo" {
            inAuxInfo = true
        } else if elementName == "strings" && attributes["language"] == "English" {
            inLocalizationStrings = true
        }
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

        // Parse localization strings BEFORE closing the element
        if inLocalizationStrings && elementName == "strings" {
            parseLocalizationStrings(buffer)
        }

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
        case "strings":
            inLocalizationStrings = false
        case "dict":
            break
        default:
            // An unexpected element type inside auxinfo must not leave a key
            // dangling to be mis-paired with a later <string>.
            if inAuxInfo { pendingKey = nil }
        }

        buffer = ""
    }

    private func parseLocalizationStrings(_ content: String) {
        // Split by semicolons to find individual entries
        let entries = content.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        for entry in entries {
            // Look for pattern: "KEY" = "value"
            if let keyStart = entry.firstIndex(of: "\""),
               let keyEnd = entry[entry.index(after: keyStart)...].firstIndex(of: "\""),
               let eqIndex = entry[entry.index(after: keyEnd)...].firstIndex(of: "="),
               let valStart = entry[entry.index(after: eqIndex)...].firstIndex(of: "\""),
               let valEnd = entry[entry.index(after: valStart)...].firstIndex(of: "\"") {
                let key = String(entry[entry.index(after: keyStart)..<keyEnd])
                let value = String(entry[entry.index(after: valStart)..<valEnd])
                localizationStrings[key] = value
            }
        }
    }
}
