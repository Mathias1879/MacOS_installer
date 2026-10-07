import Foundation

/// Errors specific to preparing an installer that are not already represented
/// by the lower-level errors (download, digest, assembly) this type wraps.
public enum InstallerPreparationError: Error, Equatable, Sendable {
    /// Mojave and Catalina used a chunked ESD layout whose assembly mechanics
    /// are not implemented yet.
    case legacyAssemblyNotSupported
    /// `softwareupdate`-sourced releases cannot be downloaded directly; the
    /// user must fetch the full installer themselves first.
    case softwareUpdateOnly(version: String)

    public var userMessage: String {
        switch self {
        case .legacyAssemblyNotSupported:
            return "Mojave and Catalina media are not supported yet. See the project roadmap."
        case .softwareUpdateOnly:
            return "This release can only be fetched with `softwareupdate --fetch-full-installer`. "
                + "Run that first, then re-run this command to use the local copy."
        }
    }
}

/// Both cases are raised from `prepare`'s initial `switch`, before any
/// download or assembly step runs, so both can truthfully say the drive was
/// not touched — and must say so explicitly, because by the time this runs
/// the user has already confirmed the erase.
extension InstallerPreparationError: Explainable {
    public var explanation: UserFacingError {
        switch self {
        case .legacyAssemblyNotSupported:
            return UserFacingError(
                title: "This macOS version isn't supported yet",
                whatHappened: "Mojave and Catalina media are not supported yet. The drive was not touched.",
                whatItMeans: "This is a gap in what this tool can build, not a problem with your drive.",
                whatToDoNext: [
                    "See the project roadmap for current support status",
                ]
            )

        case .softwareUpdateOnly(let version):
            return UserFacingError(
                title: "This release must be fetched separately",
                whatHappened: "macOS \(version) cannot be downloaded directly by this tool. "
                    + "The drive was not touched.",
                whatItMeans: "Apple only distributes this release through softwareupdate's "
                    + "full-installer fetch, not as a direct download.",
                whatToDoNext: [
                    "Run: softwareupdate --fetch-full-installer",
                    "Run this command again once that finishes, to use the local copy",
                ]
            )
        }
    }

    public var technicalDetail: String {
        switch self {
        case .legacyAssemblyNotSupported:
            return "InstallerPreparationError.legacyAssemblyNotSupported"
        case .softwareUpdateOnly(let version):
            return "InstallerPreparationError.softwareUpdateOnly version=\(version)"
        }
    }
}

/// Orchestrates turning a selected `InstallerRelease` into a usable installer
/// application: download the payload if one is needed, verify it against
/// Apple's published digest when one is available, then assemble it.
///
/// This lives in `MacOSInstallerKit`, not in `CreateCommand`, so it is covered
/// by tests — the executable target is reserved for argument parsing, prompts,
/// printing and wiring, and is excluded from coverage.
public struct InstallerPreparer {
    /// Rejects a release whose payload `prepare` cannot use, before any
    /// irreversible step — `CreateCommand`'s typed erase confirmation
    /// included — is ever reached.
    ///
    /// `prepare`'s own `switch` throws the identical errors for the identical
    /// cases, and that throw stays in place as defence in depth for any other
    /// caller. This exists so `CreateCommand.execute()` can call it
    /// immediately after `fetchRelease` returns — before the Before stage,
    /// before volume enumeration, before the typed confirmation — so a
    /// release this tool cannot use is refused before the user has done
    /// anything irreversible. Under `--offline`, every release on offer is
    /// `.softwareUpdate`, so without this check the entire table was a trap:
    /// the user would type their drive's name to confirm an erase before
    /// ever learning the release could not be fetched.
    public static func assertUsable(_ release: InstallerRelease) throws {
        switch release.payload {
        case .legacyESD:
            throw InstallerPreparationError.legacyAssemblyNotSupported
        case .softwareUpdate(let version):
            throw InstallerPreparationError.softwareUpdateOnly(version: version)
        case .installAssistant, .localApplication:
            return
        }
    }

    private let downloader: Downloader
    private let assembler: any AssemblyStrategy
    private let cacheDirectory: URL
    private let fileManager: FileManager

    public init(
        downloader: Downloader,
        assembler: any AssemblyStrategy,
        cacheDirectory: URL = CatalogCache.defaultDirectory,
        fileManager: FileManager = .default
    ) {
        self.downloader = downloader
        self.assembler = assembler
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
    }

    /// `progress` receives short human-readable status lines; the caller
    /// decides how (or whether) to print them.
    public func prepare(
        _ release: InstallerRelease,
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        switch release.payload {
        case .localApplication(let path):
            return path

        case .installAssistant(let url):
            return try await downloadAndAssemble(release: release, from: url, progress: progress)

        case .legacyESD:
            throw InstallerPreparationError.legacyAssemblyNotSupported

        case .softwareUpdate(let version):
            throw InstallerPreparationError.softwareUpdateOnly(version: version)
        }
    }

    /// A digest mismatch is retried exactly once — the download itself is
    /// deleted and re-fetched from scratch — before giving up. A checksum
    /// failure that recurs on a fresh download is not a transient blip (that
    /// case is already handled inside `Downloader`'s own attempt loop); it
    /// means the catalog's published digest itself is wrong, and looping
    /// forever would just hide that behind an endless retry.
    // `internal` rather than `private` so a test can bind to this same named
    // constant — see `combinedWorstCaseRetryTimeStaysUnderCeiling` in
    // `DownloaderTests.swift` — instead of copying the literal `2`, which
    // would silently stop tracking a future bump to this value.
    static let maximumDigestAttempts = 2

    private func downloadAndAssemble(
        release: InstallerRelease,
        from url: URL,
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let pkg = cacheDirectory.appendingPathComponent("InstallAssistant-\(release.build).pkg")

        try await downloadAndVerify(release: release, from: url, to: pkg, progress: progress)

        progress("Installing the macOS installer app (this needs your password)…")
        return try assembler.assemble(payloadAt: pkg, expectedAppName: "Install \(release.name)")
    }

    private func downloadAndVerify(
        release: InstallerRelease,
        from url: URL,
        to pkg: URL,
        progress: @Sendable @escaping (String) -> Void
    ) async throws {
        for attempt in 1...Self.maximumDigestAttempts {
            do {
                try await performDownload(release: release, from: url, to: pkg, progress: progress)
                try verifyDigestIfPresent(of: release, at: pkg, progress: progress)
                return
            } catch let error as DigestError {
                // Deliberately catches both `.mismatch` and `.unreadable`,
                // not just the mismatch case the original brief named.
                // `.unreadable` means the just-downloaded file could not be
                // read back to hash it — plausibly a transient read failure
                // (e.g. the drive hiccuping) rather than a corrupt download —
                // and `verifyDigestIfPresent` has already deleted it either
                // way, so one retry (a fresh download) is a reasonable thing
                // to try before giving up. The progress message below is
                // worded to cover both cases rather than claiming a mismatch
                // that may not have happened.
                if attempt == Self.maximumDigestAttempts { throw error }
                progress("The downloaded file didn't verify — downloading it again…")
            }
        }
    }

    private func performDownload(
        release: InstallerRelease,
        from url: URL,
        to pkg: URL,
        progress: @Sendable @escaping (String) -> Void
    ) async throws {
        do {
            try await downloader.download(from: url, to: pkg, expectedBytes: release.sizeBytes) { done, total in
                let percent = total > 0 ? Int(done * 100 / total) : 0
                progress("Downloading… \(percent)%")
            }
        } catch let error as DownloadError {
            // A size mismatch means `Downloader` found a wrong-but-present
            // file on disk and skipped the transfer entirely (it only
            // transfers when `alreadyHave < expectedBytes`). Left in place,
            // that file wedges every future run behind the identical error
            // forever. Delete it so the next run re-downloads from scratch,
            // exactly as already done for a digest mismatch below. Deletion
            // is best-effort: if it fails, the original error is still the
            // one that matters to the caller.
            if case .sizeMismatch = error {
                try? fileManager.removeItem(at: pkg)
            }
            throw error
        }
    }

    private func verifyDigestIfPresent(
        of release: InstallerRelease,
        at pkg: URL,
        progress: @Sendable @escaping (String) -> Void
    ) throws {
        guard let digest = release.digest else { return }
        progress("Checking the download…")
        do {
            try DigestVerifier.verify(fileAt: pkg, matches: digest)
        } catch {
            // `Downloader` skips the transfer entirely once a file of the
            // expected size exists on disk. Leaving a wrong-but-right-sized
            // file in the cache would make every future run fail with the
            // same digest mismatch, forever, with no visible cause — so
            // delete it and let the next run fetch a fresh copy. The
            // deletion itself is best-effort: if it fails, the original
            // digest error is still the one that matters to the caller.
            try? fileManager.removeItem(at: pkg)
            throw error
        }
    }
}
