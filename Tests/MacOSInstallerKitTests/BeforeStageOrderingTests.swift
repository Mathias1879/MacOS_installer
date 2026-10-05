import Foundation
import Testing
@testable import MacOSInstallerKit

/// Pins the ORDER `BeforeStageOrdering.announceThenObserve` runs its two
/// closures in — not merely that both ran. Asserting only "both happened"
/// would pass under the exact defect this type exists to prevent: the Before
/// stage told the user to plug in a drive, and volume enumeration ran from a
/// snapshot taken before that instruction was shown, so a user who plugged a
/// drive in right then never saw it in the list that followed.
///
/// `observe` here is wired to a real `DiskEnumerator` over a `FakeCommandRunner`
/// — the actual production shape (see `CreateCommand.execute()`), not a bare
/// closure standing in for it — so this also demonstrates the seam the fix
/// round asked for: a recording fake for the enumerator's `CommandRunner`.
private let emptyDiskListPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AllDisks</key>
  <array></array>
</dict>
</plist>
"""

@Test("announces before observing, in that order — never the reverse")
func announceRunsStrictlyBeforeObserve() throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: emptyDiskListPlist, for: "/usr/sbin/diskutil list -plist")

    var events: [String] = []

    let result = try BeforeStageOrdering.announceThenObserve(
        announce: {
            events.append("before-stage-shown")
        },
        observe: {
            events.append("volume-enumeration-ran")
            return try DiskEnumerator(runner: runner).mountedVolumes()
        }
    )

    // The order, not just the membership: this is what would stay green
    // under the regression (enumerate-then-announce) if it only checked
    // that both strings appeared somewhere in `events`.
    #expect(events == ["before-stage-shown", "volume-enumeration-ran"])
    #expect(result.volumes.isEmpty)
    #expect(runner.didInvoke(containing: "diskutil list -plist"))
}

@Test("the announcement's effect is visible before the enumerator's command ever runs")
func announcementPrecedesTheUnderlyingCommandInvocation() throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: emptyDiskListPlist, for: "/usr/sbin/diskutil list -plist")

    var announced = false

    _ = try BeforeStageOrdering.announceThenObserve(
        announce: {
            announced = true
        },
        observe: {
            // If this closure's invocation of DiskEnumerator ran first, the
            // flag would still be false right here — this is the same
            // "snapshot taken before the instruction was shown" failure mode
            // described in task-8-fix-1.md, reproduced at the seam instead of
            // through the full `create` command.
            #expect(announced)
            return try DiskEnumerator(runner: runner).mountedVolumes()
        }
    )

    #expect(runner.invocations.count == 1)
}
