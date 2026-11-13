import Foundation

/// Builds the file Pulse uploads to Strava for one workout (Phase 7).
///
/// Strava's terms (API Agreement + API Policy, both effective June 1, 2026; read on 2026-11-13):
/// - Uploading activities is allowed (Agreement §7.1).
/// - Data that comes FROM Strava's API may not be used with any AI, not even inside a prompt
///   (Policy §5.3), and may not be served through an MCP server (§5.16(b)).
/// So Pulse is upload-only: it sends workouts and reads nothing back. Nothing from Strava ever
/// reaches the Claude connector (Phase 8) or the coach (Phase 9).
///
/// Format: TCX (Garmin Training Center XML), one of the formats Strava's upload endpoint accepts.
/// It carries heart rate over time. There is no GPS: the band has none.
public enum StravaExport {

    /// Simulated workouts must never land in the user's real Strava feed.
    public static func canUpload(_ workout: Workout) -> Bool { workout.source != .simulated }

    /// Strava refuses a second upload with the same external id, so a workout can't be posted
    /// twice even if the app forgets that it already uploaded it.
    public static func externalID(for workout: Workout) -> String { "pulse-\(workout.id.uuidString.lowercased())" }

    public static func name(for workout: Workout, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: workout.start)
        let part = hour < 5 ? "Night" : hour < 12 ? "Morning" : hour < 17 ? "Afternoon" : "Evening"
        return "\(part) \(workout.kind.displayName.lowercased())"
    }

    /// TCX only knows three sports.
    static func tcxSport(_ kind: WorkoutKind) -> String {
        switch kind {
        case .run, .walk: "Running"
        case .ride: "Biking"
        case .strength, .hiit, .other: "Other"
        }
    }

    /// - Parameters:
    ///   - minutes: the raw minutes covering the workout (others are ignored).
    ///   - sampleEverySeconds: one heart-rate point every N seconds keeps the file small.
    public static func tcx(for workout: Workout, minutes: [MinuteSample], sampleEverySeconds: Int = 5) -> String {
        let step = max(1, sampleEverySeconds)
        var points: [String] = []
        for minute in minutes.sorted(by: { $0.start < $1.start }) {
            for second in stride(from: 0, to: min(60, minute.heartRate.count), by: step) {
                let time = minute.start.addingTimeInterval(Double(second))
                let bpm = minute.heartRate[second]
                guard bpm > 0, time >= workout.start, time < workout.end else { continue }
                points.append("          <Trackpoint><Time>\(iso(time))</Time><HeartRateBpm><Value>\(bpm)</Value></HeartRateBpm></Trackpoint>")
            }
        }
        let seconds = Int(workout.end.timeIntervalSince(workout.start))
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\">",
            "  <Activities>",
            "    <Activity Sport=\"\(tcxSport(workout.kind))\">",
            "      <Id>\(iso(workout.start))</Id>",
            "      <Lap StartTime=\"\(iso(workout.start))\">",
            "        <TotalTimeSeconds>\(seconds)</TotalTimeSeconds>",
            "        <DistanceMeters>0</DistanceMeters>",
            // Calories are left at 0 on purpose: Pulse's number is a rough guess (see METRICS.md).
            "        <Calories>0</Calories>",
            "        <AverageHeartRateBpm><Value>\(workout.averageHeartRate)</Value></AverageHeartRateBpm>",
            "        <MaximumHeartRateBpm><Value>\(workout.maxHeartRate)</Value></MaximumHeartRateBpm>",
            "        <Intensity>Active</Intensity>",
            "        <TriggerMethod>Manual</TriggerMethod>",
            "        <Track>",
        ]
        lines += points
        lines += [
            "        </Track>",
            "      </Lap>",
            "      <Notes>\(escape("Recorded with Pulse. Strain \(PulseFormat.strain(workout.strain)) of 21."))</Notes>",
            "    </Activity>",
            "  </Activities>",
            "</TrainingCenterDatabase>",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// UTC, whole seconds, e.g. 2026-11-13T07:37:00Z (what TCX expects).
    static func iso(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
