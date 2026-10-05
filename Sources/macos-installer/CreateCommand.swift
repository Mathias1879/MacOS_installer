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

    @Flag(name: .long, help: "Skip the guided walkthrough and print only what's necessary.")
    var brief = false

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

    /// The top-level sequence, readable in order without reading any
    /// extracted method's body: ask which Mac this is for, resolve this
    /// Mac's own boot volume, pick a release, enumerate drives, pick one,
    /// confirm the erase, then do the erase/write and show what comes after.
    /// Each phase's ordering guarantees (why Before precedes enumeration, why
    /// During precedes the password prompt, why After follows a successful
    /// write) live as comments on the phase itself, not here — see
    /// `enumerateVolumes` and `writeAndFinish`.
    private func execute() async throws {
        try PrivilegeCheck.assertNotRoot()

        let targetMac = try askTargetMacIfNeeded()

        let runner = RealCommandRunner()
        let bootVolume = try BootVolumeResolver(runner: runner).resolve()

        let release = try await fetchRelease(runner: runner)
        let volumes = try enumerateVolumes(runner: runner, targetMac: targetMac, release: release)

        let targetDecision = try selectTarget(volumes: volumes, bootVolume: bootVolume, release: release)
        let target = targetDecision.volume

        let uuid = try confirmErase(target: target, verdict: targetDecision.verdict)

        try await writeAndFinish(target: target, uuid: uuid, release: release, runner: runner, targetMac: targetMac)
    }

    /// Fetches every installer source, warns (without failing) about any that
    /// didn't respond, and resolves `--version` to one release — or prints
    /// the table and exits if no release was picked.
    private func fetchRelease(runner: any CommandRunner) async throws -> InstallerRelease {
        let catalog = await fetchCatalog(runner: runner)
        for failure in catalog.failures {
            warn("source unavailable — \(failure)")
        }

        guard let release = selectRelease(from: catalog.releases) else {
            print(ReleaseTableFormatter.render(catalog.releases))
            print("\nPick one with --version <version>.")
            throw ExitCode.failure
        }
        return release
    }

    /// Shows the Before stage, if a target Mac was chosen, and only then
    /// enumerates mounted volumes — in that order, enforced by
    /// `BeforeStageOrdering` rather than left to this call site, because the
    /// Before stage tells the user to plug a drive in and a snapshot taken
    /// before that instruction cannot reflect a drive plugged in response to
    /// it. The stage's text needs `release.name`, the same value every other
    /// stage and the final "is now named" message use, which is why this
    /// runs after the release is already known rather than before it. See
    /// task-8-fix-1.md and task-8-report.md.
    ///
    /// A volume that could not be read is otherwise indistinguishable from
    /// one that isn't plugged in, and the user is about to pick one of the
    /// drives that IS listed — so a read failure on another drive must be
    /// visible, not silent.
    private func enumerateVolumes(
        runner: any CommandRunner, targetMac: TargetMac?, release: InstallerRelease
    ) throws -> [Volume] {
        let volumeResult = try BeforeStageOrdering.announceThenObserve(
            announce: {
                if let targetMac {
                    WalkthroughPresenter.show(
                        .before, targetMac: targetMac, installerName: release.name, originalDriveName: nil
                    )
                }
            },
            observe: { try DiskEnumerator(runner: runner).mountedVolumes() }
        )
        for failure in volumeResult.failures {
            warn("could not read a volume — \(failure)")
        }
        return volumeResult.volumes
    }

    /// Evaluates every mounted volume against the guard rules and resolves
    /// `--volume` to exactly one of them. The warning is the only thing a
    /// `selectableWithWarning` volume carries that a bare erase message does
    /// not — it must be printed here, immediately above the confirmation
    /// that follows, which is the one moment it can still change the user's
    /// mind. `VolumeTableFormatter` also renders it, but only on the listing
    /// path; a targeted `--volume` never goes through that path at all.
    private func selectTarget(
        volumes: [Volume], bootVolume: BootVolume, release: InstallerRelease
    ) throws -> VolumeGuard.VolumeDecision {
        // CORRECTION: protected paths must be absolute and symlink-resolved
        // before reaching VolumeGuard, which documents that contract and is
        // deliberately pure (resolving a symlink needs filesystem access).
        // Without this, a cache directory reached through a symlink would not
        // be recognised, and the guard could offer to erase the volume
        // holding the file this run is reading from.
        let protectedCacheDirectory = CatalogCache.defaultDirectory.resolvingSymlinksInPath().path

        let decisions = VolumeGuard.evaluate(
            volumes: volumes,
            bootVolume: bootVolume,
            requiredBytes: release.sizeBytes,
            protectedPaths: [protectedCacheDirectory]
        )

        let targetDecision = try resolveTarget(from: decisions)
        if case .selectableWithWarning(let warning) = targetDecision.verdict {
            print("  ⚠ \(warning)")
        }
        return targetDecision
    }

    /// Prints the erase banner, then confirms it — via the typed-name prompt
    /// for a flagged volume (`--yes` must never remove that control; see
    /// `VolumeGuard.requiresTypedConfirmation`), or immediately otherwise.
    /// Returns the volume's UUID, checked before the prompt so the user
    /// learns the volume cannot be targeted before typing its name, not
    /// after.
    private func confirmErase(target: Volume, verdict: VolumeGuard.Verdict) throws -> String {
        print("")
        print("  This will ERASE \(target.displayName) (\(target.deviceIdentifier)).")
        print("  Everything on it will be destroyed.")
        print("")

        guard let uuid = target.volumeUUID else {
            print("  That volume has no stable identifier, so it cannot be targeted safely.")
            throw ExitCode.failure
        }

        if VolumeGuard.requiresTypedConfirmation(yesFlag: yes, verdict: verdict) {
            print("  Type the volume name to confirm: ", terminator: "")
            guard ConfirmationPrompt.requireTypedName(target.displayName) else {
                print("  Names did not match. Nothing was changed.")
                throw ExitCode.failure
            }
        }
        return uuid
    }

    /// Shows the During stage, prepares and writes the installer, then shows
    /// the After stage and exports its instructions — strictly in that
    /// order. `target.displayName` is the drive's name as it exists right
    /// now, before anything has erased or renamed it; the During stage is
    /// shown here, immediately before the real work starts, because the
    /// password prompt (triggered partway through `prepareInstaller`) is the
    /// very next thing that happens and this stage is what pre-announces it.
    /// The After stage runs only once `writeInstaller` has returned without
    /// throwing, since it describes a drive that is already renamed and
    /// ready to boot from.
    private func writeAndFinish(
        target: Volume, uuid: String, release: InstallerRelease, runner: any CommandRunner, targetMac: TargetMac?
    ) async throws {
        if let targetMac {
            WalkthroughPresenter.show(
                .during, targetMac: targetMac, installerName: release.name, originalDriveName: target.displayName
            )
        }

        print("  Preparing \(release.name) \(release.version)…")
        let app = try await prepareInstaller(for: release, runner: runner)

        try writeInstaller(app: app, to: target, uuid: uuid, runner: runner)

        print(
            "  Done. \(target.displayName) (\(target.deviceIdentifier)) is now named "
                + "\"Install \(release.name)\"."
        )

        if let targetMac {
            WalkthroughPresenter.show(.after, targetMac: targetMac, installerName: release.name, originalDriveName: nil)
            exportInstructions(targetMac: targetMac, installerName: release.name)
        }
    }

    // MARK: - Walkthrough

    /// Returns the Mac the finished installer will boot, or nil under
    /// `--brief`. Fails closed — rather than guessing or defaulting — when
    /// the picker cannot get an answer, which happens both at end-of-input
    /// (stdin is not a terminal: piped input, CI) and after repeated
    /// unresolved answers; `TargetMacPicker.ask` returns nil for both, and
    /// neither case leaves this command able to say which Mac the After
    /// stage's boot steps are actually for. Proceeding anyway would hand
    /// someone instructions for a machine that isn't theirs, with nothing in
    /// the output to tell them so.
    private func askTargetMacIfNeeded() throws -> TargetMac? {
        guard !brief else { return nil }

        guard let targetMac = TargetMacPicker.ask() else {
            print("")
            print("  Could not get an answer for which Mac this installer is for.")
            print("  Answer the prompt above, or re-run with --brief to skip the walkthrough.")
            throw ExitCode.failure
        }
        return targetMac
    }

    /// Writes the After-stage instructions to disk. A failure here must not
    /// fail the run: by the time this is called, `writeInstaller` has already
    /// returned successfully, so the user has a working installer in hand —
    /// turning a saved-file problem into a reported failure would tell them
    /// their installer failed when it didn't. The After stage was already
    /// printed above, so the steps are not lost even if the file is.
    private func exportInstructions(targetMac: TargetMac, installerName: String) {
        do {
            let url = try InstructionExporter().export(target: targetMac, installerName: installerName)
            print("  Boot instructions for that Mac were saved to: \(url.path)")
        } catch {
            let log = DiagnosticLog(directory: DiagnosticLog.defaultDirectory)
            print(explain(error, log: log).rendered())
        }
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
