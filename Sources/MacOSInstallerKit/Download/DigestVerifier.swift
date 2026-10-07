import CryptoKit
import Foundation

public enum DigestError: Error, Equatable {
    case mismatch(expected: String, actual: String)
    case unreadable(String)
}

/// Both cases are raised from `DigestVerifier.verify`, which runs strictly
/// before `InstallerPreparer` moves on to assembly and long before
/// `InstallMediaWriter` is ever constructed — so both can truthfully say the
/// drive was not touched, and must say so explicitly, because by the time
/// this runs the user has already confirmed the erase.
extension DigestError: Explainable {
    public var explanation: UserFacingError {
        switch self {
        case .mismatch(let expected, let actual):
            return UserFacingError(
                title: "The download didn't match Apple's published digest",
                whatHappened: "The downloaded installer package did not match the digest Apple "
                    + "publishes for it (expected \(expected), got \(actual)). The drive was not touched.",
                whatItMeans: "The file has been deleted, so it will be downloaded again next time "
                    + "rather than reused. This usually means the download was corrupted in transit.",
                whatToDoNext: [
                    "Run this command again to download a fresh copy",
                    "If it keeps failing, check your internet connection",
                ]
            )

        case .unreadable(let path):
            return UserFacingError(
                title: "The downloaded file couldn't be read",
                whatHappened: "Could not read the downloaded file at \(path) to verify it. "
                    + "The drive was not touched.",
                whatItMeans: "The file may have been moved, deleted, or lost its read permissions "
                    + "after it was downloaded.",
                whatToDoNext: [
                    "Run this command again to download a fresh copy",
                ]
            )
        }
    }

    public var technicalDetail: String {
        switch self {
        case .mismatch(let expected, let actual):
            return "DigestError.mismatch expected=\(expected) actual=\(actual)"
        case .unreadable(let path):
            return "DigestError.unreadable path=\(path)"
        }
    }
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
