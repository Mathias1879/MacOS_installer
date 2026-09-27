import Foundation
import Testing
@testable import MacOSInstallerKit

@Test("refuses to run as root")
func refusesRoot() {
    #expect(throws: PrivilegeError.runningAsRoot) {
        try PrivilegeCheck.assertNotRoot(effectiveUserID: 0)
    }
}

@Test("permits a normal user")
func permitsNormalUser() throws {
    try PrivilegeCheck.assertNotRoot(effectiveUserID: 501)
}
