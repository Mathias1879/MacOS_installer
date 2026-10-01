import Foundation

/// Appends bytes to `destination`, starting at `startingAt` in the remote
/// resource. Behind a protocol so tests neither touch the network nor write
/// gigabytes.
public protocol ResumableTransfer: Sendable {
    func transfer(
        from url: URL,
        to destination: URL,
        startingAt offset: Int64,
        progress: @Sendable (Int64) -> Void
    ) async throws
}

extension FileManager {
    /// Size in bytes of the file at `url`, or 0 if it does not exist. Shared
    /// by `Downloader` and `CurlResumableTransfer` so both agree on what
    /// "bytes already on disk" means.
    func fileSize(at url: URL) -> Int64 {
        guard
            let attributes = try? attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }
}

/// Tracks whether the background `curl` invocation has finished and, if so,
/// with what result. An actor rather than a lock: everything that touches it
/// is already in an async context, and an actor keeps that explicit.
private actor CurlTransferState {
    private(set) var result: Result<CommandResult, Error>?

    func finish(_ result: Result<CommandResult, Error>) {
        self.result = result
    }
}

/// Resumes a download by shelling out to `curl -L -C -`, which follows
/// Apple's CDN redirects and resumes from wherever the local file left off.
/// Progress is derived by polling the destination file's size rather than
/// parsing curl's own progress meter, so this stays small and uses the same
/// `CommandRunner` seam as every other external tool in this codebase.
///
/// Not unit-tested: it touches the network. Its correctness rests on the
/// manual verification checklist for this plan, which is also why it is kept
/// deliberately small and obvious rather than clever.
public struct CurlResumableTransfer: ResumableTransfer {
    public static let defaultPollInterval: TimeInterval = 1

    private let commandRunner: any CommandRunner
    private let curlExecutable: String
    private let pollInterval: TimeInterval

    public init(
        commandRunner: any CommandRunner = RealCommandRunner(),
        curlExecutable: String = "/usr/bin/curl",
        pollInterval: TimeInterval = CurlResumableTransfer.defaultPollInterval
    ) {
        self.commandRunner = commandRunner
        self.curlExecutable = curlExecutable
        self.pollInterval = pollInterval
    }

    public func transfer(
        from url: URL,
        to destination: URL,
        startingAt offset: Int64,
        progress: @Sendable (Int64) -> Void
    ) async throws {
        let arguments = ["-L", "-C", "-", "--fail", "--output", destination.path, url.absoluteString]
        let state = CurlTransferState()
        let commandRunner = self.commandRunner
        let curlExecutable = self.curlExecutable

        let curlTask = Task.detached {
            do {
                let result = try commandRunner.run(curlExecutable, arguments)
                await state.finish(.success(result))
            } catch {
                await state.finish(.failure(error))
            }
        }

        // Poll the file curl is writing rather than parsing its progress
        // meter. `progress` is called directly from this function's own
        // body (never handed to another closure), so it never needs to
        // escape — the protocol's non-escaping parameter is honored as-is.
        while await state.result == nil {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            progress(bytesWritten(at: destination, since: offset))
        }
        _ = await curlTask.value

        guard let outcome = await state.result else {
            throw DownloadError.transferFailed("curl finished without reporting a result")
        }

        let result = try outcome.get()
        guard result.exitCode == 0 else {
            throw DownloadError.transferFailed(
                "curl exited \(result.exitCode): \(result.standardError)"
            )
        }

        progress(bytesWritten(at: destination, since: offset))
    }

    private func bytesWritten(at destination: URL, since offset: Int64) -> Int64 {
        max(0, FileManager.default.fileSize(at: destination) - offset)
    }
}
