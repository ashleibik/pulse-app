import Foundation
import SwiftData
import PulseCore

/// "Your data starts here." The band was bought used, so its memory starts with the previous
/// owner's history. Everything recorded before the day this band was first paired in Pulse is
/// treated as theirs: it is dropped during the download (still acknowledged, so the band frees the
/// space) and never saved or shown.
///
/// Stored in UserDefaults, not in the database, so that "Forget band" + pairing again keeps the
/// original date (and so no database migration is needed).
enum BandDataCutoff {
    private static let key = "bandDataStartsAt.v1"

    /// Start of the day of the first pairing. nil = never paired.
    static var date: Date? {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    /// For the band protocol (unix seconds).
    static var unix: UInt32? {
        date.map { UInt32(clamping: Int($0.timeIntervalSince1970)) }
    }

    /// Changed by hand in Settings. Always the start of the chosen day.
    static func set(_ day: Date, calendar: Calendar = .current) {
        UserDefaults.standard.set(calendar.startOfDay(for: day).timeIntervalSince1970, forKey: key)
    }

    /// First pairing: the start of today. Does nothing if a date already exists.
    static func setOnFirstPairing(now: Date = .now) {
        guard date == nil else { return }
        set(now)
    }

    /// Versions before this one didn't record the pairing day. The band arrived recently, so a
    /// week back is safely after the previous owner's data and before your own. Editable in Settings.
    static func setForExistingInstall(now: Date = .now, calendar: Calendar = .current) {
        guard date == nil else { return }
        set(calendar.date(byAdding: .day, value: -7, to: now) ?? now, calendar: calendar)
    }
}

extension PulseStore {
    /// Deletes band data from before `cutoff`: raw minutes and the workouts detected in them.
    /// Day summaries and sleeps are rebuilt by the recalculation that must follow.
    /// Workouts you added by hand and the journal stay. Returns true if anything was deleted.
    @MainActor
    @discardableResult
    static func deleteBandData(before cutoff: Date, in context: ModelContext) throws -> Bool {
        var probe = FetchDescriptor<MinuteRecord>(predicate: #Predicate { $0.start < cutoff })
        probe.fetchLimit = 1
        let history = DataSource.history.rawValue
        let workouts = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.start < cutoff && $0.sourceRaw == history })
        let hasMinutes = try context.fetchCount(probe) > 0
        let hasWorkouts = try context.fetchCount(workouts) > 0
        guard hasMinutes || hasWorkouts else { return false }
        try context.delete(model: MinuteRecord.self, where: #Predicate { $0.start < cutoff })
        try context.delete(model: WorkoutRecord.self, where: #Predicate { $0.start < cutoff && $0.sourceRaw == history })
        try context.save()
        return true
    }
}
