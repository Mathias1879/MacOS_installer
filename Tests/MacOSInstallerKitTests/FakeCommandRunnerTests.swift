import Testing
@testable import MacOSInstallerKit

@Test("stubbed command line returns its stubbed result")
func stubbedCommandReturnsResult() throws {
    let fake = FakeCommandRunner()
    let expected = CommandResult(
        exitCode: 42,
        standardOutput: "output",
        standardError: "error"
    )

    fake.stub(expected, for: "/usr/bin/test arg1 arg2")
    let result = try fake.run("/usr/bin/test", ["arg1", "arg2"])

    #expect(result == expected)
}

@Test("unstubbed command returns empty default result")
func unstubbedCommandReturnsDefault() throws {
    let fake = FakeCommandRunner()

    let result = try fake.run("/usr/bin/unknown", ["arg"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "")
    #expect(result.standardError == "")
}

@Test("invocations records executable and arguments in order")
func invocationsRecordsInOrder() throws {
    let fake = FakeCommandRunner()

    _ = try fake.run("/bin/echo", ["hello"])
    _ = try fake.run("/usr/bin/true", [])
    _ = try fake.run("/bin/test", ["arg1", "arg2"])

    #expect(fake.invocations.count == 3)
    #expect(fake.invocations[0].executable == "/bin/echo")
    #expect(fake.invocations[0].arguments == ["hello"])
    #expect(fake.invocations[1].executable == "/usr/bin/true")
    #expect(fake.invocations[1].arguments == [])
    #expect(fake.invocations[2].executable == "/bin/test")
    #expect(fake.invocations[2].arguments == ["arg1", "arg2"])
}

@Test("didInvoke returns true for fragment that was run")
func didInvokeReturnsTrueForMatching() throws {
    let fake = FakeCommandRunner()

    _ = try fake.run("/usr/sbin/softwareupdate", ["--list-full-installers"])
    _ = try fake.run("/bin/echo", ["test"])

    #expect(fake.didInvoke(containing: "softwareupdate"))
    #expect(fake.didInvoke(containing: "--list-full-installers"))
    #expect(fake.didInvoke(containing: "echo"))
}

@Test("didInvoke returns false for fragment that was not run")
func didInvokeReturnsFalseForNonMatching() throws {
    let fake = FakeCommandRunner()

    _ = try fake.run("/usr/sbin/softwareupdate", ["--list-full-installers"])

    #expect(!fake.didInvoke(containing: "hdiutil"))
    #expect(!fake.didInvoke(containing: "--mount"))
    #expect(!fake.didInvoke(containing: "rm"))
}

@Test("stub convenience method with standardOutput")
func stubConvenienceMethod() throws {
    let fake = FakeCommandRunner()

    fake.stub(standardOutput: "success output", for: "/usr/bin/test arg")
    let result = try fake.run("/usr/bin/test", ["arg"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "success output")
    #expect(result.standardError == "")
}
