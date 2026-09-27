import Foundation
@testable import MacOSInstallerKit

final class FakeDataFetcher: DataFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: Result<Data, any Error>] = [:]
    private var recorded: [URL] = []

    var requestedURLs: [URL] {
        lock.withLock { recorded }
    }

    func stub(_ data: Data, for url: URL) {
        lock.withLock { responses[url] = .success(data) }
    }

    func fail(_ error: any Error, for url: URL) {
        lock.withLock { responses[url] = .failure(error) }
    }

    /// Synchronous on purpose: the lock must never be held across a
    /// suspension point, and `withLock` is callable from an async context
    /// because the critical section itself is synchronous.
    private func recordAndLookUp(_ url: URL) -> Result<Data, any Error>? {
        lock.withLock {
            recorded.append(url)
            return responses[url]
        }
    }

    func data(from url: URL) async throws -> Data {
        switch recordAndLookUp(url) {
        case .success(let data): return data
        case .failure(let error): throw error
        case nil: throw FetchError.httpStatus(404, url: url)
        }
    }
}
