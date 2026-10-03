import Foundation
import Testing
@testable import MacOSInstallerKit

/// Partially ported from the deleted `PreparationErrorFormatterTests`'
/// `commandErrorStatesDriveNotTouched`. The old formatter appended "The drive
/// was not touched" to every `CommandError`, including this one — that was
/// the formatter's own mistake, named explicitly in this task's fix
/// instructions as something NOT to reproduce: `CommandError` comes from
/// `CommandRunner`, which anything may call, including code that runs after
/// an erase has begun. Binding a drive promise to it would hand a false
/// guarantee to any call site added later. So only the half of the old
/// assertion that is still honest — that the explanation names the failing
/// executable — is restored here. The other half (no drive claim at all) is
/// enforced, with the opposite polarity, by
/// `PreparationChainTotalityTests.commandErrorMakesNoClaimAboutTheDrive`.
@Test("a raw CommandError is rendered in plain language and names the executable")
func commandErrorNamesTheExecutable() {
    let rendered = CommandError.launchFailed(executable: "/usr/bin/curl", reason: "no such file")
        .explanation.rendered()

    #expect(rendered.contains("/usr/bin/curl"))
}

@Test("a CommandError's technical detail names its own case and carries its payload")
func commandErrorTechnicalDetailNamesEveryCase() {
    let detail = CommandError.launchFailed(executable: "/usr/bin/curl", reason: "no such file").technicalDetail

    #expect(detail.contains("/usr/bin/curl"))
    #expect(detail.contains("no such file"))
}
