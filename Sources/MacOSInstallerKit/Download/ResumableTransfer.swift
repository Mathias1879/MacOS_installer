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
/// The end-to-end network transfer is not unit-tested — it touches the
/// network, so its correctness otherwise rests on the manual verification
/// checklist for this plan, which is also why it is kept deliberately small
/// and obvious rather than clever. Argv construction and error translation
/// are unit-tested via an injected `CommandRunner`.
///
/// KNOWN LIMITATION — cancellation does not reach curl: `curl` runs inside a
/// `Task.detached` child task, and `Task.detached` neither inherits nor
/// observes the calling task's cancellation. If the caller's task is
/// cancelled (for example, the user presses Ctrl-C), this function's polling
/// loop stops reporting progress and this call returns, but the underlying
/// `curl` process keeps running in the background and will pull the entire
/// remaining transfer on its own. The partial file curl is writing remains
/// valid — a later `Downloader.download` call resumes from wherever curl
/// left off, so nothing is corrupted — but the in-flight bandwidth use is
/// not actually stopped. Fixing this properly requires threading
/// cancellation through `CommandRunner` (a Plan 1 type with six existing
/// call sites), which is out of scope here and deliberately deferred.
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
        // `--` marks the end of options so curl cannot misread the URL as a
        // flag if it ever began with `-`. The URL is built internally today
        // (never user-supplied), but this is a one-token defence that does
        // not rely on that staying true.
        //
        // `--no-progress-meter` suppresses curl's periodic progress text on
        // stderr. Without it, curl can emit well over the ~64 KB pipe buffer
        // during an 18 GB download, which — independent of this flag — is
        // why `RealCommandRunner` must also drain stdout and stderr
        // concurrently rather than relying on suppression alone.
        let arguments = [
            "--no-progress-meter", "-L", "-C", "-", "--fail", "--output", destination.path, "--",
            url.absoluteString,
        ]
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

        let result: CommandResult
        do {
            result = try outcome.get()
        } catch {
            // Every failure out of this type comes back as a DownloadError,
            // regardless of what CommandRunner threw (e.g. CommandError
            // .launchFailed if the curl binary is missing or unlaunchable).
            throw DownloadError.transferFailed("curl failed to launch: \(error)")
        }

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
