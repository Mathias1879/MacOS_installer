import Foundation

public enum CatalogResolutionError: Error {
    case allCandidatesFailed([String])
}

/// Apple renames the catalog index with each macOS generation. Rather than
/// hard-code one URL, walk a list newest-first and use the first that responds.
/// Verified 2026-09-26: the index-27 URL returns HTTP 200, 7,045,040 bytes.
public struct CatalogURLResolver {
    public static let candidates: [URL] = [
        "https://swscan.apple.com/content/catalogs/others/index-27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
        "https://swscan.apple.com/content/catalogs/others/index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
        "https://swscan.apple.com/content/catalogs/others/index-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    ].compactMap(URL.init(string:))

    private let fetcher: any DataFetcher
    private let candidates: [URL]

    public init(fetcher: any DataFetcher, candidates: [URL] = CatalogURLResolver.candidates) {
        self.fetcher = fetcher
        self.candidates = candidates
    }

    public func resolve() async throws -> (url: URL, data: Data) {
        var failures: [String] = []

        for candidate in candidates {
            do {
                let data = try await fetcher.data(from: candidate)
                return (candidate, data)
            } catch {
                failures.append("\(candidate.lastPathComponent): \(error)")
            }
        }

        throw CatalogResolutionError.allCandidatesFailed(failures)
    }
}
