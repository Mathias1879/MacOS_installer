import Foundation

/// Formats a byte count the way this tool talks about drive and installer
/// sizes everywhere a user sees one: whole gigabytes, one decimal place.
///
/// Extracted because the same `"%.1f GB"` shape was hand-written at three call
/// sites (`VolumeGuard.RefusalReason`, `VolumeTableFormatter`,
/// `InstallerRelease.displaySize`) — a formula a reader could silently drift
/// by editing one site and not the others.
enum ByteSize {
    private static let bytesPerGigabyte: Double = 1_000_000_000

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / bytesPerGigabyte)
    }
}
