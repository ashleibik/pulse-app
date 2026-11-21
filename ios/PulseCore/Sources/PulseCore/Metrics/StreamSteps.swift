import Foundation

/// One clock minute of the band's 100 Hz motion stream (docs/METRICS.md §15).
public struct StepMinute: Equatable, Sendable {
    /// The minute's start.
    public var start: Date
    /// The steps OpenStrap's pedometer counted in it.
    public var steps: Int
    /// The seconds of motion that arrived (60 = the whole minute).
    public var seconds: Int

    public init(start: Date, steps: Int, seconds: Int) {
        self.start = start
        self.steps = steps
        self.seconds = seconds
    }

    /// Steps a minute at this minute's pace. 0 without any seconds.
    public var cadence: Double { seconds > 0 ? Double(steps) * 60 / Double(seconds) : 0 }
}

extension StepMinute: Codable {
    // In a backup, a minute is `[unix seconds, steps, seconds]`: a year of them stays a few megabytes.
    public init(from decoder: Decoder) throws {
        var row = try decoder.unkeyedContainer()
        start = Date(timeIntervalSince1970: TimeInterval(try row.decode(Int.self)))
        steps = try row.decode(Int.self)
        seconds = try row.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var row = encoder.unkeyedContainer()
        try row.encode(Int(start.timeIntervalSince1970.rounded()))
        try row.encode(steps)
        try row.encode(seconds)
    }
}

/// Counts steps on the band's 100 Hz motion stream as its seconds arrive (docs/METRICS.md §15).
///
/// Like OpenStrap's daily total (`calcSteps`), each clock minute is counted on its own, with the pedometer run on each unbroken
/// run of seconds in it. Nothing is kept but the minute in progress, so it can run all day.
public struct StreamStepCounter: Sendable {
    /// Unix seconds of the minute being filled.
    private var minute: UInt32?
    /// The size of each reading (g), one array per unbroken run of seconds in that minute.
    private var runs: [[Double]] = []
    private var seconds = 0
    private var lastSecond: UInt32?

    public init() {}

    /// Adds one second of motion. Returns the minute it finished, when this second starts a new one.
    public mutating func add(_ motion: Whoop.RawMotion) -> [StepMinute] {
        let second = motion.timestamp
        // A second the band sends twice counts once.
        if let lastSecond, second <= lastSecond { return [] }
        let sizes = LiveSteps.magnitudes([motion])
        guard !sizes.isEmpty else { return [] }
        let start = second - second % 60
        var finished: [StepMinute] = []
        if let minute, minute != start { finished = closeMinute() }
        if minute == nil { minute = start }
        if let lastSecond, second == lastSecond + 1, !runs.isEmpty {
            runs[runs.count - 1] += sizes
        } else {
            runs.append(sizes)
        }
        seconds += 1
        lastSecond = second
        return finished
    }

    /// Ends the minute in progress: the stream stopped or the connection dropped. The next second starts afresh, so a band
    /// clock that was set back in the meantime doesn't make its seconds look like repeats.
    public mutating func finish() -> [StepMinute] {
        let done = closeMinute()
        lastSecond = nil
        return done
    }

    /// The start of the minute being filled. nil = none.
    public var minuteInProgress: Date? { minute.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    /// The steps of the minute being filled, counted the same way as when it closes, so the screens can move while the
    /// owner walks. The minute's own count replaces it when it closes.
    public var stepsSoFar: Int { seconds > 0 ? count(runs) : 0 }

    private func count(_ runs: [[Double]]) -> Int {
        let counted = runs.reduce(0) { $0 + OpenStrapPedometer.pedometer($1) }
        return Int((Double(counted) * OpenStrapPedometer.gain).rounded())
    }

    private mutating func closeMinute() -> [StepMinute] {
        defer {
            minute = nil
            runs = []
            seconds = 0
        }
        guard let minute, seconds > 0 else { return [] }
        return [StepMinute(start: Date(timeIntervalSince1970: TimeInterval(minute)), steps: count(runs), seconds: seconds)]
    }
}
