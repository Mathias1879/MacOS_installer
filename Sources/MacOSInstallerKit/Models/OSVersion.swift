import Foundation

/// A dotted macOS version. Compares numerically so that 26.10 sorts after 26.9
/// and 10.14 sorts before 15.8 — both of which plain string comparison reverses.
public struct OSVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)

        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        self.components = parsed
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    /// The leading component, used to decide modern vs legacy assembly.
    public var major: Int { components[0] }

    private static func component(_ version: OSVersion, at index: Int) -> Int {
        index < version.components.count ? version.components[index] : 0
    }

    public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = component(lhs, at: index)
            let right = component(rhs, at: index)
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: OSVersion, rhs: OSVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width where component(lhs, at: index) != component(rhs, at: index) {
            return false
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1 && trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
