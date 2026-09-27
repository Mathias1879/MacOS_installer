import Foundation

/// Errors specific to running `softwareupdate`. A non-zero exit is a genuine
/// failure to reach the tool, distinguished from a zero exit that legitimately
/// lists no installers (e.g. on an Apple silicon Mac where none apply).
public enum SoftwareUpdateSourceError: Error, Equatable, Sendable {
    case commandFailed(exitCode: Int32, message: String)
}

/// Reads `softwareupdate --list-full-installers`. Apple filters this list to
/// versions the *host* model supports, so it is a fallback rather than the
/// primary source. Line format verified on macOS 27.0, 2026-09-26:
/// `* Title: macOS Tahoe, Version: 26.7, Size: 17951133KiB, Build: 25G229, Deferred: NO`
public struct SoftwareUpdateSource: InstallerSource {
    public static let executablePath = "/usr/sbin/softwareupdate"

    public let origin: InstallerRelease.Origin = .softwareUpdate

    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    public func availableReleases() async throws -> [InstallerRelease] {
        let result = try runner.run(Self.executablePath, ["--list-full-installers"])

        guard result.exitCode == 0 else {
            throw SoftwareUpdateSourceError.commandFailed(
                exitCode: result.exitCode,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { Self.parseLine(String($0)) }
            .sorted { $0.version > $1.version }
    }

    static func parseLine(_ line: String) -> InstallerRelease? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("* ") else { return nil }

        // Split "Title: X, Version: Y, Size: ZKiB, Build: B, Deferred: NO"
        // into its labelled fields.
        var fields: [String: String] = [:]
        for segment in trimmed.dropFirst(2).components(separatedBy: ", ") {
            let parts = segment.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1]
        }

        guard
            let title = fields["Title"],
            let versionString = fields["Version"],
            let version = OSVersion(versionString),
            let build = fields["Build"],
            let kibibytes = Int64(fields["Size"]?.replacingOccurrences(of: "KiB", with: "") ?? "")
        else { return nil }

        return InstallerRelease(
            name: title,
            version: version,
            build: build,
            sizeBytes: kibibytes * 1024,
            origin: .softwareUpdate,
            payload: .softwareUpdate(version: versionString)
        )
    }
}
