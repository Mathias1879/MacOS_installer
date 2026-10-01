import CryptoKit
import Foundation

public enum DigestError: Error, Equatable {
    case mismatch(expected: String, actual: String)
    case unreadable(String)
}

/// Verifies a downloaded package against the digest Apple publishes in its
/// software update catalog.
///
/// Apple publishes SHA-1. That is an INTEGRITY check, not an authenticity one:
/// SHA-1 is collision-broken, so a matching digest proves the bytes arrived
/// intact, not that they came from Apple. Authenticity comes from the package
/// being Apple-signed, which `installer` verifies when the package is applied.
/// Do not present this check to users as a security guarantee.
public enum DigestVerifier {
    private static let chunkSize = 1 << 20

    public static func sha1Hex(of data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha1Hex(ofFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw DigestError.unreadable(url.path)
        }
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(fileAt url: URL, matches expected: String) throws {
        let actual = try sha1Hex(ofFileAt: url)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw DigestError.mismatch(expected: expected.lowercased(), actual: actual)
        }
    }
}
