import Foundation

public enum FetchError: Error, Equatable {
    case httpStatus(Int, url: URL)
    case transport(String, url: URL)
}

/// All network reads go through this so tests run offline.
public protocol DataFetcher: Sendable {
    func data(from url: URL) async throws -> Data
}

public struct URLSessionDataFetcher: DataFetcher {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
    }

    public func data(from url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw FetchError.httpStatus(http.statusCode, url: url)
            }
            return data
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.transport(error.localizedDescription, url: url)
        }
    }
}
