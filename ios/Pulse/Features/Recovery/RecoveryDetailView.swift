import SwiftUI
import SwiftData
import PulseCore

/// The Recovery page (DESIGN.md §4b): big ring and score, then the four things behind it, each as
/// today vs your last 30 days (▲ / ▼), then one paragraph in plain words.
struct RecoveryDetailView: View {
    let day: DaySummaryRecord?
    let sleeps: [SleepRecord]
    let days: [DaySummaryRecord]
    @Environment(\.modelContext) private var context
    @State private var explaining = false
    @State private var respiratory: (today: Double?, average: Double?) = (nil, nil)

    var body: some View {
        ScrollView {
            if let day {
                content(day)
                    .padding(.horizontal, DS.Space.side)
                    .padding(.top, DS.Space.l)
                    .padding(.bottom, DS.Space.xxl)
            } else {
                EmptyState(symbol: "moon.zzz", title: "No recovery yet",
                           text: "Wear your band to sleep. Recovery compares each night with your own normal.")
                    .padding(DS.Space.side)
            }
        }
        .monoBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { explaining = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("What recovery means")
            }
        }
        .sheet(isPresented: $explaining) {
            MetricExplainerView(kind: .recovery, today: day, history: Array(days.prefix(14)))
                .presentationDetents([.medium, .large])
        }
        .task(id: day?.date) { loadRespiratory() }
    }

    private var title: String {
        guard let day else { return "Recovery" }
        return Calendar.current.isDateInToday(day.date) ? "TODAY" : day.date.formatted(.dateTime.weekday(.wide).month().day()).uppercased()
    }

    private func content(_ day: DaySummaryRecord) -> some View {
        let earlier = NightVitals.previous30(days, before: day.date)
        let hrvAverage = mean(earlier.compactMap(\.hrvRMSSD))
        let rhrAverage = mean(earlier.compactMap(\.restingHeartRate))
        let performance = NightVitals.performance(for: day, sleeps: sleeps)
        let performanceAverage = mean(earlier.compactMap { NightVitals.performance(for: $0, sleeps: sleeps)?.score })
        return VStack(alignment: .leading, spacing: DS.Space.l) {
            BigScoreRing(fraction: day.recoveryScore.map { $0 / 100 },
                         text: day.recoveryScore.map { "\(Int($0.rounded()))%" } ?? "--",
                         caption: day.recoveryScore == nil ? "RECOVERY\nLEARNING YOUR NORMAL" : "RECOVERY",
                         color: DS.Colors.zone(day.zone))
                .riseIn(1)

            VStack(spacing: 0) {
                CompareRow(symbol: "waveform.path.ecg", title: "Heart rate variability", value: day.hrvRMSSD,
                           average: hrvAverage, format: { "\(Int($0.rounded()))" }, higherIsBetter: true)
                Hairline()
                CompareRow(symbol: "heart", title: "Resting heart rate", value: day.restingHeartRate,
                           average: rhrAverage, format: { "\(Int($0.rounded()))" }, higherIsBetter: false)
                Hairline()
                CompareRow(symbol: "lungs", title: "Respiratory rate", value: respiratory.today,
                           average: respiratory.average, format: { String(format: "%.1f", $0) }, higherIsBetter: nil)
                Hairline()
                CompareRow(symbol: "moon", title: "Sleep performance", value: performance?.score,
                           average: performanceAverage, format: { "\(Int($0.rounded()))%" }, higherIsBetter: true)
                HStack(spacing: 6) {
                    Text("▲▼").foregroundStyle(DS.Colors.accent)
                    Text("Today").foregroundStyle(DS.Colors.primary)
                    Text("vs. last 30 days").foregroundStyle(DS.Colors.secondary)
                    Spacer()
                }
                .textStyle(.caption)
                .padding(DS.Space.s)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.background))
                .padding(.top, DS.Space.s)
            }
            .monoCard(padding: DS.Space.m)
            .riseIn(2)

            Text(paragraph(day, rhrHistory: earlier.compactMap(\.restingHeartRate)))
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
                .fixedSize(horizontal: false, vertical: true)
                .monoCard(padding: DS.Space.m)
                .riseIn(3)
        }
    }

    /// The day's explanation, plus where resting HR sits in its usual range (when there is one).
    private func paragraph(_ day: DaySummaryRecord, rhrHistory: [Double]) -> String {
        var text = day.explanation
        if let rhr = day.restingHeartRate, rhrHistory.count >= 3 {
            let mean = Stats.mean(rhrHistory)
            let spread = max(2, 1.5 * Stats.sampleSD(rhrHistory))
            let low = Int((mean - spread).rounded()), high = Int((mean + spread).rounded())
            let inside = HealthMonitor.withinRange(rhr, history: rhrHistory, minSpread: 2) == true
            text += " Your resting heart rate (\(Int(rhr.rounded())) bpm) is \(inside ? "within" : "outside") its usual range of \(low) to \(high) bpm."
        }
        return text
    }

    private func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : Stats.mean(values) }

    private func loadRespiratory() {
        guard let day else { return }
        let tonight = NightVitals.mainSleep(endingOn: day.date, in: sleeps)
        let from = Calendar.current.date(byAdding: .day, value: -30, to: day.date) ?? day.date
        let earlier = sleeps.filter { !$0.isNap && $0.end < (tonight?.start ?? day.date) && $0.end >= from }
        let values = earlier.compactMap { NightVitals.respiratoryRate($0, context: context) }
        respiratory = (tonight.flatMap { NightVitals.respiratoryRate($0, context: context) },
                       values.isEmpty ? nil : Stats.mean(values))
    }
}
