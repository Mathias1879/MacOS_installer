import Foundation
import Testing
@testable import MacOSInstallerKit

private let first = URL(string: "https://swscan.apple.com/a.sucatalog")!
private let second = URL(string: "https://swscan.apple.com/b.sucatalog")!

@Test("returns the first candidate that responds")
func returnsFirstReachableCandidate() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.stub(Data("catalog-a".utf8), for: first)
    let resolver = CatalogURLResolver(fetcher: fetcher, candidates: [first, second])

    let result = try await resolver.resolve()

    #expect(result.url == first)
    #expect(result.data == Data("catalog-a".utf8))
    #expect(fetcher.requestedURLs == [first])
}

@Test("falls through to the next candidate when the first fails")
func fallsThroughOnFailure() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.fail(FetchError.httpStatus(404, url: first), for: first)
    fetcher.stub(Data("catalog-b".utf8), for: second)
    let resolver = CatalogURLResolver(fetcher: fetcher, candidates: [first, second])

    let result = try await resolver.resolve()

    #expect(result.url == second)
    #expect(fetcher.requestedURLs == [first, second])
}

@Test("throws listing every failure when no candidate responds")
func throwsWhenAllCandidatesFail() async {
    let fetcher = FakeDataFetcher()
    fetcher.fail(FetchError.httpStatus(404, url: first), for: first)
    fetcher.fail(FetchError.httpStatus(500, url: second), for: second)
    let resolver = CatalogURLResolver(fetcher: fetcher, candidates: [first, second])

    await #expect(throws: (any Error).self) {
        _ = try await resolver.resolve()
    }
}

@Test("ships a non-empty default candidate list")
func defaultCandidatesArePresent() {
    #expect(CatalogURLResolver.candidates.isEmpty == false)
    #expect(CatalogURLResolver.candidates.allSatisfy { $0.absoluteString.hasSuffix(".sucatalog") })
}

@Test("records every request when called concurrently from a task group")
func recordsConcurrentRequestsSafely() async throws {
    let fetcher = FakeDataFetcher()
    let urls = (0..<50).map { URL(string: "https://example.invalid/\($0)")! }
    for url in urls { fetcher.stub(Data("x".utf8), for: url) }

    await withTaskGroup(of: Void.self) { group in
        for url in urls {
            group.addTask { _ = try? await fetcher.data(from: url) }
        }
    }

    #expect(fetcher.requestedURLs.count == 50)
    #expect(Set(fetcher.requestedURLs) == Set(urls))
}
