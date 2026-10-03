import ArgumentParser
import Foundation
import MacOSInstallerKit

/// Writes a bootable macOS installer to an external drive.
///
/// This type is deliberately thin: argument parsing, prompts, printing and
/// wiring together the library types that do the actual work. The orchestration
/// logic (download → verify → assemble) lives in `InstallerPreparer`, and the
/// target-disambiguation logic lives in `VolumeTargetResolver` — both in
/// `MacOSInstallerKit`, where they are covered by tests. This target is
/// excluded from coverage and must not accumulate logic that needs testing.
struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Write a bootable macOS installer to an external drive. This erases the drive."
    )

    @Option(name: .long, help: "macOS version to write, e.g. 26.7. Omit to be shown a list.")
    var version: String?

    @Option(name: .long, help: "Target volume's display name or device identifier.")
    var volume: String?

    @Flag(name: .long, help: "Skip Apple's catalog; use only softwareupdate and local installers.")
    var offline = false

    @Flag(name: .long, help: "Skip the typed confirmation. Use only in scripts you trust.")
    var yes = false

    func run() async throws {
        do {
            try await execute()
        } catch let exitCode as ExitCode {
            // Already handled: every site that throws ExitCode directly has
            // already printed its own specific message.
            throw exitCode
        } catch {
            let log = DiagnosticLog(directory: DiagnosticLog.defaultDirectory)
            print(explain(error, log: log).rendered())
            throw ExitCode.failure
        }
    }

    private func execute() async throws {
        try PrivilegeCheck.assertNotRoot()

        let runner = RealCommandRunner()
        let bootVolume = try BootVolumeResolver(runner: runner).resolve()

        let volumeResult = try DiskEnumerator(runner: runner).mountedVolumes()
        // A volume that could not be read is otherwise indistinguishable from
        // one that isn't plugged in, and the user is about to pick one of the
        // drives that IS listed — so a read failure on another drive must be
        // visible, not silent.
        for failure in volumeResult.failures {
            warn("could not read a volume — \(failure)")
        }

        let catalog = await fetchCatalog(runner: runner)
        for failure in catalog.failures {
            warn("source unavailable — \(failure)")
        }

        guard let release = selectRelease(from: catalog.releases) else {
            print(ReleaseTableFormatter.render(catalog.releases))
            print("\nPick one with --version <version>.")
            throw ExitCode.failure
        }

        // CORRECTION: protected paths must be absolute and symlink-resolved
        // before reaching VolumeGuard, which documents that contract and is
        // deliberately pure (resolving a symlink needs filesystem access).
        // Without this, a cache directory reached through a symlink would not
        // be recognised, and the guard could offer to erase the volume
        // holding the file this run is reading from.
        let protectedCacheDirectory = CatalogCache.defaultDirectory.resolvingSymlinksInPath().path

        let decisions = VolumeGuard.evaluate(
            volumes: volumeResult.volumes,
            bootVolume: bootVolume,
            requiredBytes: release.sizeBytes,
            protectedPaths: [protectedCacheDirectory]
        )

        let targetDecision = try resolveTarget(from: decisions)
        let target = targetDecision.volume

        // The warning is the only thing a `selectableWithWarning` volume
        // carries that a bare erase message does not — it must be shown here,
        // immediately above the confirmation, which is the one moment it can
        // still change the user's mind. `VolumeTableFormatter` also renders
        // it, but only on the listing path; a targeted `--volume` never goes
        // through that path at all.
        if case .selectableWithWarning(let warning) = targetDecision.verdict {
            print("  ⚠ \(warning)")
        }

        print("")
        print("  This will ERASE \(target.displayName) (\(target.deviceIdentifier)).")
        print("  Everything on it will be destroyed.")
        print("")

        // Checked before the prompt, not after: the user should learn the
        // volume cannot be targeted before typing its name, not after.
        guard let uuid = target.volumeUUID else {
            print("  That volume has no stable identifier, so it cannot be targeted safely.")
            throw ExitCode.failure
        }

        // `--yes` must never remove the typed-name control the spec requires
        // for a flagged (e.g. Time Machine-named) volume — see
        // `VolumeGuard.requiresTypedConfirmation`.
        if VolumeGuard.requiresTypedConfirmation(yesFlag: yes, verdict: targetDecision.verdict) {
            print("  Type the volume name to confirm: ", terminator: "")
            guard ConfirmationPrompt.requireTypedName(target.displayName) else {
                print("  Names did not match. Nothing was changed.")
                throw ExitCode.failure
            }
        }

        print("  Preparing \(release.name) \(release.version)…")
        let app = try await prepareInstaller(for: release, runner: runner)

        try writeInstaller(app: app, to: target, uuid: uuid, runner: runner)

        print(
            "  Done. \(target.displayName) (\(target.deviceIdentifier)) is now named "
                + "\"Install \(release.name)\"."
        )
    }

    // MARK: - Steps

    private func fetchCatalog(runner: any CommandRunner) async -> ReleaseCatalog.Result {
        var sources: [any InstallerSource] = [
            LocalInstallerSource(),
            SoftwareUpdateSource(runner: runner),
        ]
        if !offline {
            sources.append(SucatalogSource(fetcher: URLSessionDataFetcher()))
        }
        return await ReleaseCatalog(sources: sources).allReleases()
    }

    private func selectRelease(from releases: [InstallerRelease]) -> InstallerRelease? {
        guard let version else { return nil }
        return releases.first { $0.version.description == version }
    }

    /// Resolves `--volume` to exactly one target, refusing on no match or on
    /// an ambiguous match rather than guessing. See `VolumeTargetResolver` for
    /// why an ambiguous match must never silently resolve to the first hit.
    private func resolveTarget(from decisions: [VolumeGuard.VolumeDecision]) throws -> VolumeGuard.VolumeDecision {
        guard let volume else {
            print(VolumeTableFormatter.render(decisions))
            print("\nPick one with --volume <name or device identifier>.")
            throw ExitCode.failure
        }

        switch VolumeTargetResolver.resolve(matching: volume, among: decisions) {
        case .unique(let found):
            return found

        case .ambiguous(let candidates):
            print("  \"\(volume)\" matches more than one volume. Disambiguate by device identifier:")
            for candidate in candidates {
                print("    \(candidate.volume.displayName)  (\(candidate.volume.deviceIdentifier))")
            }
            throw ExitCode.failure

        case .none:
            print(VolumeTableFormatter.render(decisions))
            print("\nPick one with --volume <name or device identifier>.")
            throw ExitCode.failure
        }
    }

    private func prepareInstaller(for release: InstallerRelease, runner: any CommandRunner) async throws -> URL {
        let preparer = InstallerPreparer(
            downloader: Downloader(transfer: CurlResumableTransfer(commandRunner: runner)),
            assembler: InstallAssistantAssembler(runner: runner)
        )

        // Caught by the top-level `run()` catch, not here: a digest mismatch,
        // a download failure, an assembly failure, or even a raw
        // `CommandError` leaking out of a lower layer must all reach the user
        // as a real message through `explain`, rendered once, in one place.
        return try await preparer.prepare(release) { message in print("  \(message)") }
    }

    private func writeInstaller(app: URL, to target: Volume, uuid: String, runner: any CommandRunner) throws {
        try InstallMediaWriter(runner: runner).write(
            installerApp: app,
            toVolumeWithUUID: uuid,
            expectedDeviceIdentifier: target.deviceIdentifier,
            progress: { print("  \($0)") }
        )
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }
}
