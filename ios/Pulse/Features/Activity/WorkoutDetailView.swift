import SwiftUI
import SwiftData
import PulseCore

/// One workout: strain, key numbers, heart rate over time, and time in each zone.
/// Mono design (ios/design/DESIGN.md).
struct WorkoutDetailView: View {
    let workout: WorkoutRecord
    @Environment(\.modelContext) private var context
    @State private var heartRate: [ChartPoint] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                hero.riseIn(0)
                stats.riseIn(1)
                heart.riseIn(2)
                zones.riseIn(3)
                Text("Apple Health and Strava export arrive in Phases 6 and 7.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.xxl)
        }
        .monoBackground()
        .navigationTitle(workout.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            heartRate = ChartPoint.heartRate(from: workout.start, to: workout.end, context: context)
        }
    }

    // MARK: - Sections

    /// The answer: how hard this workout was.
    private var hero: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: workout.kind.symbolName.outlineSymbol)
                    .accessibilityHidden(true)
                Text(workout.start.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
            }
            .textStyle(.caption)
            .foregroundStyle(DS.Colors.secondary)

            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                HeroNumber(value: workout.strain) { PulseFormat.strain($0) }
                Text("strain, of 21")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(workout.kind.displayName), strain \(PulseFormat.strain(workout.strain)) of 21")
    }

    /// Four numbers, no boxes.
    private var stats: some View {
        VStack(spacing: DS.Space.l) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                StatBlock(symbol: "timer", label: "Duration",
                          number: Double(workout.durationMinutes),
                          format: { PulseFormat.duration(minutes: Int($0.rounded())) })
                StatBlock(symbol: "bolt", label: "Calories",
                          number: Double(workout.calories),
                          format: { "\(Int($0.rounded()))" }, unit: "kcal",
                          caption: "rough estimate")
            }
            Hairline()
            HStack(alignment: .top, spacing: DS.Space.m) {
                StatBlock(symbol: "heart", label: "Average HR",
                          number: Double(workout.averageHeartRate),
                          format: { "\(Int($0.rounded()))" }, unit: "bpm")
                StatBlock(symbol: "arrow.up.heart", label: "Max HR",
                          number: Double(workout.maxHeartRate),
                          format: { "\(Int($0.rounded()))" }, unit: "bpm")
            }
        }
    }

    private var heart: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Heart rate")
            if heartRate.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LineChart(points: heartRate,
                          xValues: .automatic(desiredCount: 4),
                          xFormat: .dateTime.hour().minute(),
                          height: 160,
                          summary: "Heart rate during the workout. Average \(workout.averageHeartRate), maximum \(workout.maxHeartRate) beats per minute.")
            }
        }
    }

    /// The one card on this screen.
    private var zones: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Time in zones")
            ZoneBars(minutes: workout.zoneSeconds.map { $0 / 60 }, track: DS.Colors.muted)
        }
        .monoCard()
    }
}
