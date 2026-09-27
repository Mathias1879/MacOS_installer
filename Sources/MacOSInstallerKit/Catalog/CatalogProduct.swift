import Foundation

public struct CatalogPackage: Equatable, Sendable {
    public let url: URL
    public let size: Int64
}

public struct CatalogProduct: Equatable, Sendable {
    /// Which assembly path this product's payload implies.
    public enum Kind: Equatable, Sendable {
        case installAssistant
        case legacyESD
        case other
    }

    public let identifier: String
    public let postDate: Date
    public let distributionURL: URL?
    public let packages: [CatalogPackage]

    public var installAssistantURL: URL? {
        packages.first { $0.url.lastPathComponent == "InstallAssistant.pkg" }?.url
    }

    public var legacyESDURLs: [URL] {
        guard kind == .legacyESD else { return [] }
        return packages.map(\.url)
    }

    public var kind: Kind {
        if packages.contains(where: { $0.url.lastPathComponent == "InstallAssistant.pkg" }) {
            return .installAssistant
        }
        if packages.contains(where: { $0.url.lastPathComponent == "InstallESDDmg.pkg" }) {
            return .legacyESD
        }
        return .other
    }

    public var totalSize: Int64 {
        switch kind {
        case .installAssistant:
            return packages.first { $0.url.lastPathComponent == "InstallAssistant.pkg" }?.size ?? 0
        case .legacyESD:
            return packages.reduce(0) { $0 + $1.size }
        case .other:
            return 0
        }
    }
}
