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

/// Orchestrates turning a selected `InstallerRelease` into a usable installer
/// application: download the payload if one is needed, verify it against
/// Apple's published digest when one is available, then assemble it.
///
/// This lives in `MacOSInstallerKit`, not in `CreateCommand`, so it is covered
/// by tests — the executable target is reserved for argument parsing, prompts,
/// printing and wiring, and is excluded from coverage.
public struct InstallerPreparer {
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

    private func downloadAndAssemble(
        release: InstallerRelease,
        from url: URL,
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let pkg = cacheDirectory.appendingPathComponent("InstallAssistant-\(release.build).pkg")

        try await downloader.download(from: url, to: pkg, expectedBytes: release.sizeBytes) { done, total in
            let percent = total > 0 ? Int(done * 100 / total) : 0
            progress("Downloading… \(percent)%")
        }

        if let digest = release.digest {
            progress("Checking the download…")
            try DigestVerifier.verify(fileAt: pkg, matches: digest)
        }

        progress("Installing the macOS installer app (this needs your password)…")
        return try assembler.assemble(payloadAt: pkg, expectedAppName: "Install \(release.name)")
    }
}
