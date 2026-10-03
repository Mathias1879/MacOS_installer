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
