import Foundation
@testable import MacOSInstallerKit

final class FakeTransfer: ResumableTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var payload: Data
    private var recordedOffsets: [Int64] = []
    private var error: (any Error)?
    private var bytesBeforeThrowing: Int?

    /// - Parameters:
    ///   - error: thrown after writing bytes (see `bytesBeforeThrowing`), or
    ///     never, if nil.
    ///   - bytesBeforeThrowing: how many bytes of the remaining payload to
    ///     write before `error` is thrown. Capped at whatever remains, so a
    ///     value at or above the remainder means "write everything, then
    ///     throw" — curl's write-it-all-then-exit-non-zero case. `nil` (the
    ///     default) means "write nothing before throwing" — a connection that
    ///     drops before any bytes land. Ignored when `error` is nil.
    init(payload: Data, error: (any Error)? = nil, bytesBeforeThrowing: Int? = nil) {
        self.payload = payload
        self.error = error
        self.bytesBeforeThrowing = bytesBeforeThrowing
    }

    var offsets: [Int64] { lock.withLock { recordedOffsets } }

    func transfer(
        from url: URL,
        to destination: URL,
        startingAt offset: Int64,
        progress: @Sendable (Int64) -> Void
    ) async throws {
        lock.withLock { recordedOffsets.append(offset) }

        let remainder = payload.dropFirst(Int(offset))
        let toWrite = error == nil ? remainder : remainder.prefix(bytesBeforeThrowing ?? 0)

        if !toWrite.isEmpty {
            if FileManager.default.fileExists(atPath: destination.path) {
                let handle = try FileHandle(forWritingTo: destination)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: toWrite)
            } else {
                try toWrite.write(to: destination)
            }
            progress(Int64(toWrite.count))
        }

        if let error { throw error }
    }
}
