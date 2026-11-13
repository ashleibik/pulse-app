import SwiftUI
import SwiftData
import Charts
import PulseCore

/// One workout: HR over time, zones, and the key numbers.
struct WorkoutDetailView: View {
    let workout: WorkoutRecord
    @Environment(\.modelContext) private var context
    @State private var heartRate: [MinutePoint] = []

    private static let zoneColors: [Color] = [
        Color(red: 0.55, green: 0.60, blue: 0.70),
        Theme.accent, Theme.recoveryGreen, Theme.recoveryYellow, Theme.recoveryRed,
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                HStack(spacing: Theme.spacing) {
                    MetricTile(title: "Strain", value: PulseFormat.strain(workout.strain),
                               color: Theme.strain, systemImage: "flame.fill")
                    MetricTile(title: "Duration", value: PulseFormat.duration(minutes: workout.durationMinutes),
                               color: Theme.accent, systemImage: "timer")
                }
                HStack(spacing: Theme.spacing) {
                    MetricTile(title: "Avg HR", value: "\(workout.averageHeartRate)", unit: "bpm",
                               caption: "max \(workout.maxHeartRate)", color: Theme.heart, systemImage: "heart.fill")
                    MetricTile(title: "Calories", value: "\(workout.calories)", unit: "kcal",
                               caption: "approx.", color: Theme.recoveryYellow, systemImage: "bolt.fill")
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Heart rate")
                    if heartRate.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        Chart(heartRate) { point in
                            AreaMark(x: .value("Time", point.date), y: .value("BPM", point.value))
                                .foregroundStyle(Theme.heart.opacity(0.2).gradient)
                                .interpolationMethod(.catmullRom)
                            LineMark(x: .value("Time", point.date), y: .value("BPM", point.value))
                                .foregroundStyle(Theme.heart)
                                .interpolationMethod(.catmullRom)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 170)
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Heart rate zones")
                    ForEach(0..<5, id: \.self) { zone in
                        zoneRow(zone)
                    }
                }
                .card()

                Text("Apple Health and Strava export arrive in Phases 6 and 7.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle(workout.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            heartRate = MinutePoint.load(from: workout.start, to: workout.end, context: context)
        }
    }

    private func zoneRow(_ zone: Int) -> some View {
        let seconds = zone < workout.zoneSeconds.count ? workout.zoneSeconds[zone] : 0
        let total = max(1, workout.zoneSeconds.reduce(0, +))
        let fraction = Double(seconds) / Double(total)
        return HStack(spacing: 10) {
            Text("Z\(zone + 1)").font(.caption.weight(.bold)).frame(width: 26, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.06))
                    Capsule().fill(Self.zoneColors[zone]).frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 10)
            Text(PulseFormat.duration(minutes: seconds / 60))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zone \(zone + 1): \(PulseFormat.duration(minutes: seconds / 60))")
    }
}
