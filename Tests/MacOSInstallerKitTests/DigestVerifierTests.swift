import Foundation
import Testing
@testable import MacOSInstallerKit

private func fileContaining(_ text: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try Data(text.utf8).write(to: url)
    return url
}

@Test("computes the SHA-1 of a file")
func computesKnownSHA1() throws {
    let url = try fileContaining("abc")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try DigestVerifier.sha1Hex(ofFileAt: url) == "a9993e364706816aba3e25717850c26c9cd0d89d")
}

@Test("accepts a file whose digest matches, ignoring case")
func acceptsMatchingDigest() throws {
    let url = try fileContaining("abc")
    defer { try? FileManager.default.removeItem(at: url) }

    try DigestVerifier.verify(fileAt: url, matches: "A9993E364706816ABA3E25717850C26C9CD0D89D")
}

@Test("reports mismatch with both digests so a corrupt download is diagnosable")
func reportsMismatch() throws {
    let url = try fileContaining("abc")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: DigestError.mismatch(
        expected: "0000000000000000000000000000000000000000",
        actual: "a9993e364706816aba3e25717850c26c9cd0d89d"
    )) {
        try DigestVerifier.verify(fileAt: url, matches: "0000000000000000000000000000000000000000")
    }
}

@Test("reports unreadable for a file that does not exist")
func reportsUnreadable() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")

    #expect(throws: DigestError.self) {
        _ = try DigestVerifier.sha1Hex(ofFileAt: missing)
    }
}

@Test("hashes a file larger than one read chunk correctly")
func hashesMultiChunkFile() throws {
    // 3 MB of a repeating byte, larger than the 1 MB read buffer.
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x41, count: 3 * 1024 * 1024).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let streamed = try DigestVerifier.sha1Hex(ofFileAt: url)

    // Compare against hashing the whole thing in memory.
    #expect(streamed == DigestVerifier.sha1Hex(of: try Data(contentsOf: url)))
}
