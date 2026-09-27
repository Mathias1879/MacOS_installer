import Foundation
@testable import MacOSInstallerKit

final class FakeDataFetcher: DataFetcher, @unchecked Sendable {
    nonisolated(unsafe) private var responses: [URL: Result<Data, any Error>] = [:]
    nonisolated(unsafe) private(set) var requestedURLs: [URL] = []

    func stub(_ data: Data, for url: URL) {
        responses[url] = .success(data)
    }

    func fail(_ error: any Error, for url: URL) {
        responses[url] = .failure(error)
    }

    func data(from url: URL) async throws -> Data {
        requestedURLs.append(url)
        let response = responses[url]

        switch response {
        case .success(let data): return data
        case .failure(let error): throw error
        case nil: throw FetchError.httpStatus(404, url: url)
        }
    }
}
