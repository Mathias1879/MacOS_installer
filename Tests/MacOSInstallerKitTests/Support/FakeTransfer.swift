import Foundation
@testable import MacOSInstallerKit

final class FakeTransfer: ResumableTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var payload: Data
    private var recordedOffsets: [Int64] = []
    private var error: (any Error)?

    init(payload: Data, error: (any Error)? = nil) {
        self.payload = payload
        self.error = error
    }

    var offsets: [Int64] { lock.withLock { recordedOffsets } }

    func transfer(
        from url: URL,
        to destination: URL,
        startingAt offset: Int64,
        progress: @Sendable (Int64) -> Void
    ) async throws {
        lock.withLock { recordedOffsets.append(offset) }
        if let error { throw error }

        let remainder = payload.dropFirst(Int(offset))
        if FileManager.default.fileExists(atPath: destination.path) {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: remainder)
        } else {
            try remainder.write(to: destination)
        }
        progress(Int64(remainder.count))
    }
}
