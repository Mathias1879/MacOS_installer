import Foundation

public enum AssemblyError: Error, Equatable {
    case installerFailed(exitCode: Int32, message: String)
    case applicationNotFound(String)
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
