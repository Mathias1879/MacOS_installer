import Foundation

public enum DownloadError: Error, Equatable {
    case sizeMismatch(expected: Int64, actual: Int64, path: String)
    case transferFailed(String)
}

/// Resumes an interrupted download rather than restarting it. At 18 GB per
/// installer, restarting from zero is not a realistic recovery strategy.
public struct Downloader {
    private let transfer: any ResumableTransfer
    private let fileManager: FileManager

    public init(transfer: any ResumableTransfer, fileManager: FileManager = .default) {
        self.transfer = transfer
        self.fileManager = fileManager
    }

    @discardableResult
    public func download(
        from url: URL,
        to destination: URL,
        expectedBytes: Int64,
        progress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        let alreadyHave = fileManager.fileSize(at: destination)

        if alreadyHave < expectedBytes {
            progress(alreadyHave, expectedBytes)
            try await transfer.transfer(from: url, to: destination, startingAt: alreadyHave) { written in
                progress(alreadyHave + written, expectedBytes)
            }
        }

        let finalSize = fileManager.fileSize(at: destination)
        guard finalSize == expectedBytes else {
            throw DownloadError.sizeMismatch(expected: expectedBytes, actual: finalSize, path: destination.path)
        }

        progress(finalSize, expectedBytes)
        return destination
    }
}
