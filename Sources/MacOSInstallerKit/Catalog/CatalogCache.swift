import Foundation

/// A small on-disk cache with a fixed TTL. The clock is injected so expiry is
/// testable without sleeping.
public struct CatalogCache {
    public static let ttl: TimeInterval = 86_400

    private let directory: URL
    private let clock: () -> Date

    public init(directory: URL, clock: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.clock = clock
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("macos-installer", isDirectory: true)
    }

    public func load(key: String) -> Data? {
        let entry = directory.appendingPathComponent(key)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path),
            let modified = attributes[.modificationDate] as? Date,
            clock().timeIntervalSince(modified) <= Self.ttl,
            let data = try? Data(contentsOf: entry)
        else { return nil }
        return data
    }

    public func store(_ data: Data, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = directory.appendingPathComponent(key)
        try data.write(to: entry, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: clock()], ofItemAtPath: entry.path)
    }
}
