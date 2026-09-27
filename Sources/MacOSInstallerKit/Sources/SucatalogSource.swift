import Foundation

/// Reads Apple's public software update catalog. Unlike `softwareupdate`, this
/// is not filtered by host model, which is what allows an Apple silicon host to
/// write media for an older Intel target.
public struct SucatalogSource: InstallerSource {
    public let origin: InstallerRelease.Origin = .sucatalog

    private let fetcher: any DataFetcher
    private let resolver: CatalogURLResolver

    public init(fetcher: any DataFetcher, resolver: CatalogURLResolver? = nil) {
        self.fetcher = fetcher
        self.resolver = resolver ?? CatalogURLResolver(fetcher: fetcher)
    }

    public func availableReleases() async throws -> [InstallerRelease] {
        let (_, catalogData) = try await resolver.resolve()
        let products = try SucatalogClient.parse(catalogData)

        // Distribution files are ~10 KB each and there are around twenty of
        // them. Fetch concurrently; a product whose .dist is unavailable is
        // dropped rather than failing the whole listing.
        return await withTaskGroup(of: InstallerRelease?.self) { group in
            for product in products {
                group.addTask { await release(for: product) }
            }

            var releases: [InstallerRelease] = []
            for await release in group {
                if let release { releases.append(release) }
            }
            return releases.sorted { $0.version > $1.version }
        }
    }

    private func release(for product: CatalogProduct) async -> InstallerRelease? {
        guard let distributionURL = product.distributionURL else { return nil }

        guard
            let data = try? await fetcher.data(from: distributionURL),
            let info = try? DistributionParser.parse(data)
        else { return nil }

        let payload: InstallerRelease.Payload
        switch product.kind {
        case .installAssistant:
            guard let url = product.installAssistantURL else { return nil }
            payload = .installAssistant(url: url)
        case .legacyESD:
            payload = .legacyESD(urls: product.legacyESDURLs)
        case .other:
            return nil
        }

        return InstallerRelease(
            name: info.title,
            version: info.version,
            build: info.build,
            sizeBytes: product.totalSize,
            origin: .sucatalog,
            payload: payload
        )
    }
}
