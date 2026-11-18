import Foundation

/// Small, locale-independent text helpers shared by the app and tests.
public enum PulseFormat {

    /// 460 -> "7h 40m", 480 -> "8h", 45 -> "45m"
    public static func duration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// 546 -> "9:06" (a duration written like a clock, for tiles).
    public static func clock(minutes: Int) -> String {
        let m = max(0, minutes)
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// 12.04 -> "12.0"
    public static func strain(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// 81.6 -> "82%"
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// One or two plain-language sentences explaining a recovery score.
    /// Example: "HRV is 9% above your baseline, and resting HR is down 2 bpm. You got 7h 40m of sleep."
    public static func recoveryExplanation(hrv: Double?, baselineHRV: Double?,
                                           restingHR: Double?, baselineRestingHR: Double?,
                                           sleepMinutes: Int?, sleepNeedMinutes: Int) -> String {
        var first: [String] = []
        if let hrv, let base = baselineHRV, base > 0 {
            let pct = Int(((hrv / base - 1) * 100).rounded())
            if pct >= 5 { first.append("HRV is \(pct)% above your baseline") }
            else if pct <= -5 { first.append("HRV is \(-pct)% below your baseline") }
            else { first.append("HRV is right at your baseline") }
        }
        if let rhr = restingHR, let base = baselineRestingHR {
            let diff = Int((rhr - base).rounded())
            if diff <= -2 { first.append("resting HR is down \(-diff) bpm") }
            else if diff >= 2 { first.append("resting HR is up \(diff) bpm") }
        }
        var sentences: [String] = []
        if !first.isEmpty {
            sentences.append(capitalizeFirst(first.joined(separator: ", and ")) + ".")
        }
        sentences.append(sleepSentence(sleepMinutes: sleepMinutes, sleepNeedMinutes: sleepNeedMinutes))
        return sentences.joined(separator: " ")
    }

    /// Shown for the first few days, before there's a baseline to compare against.
    /// Example: "Pulse is still learning your normal (2 of 4 nights). You got 7h 40m of sleep."
    public static func learningExplanation(nightsSoFar: Int, needed: Int,
                                           sleepMinutes: Int?, sleepNeedMinutes: Int) -> String {
        "Pulse is still learning your normal (\(nightsSoFar) of \(needed) nights). "
            + sleepSentence(sleepMinutes: sleepMinutes, sleepNeedMinutes: sleepNeedMinutes)
    }

    static func sleepSentence(sleepMinutes: Int?, sleepNeedMinutes: Int) -> String {
        guard let sleep = sleepMinutes else { return "No sleep was recorded last night." }
        if sleep < sleepNeedMinutes - 45 {
            return "You slept \(duration(minutes: sleep)), short of the \(duration(minutes: sleepNeedMinutes)) you needed."
        }
        return "You got \(duration(minutes: sleep)) of sleep."
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}
