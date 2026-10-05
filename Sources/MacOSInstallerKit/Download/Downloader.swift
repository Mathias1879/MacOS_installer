import Foundation

public enum DownloadError: Error, Equatable {
    case sizeMismatch(expected: Int64, actual: Int64, path: String)
    case transferFailed(String)
}

/// Both cases are raised from `Downloader.download` or the `ResumableTransfer`
/// it drives, entirely before `InstallerPreparer` reaches assembly and long
/// before `InstallMediaWriter` is ever constructed — so both can truthfully
/// say the drive was not touched, and must say so explicitly, because by the
/// time this runs the user has already confirmed the erase.
extension DownloadError: Explainable {
    public var explanation: UserFacingError {
        switch self {
        case .sizeMismatch(let expected, let actual, let path):
            return UserFacingError(
                title: "The download didn't finish correctly",
                whatHappened: "The downloaded file is the wrong size: expected \(expected) bytes but got "
                    + "\(actual) at \(path). The drive was not touched.",
                whatItMeans: "The file has been deleted, so it will be downloaded again next time "
                    + "rather than reused.",
                whatToDoNext: [
                    "Run this command again to retry the download",
                    "If it keeps failing, check your internet connection",
                ]
            )

        case .transferFailed(let message):
            return UserFacingError(
                title: "The download failed",
                whatHappened: "The download of the installer failed: \(message). The drive was not touched.",
                whatItMeans: "This is usually a dropped network connection rather than a problem with "
                    + "your drive.",
                whatToDoNext: [
                    "Check your internet connection",
                    "Run this command again — the download resumes from where it left off",
                ]
            )
        }
    }

    public var technicalDetail: String {
        switch self {
        case .sizeMismatch(let expected, let actual, let path):
            return "DownloadError.sizeMismatch expected=\(expected) actual=\(actual) path=\(path)"
        case .transferFailed(let message):
            return "DownloadError.transferFailed message=\(message)"
        }
    }
}

/// Resumes an interrupted download rather than restarting it. At 18 GB per
/// installer, restarting from zero is not a realistic recovery strategy.
public struct Downloader {
    private let transfer: any ResumableTransfer
    private let fileManager: FileManager
    private let maximumAttempts: Int
    private let backoff: @Sendable (Int) -> Duration
    private let onRetry: @Sendable (Int, Duration, any Error) -> Void

    /// 1s, 2s, 4s — short enough not to look hung, long enough to outlast a
    /// brief network blip.
    public static let defaultBackoff: @Sendable (Int) -> Duration = { attempt in
        .seconds(1 << (attempt - 1))
    }

    public init(
        transfer: any ResumableTransfer,
        fileManager: FileManager = .default,
        maximumAttempts: Int = 3,
        backoff: @escaping @Sendable (Int) -> Duration = Downloader.defaultBackoff,
        onRetry: @escaping @Sendable (Int, Duration, any Error) -> Void = { _, _, _ in }
    ) {
        self.transfer = transfer
        self.fileManager = fileManager
        self.maximumAttempts = max(1, maximumAttempts)
        self.backoff = backoff
        self.onRetry = onRetry
    }

    @discardableResult
    public func download(
        from url: URL,
        to destination: URL,
        expectedBytes: Int64,
        progress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        try await transferIfNeeded(from: url, to: destination, expectedBytes: expectedBytes, progress: progress)

        let finalSize = fileManager.fileSize(at: destination)
        guard finalSize == expectedBytes else {
            // A wrong size after a successful transfer is a corrupt or stale
            // file on disk, not a transient network failure — retrying it
            // would just re-skip the transfer (it is already "complete" by
            // size) and throw the identical error again. Plan 2 already
            // deletes this file at the call site; this just must not retry.
            throw DownloadError.sizeMismatch(expected: expectedBytes, actual: finalSize, path: destination.path)
        }

        progress(finalSize, expectedBytes)
        return destination
    }

    /// Retries a failing transfer up to `maximumAttempts` times, recomputing
    /// `alreadyHave` on every attempt so a partially-written file resumes
    /// instead of restarting from zero. Returns normally once the file is
    /// already complete or a transfer attempt succeeds; rethrows the last
    /// transfer error once attempts are exhausted.
    private func transferIfNeeded(
        from url: URL,
        to destination: URL,
        expectedBytes: Int64,
        progress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        for attempt in 1...maximumAttempts {
            let alreadyHave = fileManager.fileSize(at: destination)
            if alreadyHave >= expectedBytes { return }

            progress(alreadyHave, expectedBytes)
            do {
                try await transfer.transfer(from: url, to: destination, startingAt: alreadyHave) { written in
                    progress(alreadyHave + written, expectedBytes)
                }
                return
            } catch {
                if attempt == maximumAttempts { throw error }
                let wait = backoff(attempt)
                onRetry(attempt, wait, error)
                try await Task.sleep(for: wait)
            }
        }
    }
}
