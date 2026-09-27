import Foundation

/// Finds installer applications already present on disk. Reusing one avoids a
/// multi-gigabyte download when re-flashing a drive, which is the common case
/// once the tool is in regular use.
public struct LocalInstallerSource: InstallerSource {
    public static let defaultSearchDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications")
    ]

    public let origin: InstallerRelease.Origin = .local

    private let searchDirectories: [URL]
    private let listDirectory: @Sendable (URL) -> [URL]
    private let measureSize: @Sendable (URL) -> Int64

    public init(
        searchDirectories: [URL] = LocalInstallerSource.defaultSearchDirectories,
        listDirectory: (@Sendable (URL) -> [URL])? = nil,
        measureSize: (@Sendable (URL) -> Int64)? = nil
    ) {
        self.searchDirectories = searchDirectories
        self.listDirectory = listDirectory ?? { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        self.measureSize = measureSize ?? { url in
            (try? FileManager.default.allocatedSize(ofDirectoryAt: url)) ?? 0
        }
    }

    public func availableReleases() async throws -> [InstallerRelease] {
        searchDirectories
            .flatMap(candidateApplications(in:))
            .compactMap(release(forApplicationAt:))
            .sorted { $0.version > $1.version }
    }

    private func candidateApplications(in directory: URL) -> [URL] {
        let entries = listDirectory(directory)

        return entries.filter {
            $0.pathExtension == "app" && $0.lastPathComponent.hasPrefix("Install macOS")
        }.map { url in
            let standardized = url.standardizedFileURL
            return removingTrailingSlash(from: standardized)
        }
    }

    private func release(forApplicationAt app: URL) -> InstallerRelease? {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")

        guard
            let data = try? Data(contentsOf: infoURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let info = plist as? [String: Any],
            let name = info["CFBundleDisplayName"] as? String,
            let versionString = info["DTPlatformVersion"] as? String,
            let version = OSVersion(versionString),
            let build = info["DTSDKBuild"] as? String
        else { return nil }

        let size = measureSize(app)

        // Fail-closed: skip if computed size is 0 (indicates unreadable bundle)
        guard size > 0 else { return nil }

        let normalizedApp = removingTrailingSlash(from: app)

        return InstallerRelease(
            name: name,
            version: version,
            build: build,
            sizeBytes: size,
            origin: .local,
            payload: .localApplication(path: normalizedApp)
        )
    }

    /// Removes trailing slash from a file URL path if present.
    private func removingTrailingSlash(from url: URL) -> URL {
        if url.path.hasSuffix("/") {
            return URL(fileURLWithPath: String(url.path.dropLast()))
        }
        return url
    }
}

extension FileManager {
    /// Sums the allocated size of every regular file beneath `url`.
    func allocatedSize(ofDirectoryAt url: URL) throws -> Int64 {
        guard let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
