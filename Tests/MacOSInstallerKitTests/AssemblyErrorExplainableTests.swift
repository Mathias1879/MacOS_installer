import Foundation
import Testing
@testable import MacOSInstallerKit

/// Ported from the deleted `PreparationErrorFormatterTests`. `AssemblyError`
/// is raised from `InstallAssistantAssembler.swift:38/46`, entirely before
/// `InstallMediaWriter` is ever constructed, so every case can truthfully say
/// the drive was not touched.
@Test("an assembly failure states plainly that the drive was not touched")
func assemblyFailureStatesDriveNotTouched() {
    let rendered = AssemblyError.installerFailed(exitCode: 1, message: "installer: failed").explanation.rendered()

    #expect(rendered.contains("The drive was not touched"))
    #expect(rendered.contains("installer: failed"))
}

@Test("an application-not-found assembly failure states plainly that the drive was not touched")
func applicationNotFoundStatesDriveNotTouched() {
    let rendered = AssemblyError.applicationNotFound("Install macOS Tahoe").explanation.rendered()

    #expect(rendered.contains("The drive was not touched"))
    #expect(rendered.contains("Install macOS Tahoe"))
}

@Test("an AssemblyError's technical detail names its own case and carries its payload")
func assemblyErrorTechnicalDetailNamesEveryCase() {
    #expect(
        AssemblyError.installerFailed(exitCode: 1, message: "installer: failed").technicalDetail
            .contains("exitCode=1")
    )
    #expect(AssemblyError.applicationNotFound("Install macOS Tahoe").technicalDetail.contains("Install macOS Tahoe"))
}
