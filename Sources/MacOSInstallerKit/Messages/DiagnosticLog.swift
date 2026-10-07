import Foundation

extension DateFormatter {
    /// `2026-10-03` — one log file per day.
    static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}

/// Appends technical detail to `~/Library/Logs/macos-installer/<date>.log`.
///
/// The terminal shows the human version of a failure; this is where the exact
/// argv, exit status and stderr go. For a possibly-partially-erased drive that
/// detail is the only record of what was attempted, and terminal scrollback is
/// not a record.
///
/// Logging is best-effort by design: `record` returns nil rather than throwing,
/// because a logging failure must never replace or mask the error the caller is
/// in the middle of reporting.
public struct DiagnosticLog {
    private let directory: URL
    private let clock: () -> Date

    public init(directory: URL, clock: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.clock = clock
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/macos-installer", isDirectory: true)
    }

    /// Abbreviates a path under the user's home directory to `~/…` for display.
    ///
    /// The comparison is on a path-component boundary, not a raw character
    /// prefix: with a home of `/Users/matt`, a sibling like
    /// `/Users/matthew/foo` shares the prefix but is not inside it, and a
    /// naive `hasPrefix` would render it as `~hew/foo` — a path the user
    /// cannot act on, shown to them as the location of their log.
    public static func displayPath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path == home { return "~" }
        guard url.path.hasPrefix(home + "/") else { return url.path }
        return "~" + url.path.dropFirst(home.count)
    }

    /// Appends `detail` and returns the display path, or nil if nothing was written.
    @discardableResult
    public func record(_ detail: String) -> String? {
        let now = clock()
        let file = directory.appendingPathComponent(
            DateFormatter.logDateFormatter.string(from: now) + ".log"
        )

        let entry = "=== \(ISO8601DateFormatter().string(from: now)) ===\n\(detail)\n\n"

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
            } else {
                try Data(entry.utf8).write(to: file, options: .atomic)
            }
        } catch {
            return nil
        }

        return Self.displayPath(for: file)
    }
}
