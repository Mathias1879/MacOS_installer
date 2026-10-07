import Foundation
import MacOSInstallerKit

/// Prints guidance. Owns no content and makes no decisions.
///
/// `targetMac` names which Mac will boot the finished installer — distinct
/// from `CreateCommand`'s own `target`, which is the `Volume` being erased.
/// `originalDriveName` is the drive's name before this tool touched it;
/// `GuidanceCatalog` reads it only for `.during` and ignores it for every
/// other stage (see `GuidanceCatalog.sections(for:target:installerName:originalDriveName:)`),
/// so callers pass `nil` for `.before` and `.after`.
enum WalkthroughPresenter {
    static func show(
        _ stage: GuidanceStage,
        targetMac: TargetMac,
        installerName: String,
        originalDriveName: String?,
        payload: GuidanceCatalog.DuringPayloadKind = .needsDownload,
        emit: (String) -> Void = { Swift.print($0) }
    ) {
        let sections = GuidanceCatalog.sections(
            for: stage, target: targetMac, installerName: installerName,
            originalDriveName: originalDriveName, payload: payload
        )
        emit("")
        emit(GuidanceRenderer.render(sections))
        emit("")
    }
}
