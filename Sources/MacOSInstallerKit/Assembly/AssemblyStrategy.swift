import Foundation

/// Turns a downloaded payload into an `Install macOS X.app` bundle.
/// Two implementations are planned: the modern single-package path, and the
/// legacy chunked-ESD path, whose mechanics are still unspecified.
public protocol AssemblyStrategy: Sendable {
    func assemble(payloadAt payload: URL, expectedAppName: String) throws -> URL
}
