import Foundation
import Testing
@testable import MacOSInstallerKit

/// Ported from the deleted `PreparationErrorFormatterTests`. `DigestError` is
/// raised from `DigestVerifier.swift:26/43`, entirely before
/// `InstallMediaWriter` is ever constructed, so every case can truthfully say
/// the drive was not touched.
@Test("a digest mismatch states plainly that the drive was not touched")
func digestMismatchStatesDriveNotTouched() {
    let rendered = DigestError.mismatch(expected: "aaaa", actual: "bbbb").explanation.rendered()

    #expect(rendered.contains("The drive was not touched"))
}

@Test("a digest mismatch mentions the corrupted file was deleted")
func digestMismatchMentionsDeletion() {
    let rendered = DigestError.mismatch(expected: "aaaa", actual: "bbbb").explanation.rendered()

    #expect(rendered.contains("deleted"))
}

@Test("an unreadable download states plainly that the drive was not touched")
func digestUnreadableStatesDriveNotTouched() {
    let rendered = DigestError.unreadable("/tmp/InstallAssistant-25G229.pkg").explanation.rendered()

    #expect(rendered.contains("The drive was not touched"))
    #expect(rendered.contains("/tmp/InstallAssistant-25G229.pkg"))
}

@Test("a DigestError's technical detail names its own case and carries its payload")
func digestErrorTechnicalDetailNamesEveryCase() {
    #expect(DigestError.mismatch(expected: "aaaa", actual: "bbbb").technicalDetail.contains("expected=aaaa"))
    #expect(DigestError.unreadable("/x").technicalDetail.contains("/x"))
}
