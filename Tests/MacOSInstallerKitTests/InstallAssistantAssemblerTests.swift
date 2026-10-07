import Foundation
import Testing
@testable import MacOSInstallerKit

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("invokes sudo installer with the package and a root target")
func invokesInstaller() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let pkg = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("pkg".utf8).write(to: pkg)
    let appDir = dir.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(
        at: appDir.appendingPathComponent("Install macOS Tahoe.app"), withIntermediateDirectories: true
    )

    let runner = FakeCommandRunner()
    runner.stub(standardOutput: "installer: The install was successful.",
                for: "/usr/bin/sudo /usr/sbin/installer -pkg \(pkg.path) -target /")

    let app = try InstallAssistantAssembler(runner: runner, applicationsDirectory: appDir)
        .assemble(payloadAt: pkg, expectedAppName: "Install macOS Tahoe")

    #expect(app.lastPathComponent == "Install macOS Tahoe.app")
    #expect(runner.invocations.count == 1)
    #expect(runner.invocations[0].executable == "/usr/bin/sudo")
    #expect(runner.invocations[0].arguments == ["/usr/sbin/installer", "-pkg", pkg.path, "-target", "/"])
}

@Test("passes the package path as one argument even when it contains spaces")
func handlesSpacesInPath() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let spaced = dir.appendingPathComponent("My Downloads")
    try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
    let pkg = spaced.appendingPathComponent("InstallAssistant.pkg")
    try Data("pkg".utf8).write(to: pkg)
    let appDir = dir.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(
        at: appDir.appendingPathComponent("Install macOS Tahoe.app"), withIntermediateDirectories: true
    )

    let runner = FakeCommandRunner()
    runner.stub(standardOutput: "ok", for: "/usr/bin/sudo /usr/sbin/installer -pkg \(pkg.path) -target /")

    _ = try InstallAssistantAssembler(runner: runner, applicationsDirectory: appDir)
        .assemble(payloadAt: pkg, expectedAppName: "Install macOS Tahoe")

    // The path must arrive as a single argv element, unquoted and unsplit.
    #expect(runner.invocations[0].arguments[2] == pkg.path)
    #expect(runner.invocations[0].arguments[2].contains(" "))
}

@Test("throws installerFailed carrying the exit code and stderr")
func throwsWhenInstallerFails() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let pkg = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("pkg".utf8).write(to: pkg)

    let runner = FakeCommandRunner()
    runner.stub(
        CommandResult(exitCode: 1, standardOutput: "", standardError: "package is not signed"),
        for: "/usr/bin/sudo /usr/sbin/installer -pkg \(pkg.path) -target /"
    )

    #expect(throws: AssemblyError.installerFailed(exitCode: 1, message: "package is not signed")) {
        _ = try InstallAssistantAssembler(runner: runner, applicationsDirectory: dir)
            .assemble(payloadAt: pkg, expectedAppName: "Install macOS Tahoe")
    }
}

@Test("throws applicationNotFound when installer succeeds but the app is absent")
func throwsWhenAppMissing() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let pkg = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("pkg".utf8).write(to: pkg)
    let appDir = dir.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

    let runner = FakeCommandRunner()
    runner.stub(standardOutput: "ok", for: "/usr/bin/sudo /usr/sbin/installer -pkg \(pkg.path) -target /")

    #expect(throws: AssemblyError.applicationNotFound("Install macOS Tahoe")) {
        _ = try InstallAssistantAssembler(runner: runner, applicationsDirectory: appDir)
            .assemble(payloadAt: pkg, expectedAppName: "Install macOS Tahoe")
    }
}
