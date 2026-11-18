import Foundation
import Testing
@testable import PulseCore

struct TodaySoFarTests {
    private func minute(_ i: Int, hr: UInt8) -> MinuteSample {
        MinuteSample(start: Date(timeIntervalSince1970: 1_763_337_600 + Double(i) * 60),
                     heartRate: Array(repeating: hr, count: 60), rrIntervalsMs: [],
                     activity: Array(repeating: 5, count: 60), source: .history)
    }

    @Test func nothingWornMeansNothingToShow() {
        #expect(TodaySoFar.compute(minutes: []) == nil)
        #expect(TodaySoFar.compute(minutes: [minute(0, hr: 0), minute(1, hr: 0)]) == nil)
    }

    @Test func summarizesTheWornMinutesSoFar() throws {
        // 30 calm minutes at 60, then 30 at 80, then 10 off the wrist.
        let minutes = (0..<30).map { minute($0, hr: 60) } + (30..<60).map { minute($0, hr: 80) }
            + (60..<70).map { minute($0, hr: 0) }
        let today = try #require(TodaySoFar.compute(minutes: minutes))
        #expect(today.wornMinutes == 60)
        #expect(today.hoursOfData == 1)
        #expect(today.averageHeartRate == 70)
        #expect(today.restingHeartRate == 60)
        #expect(today.strain >= 0 && today.strain <= 21)
    }
}
