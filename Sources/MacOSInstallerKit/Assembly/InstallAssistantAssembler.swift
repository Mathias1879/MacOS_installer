import Foundation

public enum AssemblyError: Error, Equatable {
    case installerFailed(exitCode: Int32, message: String)
    case applicationNotFound(String)
}

/// Both cases are raised from `InstallAssistantAssembler.assemble`, which
/// installs the downloaded package into `/Applications` — entirely separate
/// from, and strictly before, `InstallMediaWriter` is ever constructed. So
/// both can truthfully say the drive was not touched, and must say so
/// explicitly, because by the time this runs the user has already confirmed
/// the erase.
extension AssemblyError: Explainable {
    // `.installerFailed` deliberately does not bind `exitCode` or `message`
    // here (I6 of the final fix round) — matching the standard
    // `MediaWriteError.writeToolDidNotLaunch` and `.authenticationFailed`
    // already set: raw stderr from `installer` reads as a crash dump to
    // someone who has never opened Terminal. Both payloads still reach
    // `technicalDetail` below, in full.
    public var explanation: UserFacingError {
        switch self {
        case .installerFailed:
            return UserFacingError(
                title: "Installing the installer app failed",
                whatHappened: "Assembling the installer application failed. The drive was not touched.",
                whatItMeans: "The `installer` tool macOS uses to unpack the downloaded package "
                    + "exited with an error before it finished.",
                whatToDoNext: [
                    "Run this command again",
                    "If it keeps failing, check that you have enough free space in /Applications",
                ]
            )

        case .applicationNotFound(let name):
            return UserFacingError(
                title: "The installer app wasn't where it should be",
                whatHappened: "The installer application \"\(name)\" was not found after assembly "
                    + "completed. The drive was not touched.",
                whatItMeans: "Assembly reported success but the expected app isn't in /Applications, "
                    + "which usually means the release name doesn't match what Apple's installer "
                    + "actually produces.",
                whatToDoNext: [
                    "Check /Applications for an installer app under a different name",
                    "Run this command again",
                ]
            )
        }
    }

    public var technicalDetail: String {
        switch self {
        case .installerFailed(let exitCode, let message):
            return "AssemblyError.installerFailed exitCode=\(exitCode) message=\(message)"
        case .applicationNotFound(let name):
            return "AssemblyError.applicationNotFound name=\(name)"
        }
    }
}

/// Applies `InstallAssistant.pkg` with `installer`, which writes
/// `Install macOS X.app` into /Applications.
///
/// `installer` verifies the package's Apple signature as part of applying it,
/// which is where authenticity is actually established — the catalog's SHA-1
/// digest only proves the bytes arrived intact.
public struct InstallAssistantAssembler: AssemblyStrategy {
    public static let sudoPath = "/usr/bin/sudo"
    public static let installerPath = "/usr/sbin/installer"

    private let runner: any CommandRunner
    private let applicationsDirectory: URL

    public init(
        runner: any CommandRunner,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications")
    ) {
        self.runner = runner
        self.applicationsDirectory = applicationsDirectory
    }

    public func assemble(payloadAt payload: URL, expectedAppName: String) throws -> URL {
        // Arguments are passed as separate argv elements. Paths routinely
        // contain spaces; assembling a shell string here would break them.
        let result = try runner.run(
            Self.sudoPath,
            [Self.installerPath, "-pkg", payload.path, "-target", "/"]
        )

        guard result.exitCode == 0 else {
            throw AssemblyError.installerFailed(
                exitCode: result.exitCode,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let app = applicationsDirectory.appendingPathComponent("\(expectedAppName).app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw AssemblyError.applicationNotFound(expectedAppName)
        }

        return app
    }
}
