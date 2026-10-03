import Foundation
import Testing
@testable import MacOSInstallerKit

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("writes a dated file and returns the path to show the user")
func writesDatedFile() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let fixed = Date(timeIntervalSince1970: 1_790_000_000)  // a fixed instant
    let log = DiagnosticLog(directory: dir, clock: { fixed })

    let shown = log.record("createinstallmedia exited 1\nstderr: could not erase")

    let expectedName = DateFormatter.logDateFormatter.string(from: fixed) + ".log"
    let file = dir.appendingPathComponent(expectedName)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(shown?.hasSuffix(expectedName) == true)

    let contents = try String(contentsOf: file, encoding: .utf8)
    #expect(contents.contains("createinstallmedia exited 1"))
    #expect(contents.contains("could not erase"))
}

@Test("appends rather than truncating, so a session's failures accumulate")
func appendsAcrossCalls() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let fixed = Date(timeIntervalSince1970: 1_790_000_000)
    let log = DiagnosticLog(directory: dir, clock: { fixed })

    _ = log.record("first failure")
    _ = log.record("second failure")

    let file = dir.appendingPathComponent(DateFormatter.logDateFormatter.string(from: fixed) + ".log")
    let contents = try String(contentsOf: file, encoding: .utf8)
    #expect(contents.contains("first failure"))
    #expect(contents.contains("second failure"))
}

@Test("timestamps each entry so entries can be correlated with a run")
func timestampsEntries() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let fixed = Date(timeIntervalSince1970: 1_790_000_000)
    let log = DiagnosticLog(directory: dir, clock: { fixed })

    _ = log.record("something")

    let file = dir.appendingPathComponent(DateFormatter.logDateFormatter.string(from: fixed) + ".log")
    let contents = try String(contentsOf: file, encoding: .utf8)

    // Exact, not a substring that almost anything would satisfy.
    let expected = ISO8601DateFormatter().string(from: fixed)
    #expect(contents.contains(expected), "entry header should contain \(expected)")
}

@Test("returns nil rather than throwing when the log cannot be written")
func survivesUnwritableDirectory() {
    // A path under a file, so directory creation cannot succeed.
    let unwritable = URL(fileURLWithPath: "/dev/null/macos-installer-logs")
    let log = DiagnosticLog(directory: unwritable, clock: { Date() })

    // Logging is a convenience. Failing to log must never mask the real error
    // the caller is in the middle of reporting.
    #expect(log.record("detail") == nil)
}

@Test("abbreviates a home-relative path for display")
func abbreviatesHomePath() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let inside = home.appendingPathComponent("Library/Logs/macos-installer/x.log")

    #expect(DiagnosticLog.displayPath(for: inside) == "~/Library/Logs/macos-installer/x.log")
}

@Test("leaves a sibling path alone when it only shares the home prefix's characters")
func doesNotMangleSiblingPath() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    // A sibling directory whose name extends the home directory's name.
    let sibling = URL(fileURLWithPath: home + "extra/foo.log")

    #expect(DiagnosticLog.displayPath(for: sibling) == sibling.path)
}

@Test("abbreviates the home directory itself to a bare tilde")
func abbreviatesHomeItself() {
    let home = FileManager.default.homeDirectoryForCurrentUser

    #expect(DiagnosticLog.displayPath(for: home) == "~")
}
