// Ported to Swift from OpenStrap analytics, lib/src/onehz/workout/auto_detect.dart (AutoWorkoutDetector.detect).
// Source: https://github.com/OpenStrap/analytics at commit e59d63ccc39713a6deb2facfd1c8288a5203398a
// License: MIT, Copyright (c) 2026 OpenStrap. See docs/THIRD_PARTY.md for the full notice.
//
// Changed for Pulse: the motion limit is in Pulse's movement units and tuned on the owner's data, and
// minutes that can't reach the heart-rate floor are skipped first so a sync stays fast.

import Foundation

/// Sustained cardio: heart rate held clearly above rest for at least 12 minutes.
enum OpenStrapAutoDetect {
    static let elevatedMargin = 40.0
    static let reserveFloor = 0.45
    static let longestMinutes = 120
    static let shortestSeconds = 12 * 60
    static let longestDipSeconds = 90
    static let longestGapSeconds = 90
    static let mergeGapSeconds = 5 * 60
    /// OpenStrap's 0.15 g in Pulse's units is 75. The owner's walking measured 40 to 84 and desk work under 15.
    static let motionConfirmation = 30.0
    static let onsetSeconds = 180
    static let onsetRise = 25.0

    struct Bout: Equatable { var start: Int; var end: Int }

    static func floor(resting: Double, maximum: Double) -> Double {
        max(resting + elevatedMargin, (resting + reserveFloor * (maximum - resting)).rounded())
    }

    /// - Parameters:
    ///   - seconds: time (Unix seconds) and heart rate of every measured second, in order.
    ///   - movement: average movement for a time span.
    ///   - meanRate: average heart rate over a time span, nil without data.
    static func detect(seconds: [(time: Int, rate: Double)], floor: Double,
                       movement: (Int, Int) -> Double?) -> [Bout] {
        var spans: [Bout] = []
        var spanStart: Int?
        var spanEnd = 0
        var dipStart: Int?

        func close() {
            if let start = spanStart, spanEnd - start >= shortestSeconds { spans.append(Bout(start: start, end: spanEnd)) }
            spanStart = nil
            dipStart = nil
        }

        for index in seconds.indices {
            let now = seconds[index]
            if index > 0, spanStart != nil, now.time - seconds[index - 1].time > longestGapSeconds { close() }
            if now.rate >= floor {
                if spanStart == nil { spanStart = now.time }
                spanEnd = now.time
                dipStart = nil
            } else if spanStart != nil {
                if dipStart == nil { dipStart = now.time }
                if let dip = dipStart, now.time - dip > longestDipSeconds { close() }
            }
        }
        close()

        var merged: [Bout] = []
        for span in spans {
            if let last = merged.last, span.start - last.end < mergeGapSeconds {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }

        func mean(_ low: Int, _ high: Int) -> Double? {
            let rates = seconds.filter { $0.time >= low && $0.time < high }.map(\.rate)
            return rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
        }

        return merged.filter { bout in
            guard bout.end - bout.start <= longestMinutes * 60, let average = mean(bout.start, bout.end + 1), average >= floor else {
                return false
            }
            guard let moved = movement(bout.start, bout.end), moved < motionConfirmation else { return true }
            // Little wrist motion still counts when the heart rate clearly jumped at the start (cycling, rowing).
            guard let before = mean(bout.start - onsetSeconds, bout.start),
                  let early = mean(bout.start, min(bout.end + 1, bout.start + onsetSeconds)) else { return false }
            return early - before >= onsetRise
        }
    }
}
