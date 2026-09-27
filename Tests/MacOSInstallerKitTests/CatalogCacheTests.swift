import Foundation
import Testing
@testable import MacOSInstallerKit

private func tempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("returns data stored within the TTL")
func returnsFreshData() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let cache = CatalogCache(directory: dir, clock: { now })

    try cache.store(Data("catalog".utf8), key: "sucatalog")
    now = now.addingTimeInterval(3_600)   // one hour later

    #expect(cache.load(key: "sucatalog") == Data("catalog".utf8))
}

@Test("ignores data older than the 24-hour TTL")
func ignoresStaleData() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let cache = CatalogCache(directory: dir, clock: { now })

    try cache.store(Data("catalog".utf8), key: "sucatalog")
    now = now.addingTimeInterval(CatalogCache.ttl + 1)

    #expect(cache.load(key: "sucatalog") == nil)
}

@Test("data exactly at the TTL boundary is still considered fresh")
func boundaryIsFresh() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let cache = CatalogCache(directory: dir, clock: { now })

    try cache.store(Data("catalog".utf8), key: "sucatalog")
    now = now.addingTimeInterval(CatalogCache.ttl)

    #expect(cache.load(key: "sucatalog") == Data("catalog".utf8))
}

@Test("returns nil for a key that was never stored")
func missingKeyReturnsNil() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(CatalogCache(directory: dir, clock: { Date() }).load(key: "absent") == nil)
}
