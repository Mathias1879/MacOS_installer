import Foundation

public enum DiskEnumeratorError: Error, Equatable {
    case listFailed(String)
}

/// Lists volumes via `diskutil`. A volume whose details cannot be read is
/// skipped rather than failing the listing — one unreadable disk must not stop
/// the user seeing the others.
public struct DiskEnumerator {
    public static let diskutilPath = "/usr/sbin/diskutil"

    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    public func mountedVolumes() throws -> [Volume] {
        let listed = try runner.run(Self.diskutilPath, ["list", "-plist"])

        guard listed.exitCode == 0 else {
            throw DiskEnumeratorError.listFailed(
                "diskutil exited \(listed.exitCode): "
                    + listed.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let identifiers: [String]
        do {
            identifiers = try DiskutilClient.parseVolumeIdentifiers(Data(listed.standardOutput.utf8))
        } catch {
            throw DiskEnumeratorError.listFailed("unparsable diskutil output: \(error)")
        }

        return identifiers.compactMap { identifier in
            guard
                let info = try? runner.run(Self.diskutilPath, ["info", "-plist", identifier]),
                info.exitCode == 0,
                let volume = try? DiskutilClient.parseInfo(Data(info.standardOutput.utf8))
            else { return nil }
            return volume
        }
    }
}
