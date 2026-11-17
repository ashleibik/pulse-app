import Foundation

/// The sync log: one timestamped line per notification, frame, command and batch, kept in memory
/// and exported as a text file from the debug screen. It contains raw band bytes (your heart data),
/// so it is never saved or uploaded by the app; only you can share it.
///
/// A first sync can produce hundreds of thousands of lines, so it keeps the FIRST `headLimit` lines
/// (how the conversation started, where most bugs show) and the LAST `tailLimit` lines (how it
/// ended), and counts what was skipped in between.
public struct SyncTrace: Sendable {
    public let headLimit: Int
    public let tailLimit: Int
    public private(set) var total = 0
    private var head: [String] = []
    private var tail: [String] = []
    private var tailStart = 0
    private var origin: Double?
    public private(set) var startedAt: Double?

    public init(headLimit: Int = 10_000, tailLimit: Int = 10_000) {
        self.headLimit = headLimit
        self.tailLimit = tailLimit
    }

    /// Lines dropped from the middle.
    public var omitted: Int { max(0, total - head.count - tail.count) }

    /// - Parameter time: unix seconds. Lines show seconds since the first line.
    public mutating func add(_ line: String, at time: Double) {
        if origin == nil { origin = time; startedAt = time }
        let stamped = String(format: "+%9.3f ", time - (origin ?? time)) + line
        total += 1
        if head.count < headLimit {
            head.append(stamped)
        } else if tail.count < tailLimit {
            tail.append(stamped)
        } else if tailLimit > 0 {
            tail[tailStart] = stamped
            tailStart = (tailStart + 1) % tailLimit
        }
    }

    /// Every kept line, in order.
    public var lines: [String] {
        head + Array(tail[tailStart...]) + Array(tail[..<tailStart])
    }

    /// The newest `count` lines (for the screen).
    public func last(_ count: Int) -> [String] { Array(lines.suffix(count)) }

    public func text(header: String) -> String {
        var parts = [header, "lines: \(total) (\(omitted) skipped in the middle)", ""]
        parts += head
        if omitted > 0 { parts.append("... \(omitted) lines skipped ...") }
        parts += Array(tail[tailStart...]) + Array(tail[..<tailStart])
        return parts.joined(separator: "\n") + "\n"
    }
}
