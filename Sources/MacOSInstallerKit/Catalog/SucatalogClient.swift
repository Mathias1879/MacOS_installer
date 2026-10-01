import Foundation

public enum SucatalogParseError: Error, Equatable {
    case notAPropertyList
    case missingProductsDictionary
}

/// Parses Apple's software update catalog. The live catalog holds ~646 products,
/// of which only those carrying an InstallAssistant or InstallESD payload are
/// macOS installers; the rest are updates, fonts and dictionaries.
public enum SucatalogClient {
    public static func parse(_ data: Data) throws -> [CatalogProduct] {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw SucatalogParseError.notAPropertyList
        }

        guard let root = object as? [String: Any] else {
            throw SucatalogParseError.notAPropertyList
        }
        guard let products = root["Products"] as? [String: Any] else {
            throw SucatalogParseError.missingProductsDictionary
        }

        return products.compactMap { identifier, value in
            guard let entry = value as? [String: Any] else { return nil }
            let product = makeProduct(identifier: identifier, entry: entry)
            return product.kind == .other ? nil : product
        }
        .sorted { $0.postDate < $1.postDate }
    }

    private static func makeProduct(identifier: String, entry: [String: Any]) -> CatalogProduct {
        let packages = (entry["Packages"] as? [[String: Any]] ?? []).compactMap { package -> CatalogPackage? in
            guard
                let urlString = package["URL"] as? String,
                let url = URL(string: urlString),
                let size = (package["Size"] as? NSNumber)?.int64Value
            else { return nil }
            return CatalogPackage(url: url, size: size, digest: package["Digest"] as? String)
        }

        let distributions = entry["Distributions"] as? [String: String]
        let distributionURL = (distributions?["English"]).flatMap(URL.init(string:))

        return CatalogProduct(
            identifier: identifier,
            postDate: entry["PostDate"] as? Date ?? .distantPast,
            distributionURL: distributionURL,
            packages: packages
        )
    }
}
