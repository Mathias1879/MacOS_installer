import Foundation
import Testing
@testable import MacOSInstallerKit

/// `InstallerPreparationError`'s two cases are both raised from `prepare`'s
/// initial `switch`, before any download or assembly step runs — the user has
/// already confirmed the erase by this point, so each explanation must say so
/// explicitly rather than relying on it being implied.
private let preparationErrors: [InstallerPreparationError] = [
    .legacyAssemblyNotSupported,
    .softwareUpdateOnly(version: "26.7"),
]

@Test("every InstallerPreparationError explanation states the drive was not touched")
func preparationErrorsSayDriveUntouched() {
    for error in preparationErrors {
        let rendered = error.explanation.rendered().lowercased()
        #expect(rendered.contains("not touched"), "\(error) must state the drive was not touched")
    }
}

/// Ported from the deleted `PreparationErrorFormatterTests`'
/// `installerPreparationErrorUsesItsOwnMessage`. The original asserted the
/// formatter added no extra "not touched" suffix to `userMessage`, because
/// that guarantee did not exist yet for this type. It now does (see above),
/// so the ported assertion instead pins that each case keeps its own
/// distinguishing wording in the new three-part shape rather than being
/// replaced by a generic message.
@Test("legacyAssemblyNotSupported's explanation keeps its own wording")
func legacyAssemblyNotSupportedKeepsItsOwnWording() {
    let rendered = InstallerPreparationError.legacyAssemblyNotSupported.explanation.rendered()
    #expect(rendered.contains("not supported yet"))
}

@Test("softwareUpdateOnly's explanation keeps its own wording")
func softwareUpdateOnlyKeepsItsOwnWording() {
    let rendered = InstallerPreparationError.softwareUpdateOnly(version: "26.7").explanation.rendered()
    #expect(rendered.contains("softwareupdate --fetch-full-installer"))
}

@Test("an InstallerPreparationError's technical detail names its own case")
func technicalDetailNamesTheCase() {
    #expect(InstallerPreparationError.legacyAssemblyNotSupported.technicalDetail.contains("legacyAssemblyNotSupported"))
    #expect(
        InstallerPreparationError.softwareUpdateOnly(version: "26.7").technicalDetail.contains("26.7")
    )
}
