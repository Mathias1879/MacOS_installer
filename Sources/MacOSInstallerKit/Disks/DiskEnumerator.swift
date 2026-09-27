import Foundation

public enum DiskEnumeratorError: Error, Equatable {
    case listFailed(String)
}

/// Lists volumes via `diskutil`. A volume whose details cannot be read is
/// skipped rather than failing the listing — one unreadable disk must not stop
/// the user seeing the others.
public struct DiskEnumerator {
    public static let diskutilPath = "/usr/sbin/diskutil"

    public struct Result: Sendable {
        public let volumes: [Volume]
        /// One entry per identifier that could not be read, so the caller can
        /// tell "that drive isn't attached" from "we could not read it".
        public let failures: [String]

        public init(volumes: [Volume], failures: [String]) {
            self.volumes = volumes
            self.failures = failures
        }
    }

    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    public func mountedVolumes() throws -> Result {
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

        var volumes: [Volume] = []
        var failures: [String] = []

        for identifier in identifiers {
            guard let info = try? runner.run(Self.diskutilPath, ["info", "-plist", identifier]) else {
                failures.append("\(identifier): failed to run diskutil info")
                continue
            }

            guard info.exitCode == 0 else {
                let errorMsg = info.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                failures.append("\(identifier): diskutil info exited \(info.exitCode): \(errorMsg)")
                continue
            }

            do {
                let volume = try DiskutilClient.parseInfo(Data(info.standardOutput.utf8))
                volumes.append(volume)
            } catch {
                failures.append("\(identifier): could not parse info: \(error)")
            }
        }

        return Result(volumes: volumes, failures: failures)
    }
}
