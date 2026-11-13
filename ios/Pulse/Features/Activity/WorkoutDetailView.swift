import SwiftUI
import SwiftData
import Charts
import PulseCore

/// One workout: key numbers, heart rate over time (with zone bands), and time in each zone.
struct WorkoutDetailView: View {
    let workout: WorkoutRecord
    @Environment(\.modelContext) private var context
    @Query private var profiles: [ProfileRecord]
    @State private var heartRate: [MinutePoint] = []

    private var maxHR: Double { profiles.first?.estimatedMaxHeartRate() ?? 190 }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                header
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.spacing), GridItem(.flexible(), spacing: Theme.spacing)],
                          spacing: Theme.spacing) {
                    MetricTile(title: "Strain", value: PulseFormat.strain(workout.strain),
                               caption: "of 21", color: Theme.strain, systemImage: "flame.fill")
                    MetricTile(title: "Duration", value: PulseFormat.duration(minutes: workout.durationMinutes),
                               color: Theme.accent, systemImage: "timer")
                    MetricTile(title: "Avg HR", value: "\(workout.averageHeartRate)", unit: "bpm",
                               caption: "max \(workout.maxHeartRate)", color: Theme.heart, systemImage: "heart.fill")
                    MetricTile(title: "Calories", value: "\(workout.calories)", unit: "kcal",
                               caption: "rough estimate", color: Theme.recoveryYellow, systemImage: "bolt.fill")
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Heart rate")
                    if heartRate.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 170)
                    } else {
                        Chart {
                            // Faint zone bands behind the line (Z2-Z5 boundaries)
                            ForEach(1..<5, id: \.self) { zone in
                                RuleMark(y: .value("Zone \(zone + 1)", maxHR * (0.5 + Double(zone) / 10)))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                                    .foregroundStyle(Theme.zoneColors[zone].opacity(0.4))
                            }
                            ForEach(heartRate) { point in
                                AreaMark(x: .value("Time", point.date), y: .value("BPM", point.value))
                                    .foregroundStyle(Theme.heart.opacity(0.2).gradient)
                                    .interpolationMethod(.catmullRom)
                                LineMark(x: .value("Time", point.date), y: .value("BPM", point.value))
                                    .foregroundStyle(Theme.heart)
                                    .interpolationMethod(.catmullRom)
                            }
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 180)
                        .accessibilityLabel("Heart rate during the workout. Average \(workout.averageHeartRate), maximum \(workout.maxHeartRate) beats per minute.")
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Time in zones")
                    ZoneBars(minutes: workout.zoneSeconds.map { $0 / 60 })
                }
                .card()

                Label("Apple Health and Strava export arrive in Phases 6 and 7.", systemImage: "arrow.up.forward.app")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
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

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: workout.kind.symbolName)
                .font(.title)
                .foregroundStyle(Theme.strain)
                .frame(width: 56, height: 56)
                .background(Theme.strain.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.kind.displayName).font(.title2.weight(.bold))
                Text(workout.start.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
