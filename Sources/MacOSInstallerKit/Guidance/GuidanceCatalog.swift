import Foundation

/// A phase of the guided walkthrough: before the user starts, while the tool
/// is running, and after the drive is ready to boot from.
public enum GuidanceStage: CaseIterable, Sendable {
    case before
    case during
    case after
}

/// One titled block of guidance. `body` is prose; `steps` is numbered actions.
public struct GuidanceSection: Equatable, Sendable {
    public let heading: String
    public let body: [String]
    public let steps: [String]

    public init(heading: String, body: [String] = [], steps: [String] = []) {
        self.heading = heading
        self.body = body
        self.steps = steps
    }
}

/// All the words the walkthrough says, as data.
///
/// Keeping this out of control flow is a spec requirement: it makes the copy
/// testable (the tests assert that the password surprise is pre-announced and
/// that the after-stage contains only the selected target's instructions), and
/// editable without reading the command.
public enum GuidanceCatalog {
    /// - Parameter originalDriveName: The name the user's drive had BEFORE
    ///   this tool touched it (what they'd see on their desktop right now,
    ///   e.g. "SanDisk Ultra"). This is used only for `.during`, where the
    ///   user is still looking for their own drive. `.after` ignores it: once
    ///   `createinstallmedia` finishes, the drive is always renamed to
    ///   "Install \(installerName)", so `.after` derives that name itself
    ///   rather than accepting it as a parameter — a caller cannot pass the
    ///   wrong name for a value it is never asked for.
    /// - Parameter payload: Which of the two payload shapes that can still
    ///   reach the During stage this release has. `.legacyESD` and
    ///   `.softwareUpdate` have no case here because `InstallerPreparer.assertUsable`
    ///   — called from `CreateCommand.execute()` immediately after the
    ///   release is fetched, before the Before stage is even shown — rejects
    ///   both. By the time `.during` is ever rendered, only these two kinds
    ///   of release remain. Ignored for `.before` and `.after`, the same way
    ///   `originalDriveName` is.
    public static func sections(
        for stage: GuidanceStage,
        target: TargetMac,
        installerName: String,
        originalDriveName: String?,
        payload: DuringPayloadKind = .needsDownload
    ) -> [GuidanceSection] {
        switch stage {
        case .before: return before(installerName: installerName)
        case .during: return during(driveName: originalDriveName, payload: payload)
        case .after: return after(target: target, installerName: installerName)
        }
    }

    /// Which of the two payload shapes that can reach the During stage this
    /// release has — see `sections(for:target:installerName:originalDriveName:payload:)`
    /// for why there is no case for `.legacyESD` or `.softwareUpdate`.
    public enum DuringPayloadKind: Sendable {
        /// `InstallerPreparer.prepare` returns the already-installed app
        /// unchanged for `InstallerRelease.Payload.localApplication` — no
        /// download, and no separate assembly/install step, since the app is
        /// already fully assembled in `/Applications`.
        case local
        /// `InstallerRelease.Payload.installAssistant` is downloaded,
        /// digest-checked, then assembled with `installer` (which is the
        /// first of the two `sudo` prompts this path actually triggers — see
        /// `InstallAssistantAssembler`).
        case needsDownload
    }

    private static func before(installerName: String) -> [GuidanceSection] {
        [
            GuidanceSection(
                heading: "Before you start",
                body: [
                    "You'll be making a USB drive that can install \(installerName) onto a Mac.",
                ],
                steps: [
                    "Find a USB drive that holds 32 GB or more — any brand is fine",
                    "Copy anything you want to keep off that drive first, onto this Mac's desktop",
                    "Plug the drive into this Mac",
                ]
            ),
            GuidanceSection(
                heading: "Two things to know",
                body: [
                    "Everything on that USB drive will be erased. There is no undo.",
                    "This takes roughly 30 to 60 minutes, most of it downloading.",
                    "Keep the drive plugged in and this Mac awake the whole time — "
                        + "unplugging it or letting the Mac sleep partway through can ruin the drive.",
                    "The installer itself is already on the drive and is not downloaded again — "
                        + "though some Macs will still ask you to connect to Wi-Fi during setup afterward.",
                ]
            ),
        ]
    }

    private static func during(driveName: String?, payload: DuringPayloadKind) -> [GuidanceSection] {
        let drive = driveName ?? "your drive"
        return [
            GuidanceSection(heading: "What happens now", steps: duringSteps(for: payload, drive: drive)),
            GuidanceSection(
                heading: "Two things that look like problems but aren't",
                body: [
                    "When macOS asks for your password, no characters appear as you type — "
                        + "not even dots. That is normal. Type it and press Return.",
                    "A box may appear saying \"Terminal would like to access files on a "
                        + "removable volume\". Click OK. If you don't, writing the drive fails.",
                ]
            ),
        ]
    }

    /// Pinned to the real sequence for each payload kind — see
    /// `InstallerPreparer.prepare` for `.needsDownload` (download →
    /// `verifyDigestIfPresent` → `downloadAndAssemble`, which is where
    /// `InstallAssistantAssembler` invokes `sudo` for the first time and a
    /// password prompt actually appears) and `.local` (the release's payload
    /// is returned unchanged, with neither a download nor a separate assembly
    /// step). Both kinds still end in a write, and `InstallMediaWriter.write`
    /// calls `sudo -v` immediately before that write runs regardless of kind
    /// — a second, independent password moment that `.needsDownload` was
    /// previously the only path ever mentioned losing.
    private static func duringSteps(for payload: DuringPayloadKind, drive: String) -> [String] {
        switch payload {
        case .local:
            return [
                "The installer app already on this Mac is used directly — nothing is downloaded",
                "\(drive) is erased and the installer is written to it — "
                    + "macOS asks for your password here, see the note below",
            ]
        case .needsDownload:
            return [
                "The installer downloads from Apple (this is the slow part)",
                "The download is checked to make sure it arrived intact",
                "The installer app is installed — macOS asks for your password here, see the note below",
                "\(drive) is erased and the installer is written to it — "
                    + "macOS may ask for your password again here",
            ]
        }
    }

    private static func after(
        target: TargetMac,
        installerName: String
    ) -> [GuidanceSection] {
        // createinstallmedia always renames the finished volume to this, no
        // matter what it was called before — so this is derived, never passed in.
        let volume = "Install \(installerName)"
        let securitySection = target.requiresStartupSecurityUtility ? [startupSecuritySection()] : []

        // Security BEFORE boot, not after: a T2 Mac is guaranteed not to
        // list the drive until Startup Security Utility is changed, and
        // `bootSection`'s own steps state selecting the drive as a certainty
        // ("Select \"\(volume)\" and press Return"), not a maybe. Printing
        // that certainty before the one section that explains why it might
        // not hold yet told a T2 user to do something the next section
        // admitted they couldn't — this order states the precondition first.
        return [readySection(volume: volume)]
            + securitySection
            + [bootSection(target: target, volume: volume), troubleshootingSection()]
    }

    private static func readySection(volume: String) -> GuidanceSection {
        GuidanceSection(
            heading: "Your installer is ready",
            body: [
                "The USB drive is now named \"\(volume)\". "
                    + "That is the name you'll look for when starting up.",
            ]
        )
    }

    /// The first step reuses `TargetMac.bootMethod` rather than restating the
    /// power-button-vs-Option-key fact here — that fact already has one home.
    private static func bootSection(target: TargetMac, volume: String) -> GuidanceSection {
        let commonSteps = [
            "Shut the other Mac down completely",
            "Plug this USB drive directly into that Mac — not through a hub",
            target.bootMethod,
        ]

        let targetSteps: [String]
        switch target {
        case .appleSilicon:
            targetSteps = [
                "Click \"\(volume)\", then click Continue",
                "Follow the instructions on screen to install macOS",
            ]
        case .intelT2, .intelPreT2:
            targetSteps = [
                "Select \"\(volume)\" and press Return",
                "Choose your language if asked",
                "Select \"Install macOS\" and click Continue",
            ]
        }

        return GuidanceSection(heading: "Starting up from the drive", steps: commonSteps + targetSteps)
    }

    private static func startupSecuritySection() -> GuidanceSection {
        GuidanceSection(
            heading: "One extra step for your Mac",
            body: [
                "Intel Macs with a T2 security chip refuse to start from a USB drive "
                    + "until you allow it.",
            ],
            steps: [
                // An instruction, not a fallback: this section now runs
                // BEFORE "Starting up from the drive" (see `after(target:installerName:)`),
                // so a T2 Mac has not yet had a chance to show the drive when
                // this step runs — "if it doesn't appear" would hedge a thing
                // that, for this target, is certain.
                "Hold Command-R at startup to reach Startup Security Utility",
                "From the menu bar choose Utilities, then Startup Security Utility",
                "If asked to unlock it, select a user and enter that Mac's administrator password",
                "Set \"Allow booting from external or removable media\"",
                "Restart and hold Option again",
            ]
        )
    }

    private static func troubleshootingSection() -> GuidanceSection {
        GuidanceSection(
            heading: "If something goes wrong",
            body: [
                "If you see a circle with a line through it, that macOS version "
                    + "cannot run on that Mac. You'll need a different version.",
                "If the drive doesn't appear at all, try a different USB port, "
                    + "and plug it in directly rather than through a hub or dock.",
            ]
        )
    }
}
