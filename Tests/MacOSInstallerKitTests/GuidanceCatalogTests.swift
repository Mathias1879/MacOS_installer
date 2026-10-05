import Testing
@testable import MacOSInstallerKit

@Test("the before stage names the hardware, the erase, and the time")
func beforeStageCoversPreconditions() {
    let sections = GuidanceCatalog.sections(
        for: .before, target: .intelPreT2, installerName: "macOS Tahoe", originalDriveName: nil
    )
    let all = sections.flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n")

    #expect(all.contains("32 GB"))
    #expect(all.lowercased().contains("erase"))
    // An honest duration, so nobody assumes it has frozen after five minutes.
    #expect(all.contains("minutes") || all.contains("hour"))
}

@Test("the before stage tells the user to keep the drive plugged in and the Mac awake")
func beforeStageWarnsAgainstUnpluggingOrSleeping() {
    let sections = GuidanceCatalog.sections(
        for: .before, target: .intelPreT2, installerName: "macOS Tahoe", originalDriveName: nil
    )
    let all = sections.flatMap { $0.body + $0.steps }.joined(separator: "\n").lowercased()

    // The erase happens unattended at the very end of the 30-60 minute
    // window. Unplugging or letting the Mac sleep partway through ruins the
    // drive, and this is the only place in the happy-path text that says so
    // before the fact rather than in an error message after it.
    #expect(all.contains("plugged in"))
    #expect(all.contains("awake"))
}

@Test("the before stage explains the installer is already on the drive, not downloaded again")
func beforeStageExplainsInstallerIsAlreadyOnDrive() {
    let sections = GuidanceCatalog.sections(
        for: .before, target: .appleSilicon, installerName: "macOS Tahoe", originalDriveName: nil
    )
    let all = sections.flatMap { $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(all.contains("already on the drive"))
    #expect(all.contains("wi-fi"))
}

@Test("no stage claims the target Mac must be connected to the internet to install")
func noStageClaimsInternetIsRequired() {
    GuidanceStage.allCases.forEach(exhaustivelyCheckGuidanceStage)
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)

    for stage in GuidanceStage.allCases {
        for target in TargetMac.allCases {
            let text = GuidanceCatalog.sections(
                for: stage, target: target, installerName: "macOS Tahoe", originalDriveName: "SanDisk Ultra"
            ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

            #expect(
                text.contains("need to be connected to the internet") == false,
                "\(stage)/\(target) claims an internet connection is required to install"
            )
        }
    }
}

@Test("the during stage pre-announces the invisible password and the permission dialog")
func duringStagePreAnnouncesSurprises() {
    let sections = GuidanceCatalog.sections(
        for: .during, target: .appleSilicon, installerName: "macOS Tahoe", originalDriveName: "SanDisk Ultra"
    )
    let all = sections.flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

    // Apple documents both. Announcing them afterwards is useless — the point
    // is that the user is not surprised.
    #expect(all.contains("no characters") || all.contains("nothing appear"))
    #expect(all.contains("removable volume") || all.contains("permission"))
}

@Test("the during stage lists its steps in the order they actually happen")
func duringStageStepsMatchRealOrder() {
    let sections = GuidanceCatalog.sections(
        for: .during, target: .appleSilicon, installerName: "macOS Tahoe", originalDriveName: "SanDisk Ultra"
    )
    let steps = sections.first { $0.heading == "What happens now" }?.steps

    // Pinned to the real sequence: download (InstallerPreparer.swift),
    // digest check, then assembly — where `InstallAssistantAssembler.swift`
    // invokes `sudo` for the first time and the password prompt actually
    // appears — then the write. A shape-only "password text is present"
    // assertion would not catch the password step being in the wrong
    // position, which is exactly the defect this test exists to pin.
    #expect(steps == [
        "The installer downloads from Apple (this is the slow part)",
        "The download is checked to make sure it arrived intact",
        "The installer app is installed — macOS asks for your password here, see the note below",
        "SanDisk Ultra is erased and the installer is written to it",
    ])
}

@Test("the after stage gives only the selected target's boot method")
func afterStageIsSingleTarget() {
    let silicon = GuidanceCatalog.sections(
        for: .after, target: .appleSilicon, installerName: "macOS Tahoe", originalDriveName: "SanDisk Ultra"
    ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(silicon.contains("power button"))
    // No branch for the reader to misparse.
    #expect(silicon.contains("option key") == false)

    let intel = GuidanceCatalog.sections(
        for: .after, target: .intelPreT2, installerName: "macOS Tahoe", originalDriveName: "SanDisk Ultra"
    ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(intel.contains("option"))
    #expect(intel.contains("power button") == false)
}

@Test("the after stage includes the Startup Security Utility step for a T2 target only")
func afterStageIncludesT2Caveat() {
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)

    func afterText(_ target: TargetMac) -> String {
        GuidanceCatalog.sections(
            for: .after, target: target, installerName: "macOS Tahoe", originalDriveName: "SanDisk Ultra"
        ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n")
    }

    #expect(afterText(.intelT2).contains("Startup Security Utility"))
    #expect(afterText(.appleSilicon).contains("Startup Security Utility") == false)
    #expect(afterText(.intelPreT2).contains("Startup Security Utility") == false)
}

@Test("the Startup Security Utility step warns that it may ask for the administrator password")
func startupSecuritySectionWarnsAboutPassword() {
    let all = GuidanceCatalog.sections(
        for: .after, target: .intelT2, installerName: "macOS Tahoe", originalDriveName: "SanDisk Ultra"
    ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

    // Startup Security Utility requires selecting a user and entering an
    // administrator password before its controls unlock. Without this line,
    // a first-time user who hits that prompt has no way to know it's expected.
    #expect(all.contains("administrator password"))
}

@Test("the after stage explains the circle with a line through it")
func afterStageExplainsIncompatibilitySymbol() {
    let all = GuidanceCatalog.sections(
        for: .after, target: .intelPreT2, installerName: "macOS Mojave", originalDriveName: "SanDisk Ultra"
    ).flatMap { $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(all.contains("circle with a line"))
}

@Test("the after stage always shows the post-rename name, ignoring whatever the drive was called before")
func afterStageNamesRenamedDrive() {
    let all = GuidanceCatalog.sections(
        for: .after, target: .appleSilicon, installerName: "macOS Tahoe", originalDriveName: "SanDisk Ultra"
    ).flatMap { $0.body + $0.steps }.joined(separator: "\n")

    // createinstallmedia renames the volume on success, no matter what it was
    // called before. "SanDisk Ultra" is a name the derived "Install
    // \(installerName)" string could never produce by coincidence, so this
    // proves the derived name is actually used rather than some passed-in
    // value being echoed back.
    #expect(all.contains("Install macOS Tahoe"))
    #expect(all.contains("SanDisk Ultra") == false)
}

@Test("no stage uses language that blames the reader")
func noStageBlamesTheReader() {
    GuidanceStage.allCases.forEach(exhaustivelyCheckGuidanceStage)
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)

    for stage in GuidanceStage.allCases {
        for target in TargetMac.allCases {
            let text = GuidanceCatalog.sections(
                for: stage, target: target, installerName: "macOS Tahoe", originalDriveName: "SanDisk Ultra"
            ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

            for banned in ["simply", "just ", "obviously", "merely"] {
                #expect(text.contains(banned) == false, "\(stage)/\(target) contains '\(banned)'")
            }
        }
    }
}

@Test("every stage returns at least one section for every target")
func everyStageHasContentForEveryTarget() {
    GuidanceStage.allCases.forEach(exhaustivelyCheckGuidanceStage)
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)

    for stage in GuidanceStage.allCases {
        for target in TargetMac.allCases {
            let sections = GuidanceCatalog.sections(
                for: stage, target: target, installerName: "macOS Tahoe", originalDriveName: "SanDisk Ultra"
            )
            #expect(sections.isEmpty == false, "\(stage)/\(target) has no content")
        }
    }
}

// MARK: - Exhaustiveness guards
//
// `afterStageIncludesT2Caveat` hand-enumerates all three `TargetMac` cases
// with a specific true/false expectation per case, and the loop-based tests
// above hand-iterate `GuidanceStage` and `TargetMac` together. Per this
// codebase's established pattern (see `TargetMacTests.swift` and
// `ExplanationWordingTests.swift`), each is an exhaustive `switch` with no
// `default` clause so that adding a case to either enum fails this file to
// compile until the new case is accounted for here — a hand-maintained list
// alone would let a new case ship with no guidance coverage at all.

private func exhaustivelyCheckGuidanceStage(_ stage: GuidanceStage) {
    switch stage {
    case .before: break
    case .during: break
    case .after: break
    }
}

private func exhaustivelyCheckTargetMac(_ target: TargetMac) {
    switch target {
    case .appleSilicon: break
    case .intelT2: break
    case .intelPreT2: break
    }
}
