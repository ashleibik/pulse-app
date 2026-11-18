import Foundation
import Testing
@testable import PulseCore

// Export all data / Import data (see PulseBackup.swift).

private let base = 1_750_000_020.0     // a whole minute

private func date(_ minutes: Int) -> Date { Date(timeIntervalSince1970: base + Double(minutes) * 60) }

private func minute(_ index: Int, bpm: UInt8 = 60, seconds: Range<Int> = 0..<60, rr: [UInt16] = [1000, 1010],
                    source: DataSource = .history) -> MinuteSample {
    var heartRate = [UInt8](repeating: 0, count: 60)
    var activity = [UInt8](repeating: 0, count: 60)
    for second in seconds {
        heartRate[second] = bpm
        activity[second] = 7
    }
    return MinuteSample(start: date(index), heartRate: heartRate, rrIntervalsMs: rr, activity: activity, source: source)
}

private func workout(_ source: DataSource, start: Int) -> Workout {
    Workout(kind: .run, start: date(start), end: date(start + 30), averageHeartRate: 150, maxHeartRate: 170,
            strain: 10, zoneSeconds: [0, 0, 600, 600, 600], calories: 300, source: source)
}

/// One fixed value: the records inside have random IDs.
private let fixture = makeContents()

private func makeContents() -> PulseBackup.Contents {
    let profile = PulseBackup.Profile(birthYear: 1990, maxHeartRateOverride: nil, sleepGoalMinutes: 465, sex: .male,
                                      weightKg: 78.5, heightCm: 181)
    let header = PulseBackup.Header(exportedAt: date(5000), appVersion: "0.2.0 (1)", dataStart: date(0), profile: profile)
    let sleep = SleepSession(start: date(10), end: date(400), asleepMinutes: 360, awakeMinutes: 30, disturbances: 2, source: .history)
    let day = DailySummary(date: date(0), recoveryScore: 71.5, strain: 9.2, sleepMinutes: 360, sleepNeedMinutes: 480,
                           restingHeartRate: 52, hrvRMSSD: 61, baselineRestingHeartRate: nil, baselineHRV: nil,
                           explanation: "Line one\nline two, with \"quotes\"", source: .history)
    return PulseBackup.Contents(header: header,
                                workouts: [PulseBackup.WorkoutEntry(workout: workout(.history, start: 50), healthKitID: UUID(), stravaUploadedAt: date(90))],
                                journal: [PulseBackup.JournalDay(day: date(0), habits: ["alcohol", "aHabitFromTheFuture"])],
                                days: [day], sleeps: [sleep],
                                sleepCorrections: [SleepCorrection(detectedStart: date(10), detectedEnd: date(400), createdAt: date(500)),
                                                   SleepCorrection(detectedStart: date(10), detectedEnd: date(400), start: date(20),
                                                                   end: date(390), createdAt: date(600))])
}

private func file(minutes: [MinuteSample]) throws -> Data {
    var out = Data()
    var writer = try PulseBackup.Writer(contents: fixture) { out.append($0) }
    // Written in two pieces, the way the app writes pages of minutes.
    try writer.append(Array(minutes.prefix(1)))
    try writer.append(Array(minutes.dropFirst()))
    try writer.finish()
    return out
}

/// Hands the file over in pieces of `size` bytes, like reading it from disk.
private func chunks(_ data: Data, size: Int = 4096) -> () throws -> Data? {
    var offset = 0
    return {
        guard offset < data.count else { return nil }
        defer { offset += size }
        return data.subdata(in: offset..<min(offset + size, data.count))
    }
}

private func readAll(_ data: Data, size: Int = 4096) throws -> (PulseBackup.Contents, [MinuteSample]) {
    let reader = try PulseBackup.Reader(chunks: chunks(data, size: size))
    var minutes: [MinuteSample] = []
    while let minute = try reader.nextMinute() { minutes.append(minute) }
    return (reader.contents, minutes)
}

@Test func everythingSurvivesTheRoundTrip() throws {
    let minutes = [minute(0), minute(1, bpm: 71, seconds: 10..<40, rr: []), minute(2, rr: [900, 65_535])]
    let (restored, restoredMinutes) = try readAll(try file(minutes: minutes))
    #expect(restored == fixture)
    #expect(restoredMinutes == minutes)
}

@Test func theFileIsOrdinaryJSON() throws {
    let data = try file(minutes: [minute(0), minute(1)])
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((object["minutes"] as? [Any])?.count == 2)
    #expect((object["footer"] as? [String: Any])?["minutes"] as? Int == 2)
    #expect((object["header"] as? [String: Any])?["app"] as? String == "Pulse")
}

@Test func aBackupWithoutRawMinutesIsStillValid() throws {
    let data = try file(minutes: [])
    #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
    #expect(try readAll(data).1.isEmpty)
}

@Test func readingDoesNotDependOnHowTheFileIsCutIntoChunks() throws {
    let minutes = (0..<5).map { minute($0) }
    let data = try file(minutes: minutes)
    for size in [1, 7, 64, 1000] {
        #expect(try readAll(data, size: size).1 == minutes)
    }
}

@Test func theSummaryCountsWhatTheFileHolds() throws {
    let summary = try PulseBackup.summarize(chunks: chunks(try file(minutes: [minute(3), minute(1), minute(2)])))
    #expect(summary.minutes == 3 && summary.workouts == 1 && summary.journalDays == 1)
    #expect(summary.firstMinute == date(1) && summary.lastMinute == date(3))
    #expect(summary.exportedAt == date(5000))
}

// MARK: - Refusing bad files

@Test func aFileCutShortAnywhereIsRefused() throws {
    let data = try file(minutes: (0..<4).map { minute($0) })
    for length in stride(from: 1, to: data.count - 2, by: max(1, data.count / 40)) {
        #expect(throws: (any Error).self) { _ = try readAll(data.prefix(length)) }
    }
}

@Test func aMissingMinuteIsNoticed() throws {
    let lines = String(decoding: try file(minutes: (0..<3).map { minute($0) }), as: UTF8.self)
        .components(separatedBy: "\n")
    let index = try #require(lines.firstIndex(of: "\"minutes\":[")) + 1
    var shorter = lines
    shorter.remove(at: index)
    #expect(throws: PulseBackup.Failure.damaged) { _ = try readAll(Data(shorter.joined(separator: "\n").utf8)) }
}

@Test func otherFilesAreRefused() {
    for text in ["", "hello", "{\n\"something\":1,\n}", "{\"app\":\"Pulse\"}", "{\n\"header\":{\"app\":\"Other\"},\n"] {
        #expect(throws: PulseBackup.Failure.notABackup) { _ = try readAll(Data(text.utf8)) }
    }
}

@Test func aBackupFromANewerVersionIsRefused() throws {
    let text = String(decoding: try file(minutes: []), as: UTF8.self)
        .replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2")
    #expect(throws: PulseBackup.Failure.newerVersion) { _ = try readAll(Data(text.utf8)) }
}

// MARK: - Merging

@Test func mergingFillsOnlyMissingSecondsAndKeepsWhatIsHere() {
    let here = minute(0, bpm: 60, seconds: 0..<30, rr: [1000, 1000, 1000])
    let file = minute(0, bpm: 90, seconds: 20..<60, rr: [800])
    let merged = PulseBackup.merged(existing: here, incoming: file)
    #expect(merged.heartRate[10] == 60)         // only here
    #expect(merged.heartRate[25] == 60)         // both: this iPhone wins
    #expect(merged.heartRate[45] == 90)         // only in the file
    #expect(merged.activity[45] == 7)
    #expect(merged.rrIntervalsMs == [1000, 1000, 1000])
}

@Test func importingTheSameFileTwiceChangesNothing() {
    let here = minute(0, bpm: 60, seconds: 0..<30, rr: [1000])
    let file = minute(0, bpm: 90, seconds: 20..<60, rr: [800, 810, 820])
    let once = PulseBackup.merged(existing: here, incoming: file)
    #expect(PulseBackup.merged(existing: once, incoming: file) == once)
    #expect(once.rrIntervalsMs.count == 3)      // beats are never added together
}

// MARK: - Cutoff and fake data

@Test func theFilesCutoffWinsSoItsDataIsNotDeletedAfterImport() {
    #expect(PulseBackup.effectiveDataStart(file: date(0), local: date(900)) == date(0))
    #expect(PulseBackup.effectiveDataStart(file: nil, local: date(900)) == date(900))
    #expect(PulseBackup.effectiveDataStart(file: nil, local: nil) == nil)
}

@Test func importRefusesThePreviousOwnersDataAndAnythingSimulated() {
    #expect(PulseBackup.accepts(minute(10), dataStart: date(10)))
    #expect(!PulseBackup.accepts(minute(9), dataStart: date(10)))
    #expect(!PulseBackup.accepts(minute(20, source: .simulated), dataStart: nil))

    #expect(!PulseBackup.accepts(workout(.history, start: 5), dataStart: date(10)))
    #expect(PulseBackup.accepts(workout(.manual, start: 5), dataStart: date(10)))
    #expect(!PulseBackup.accepts(workout(.simulated, start: 50), dataStart: nil))
}
