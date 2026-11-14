import SwiftUI
import SwiftData
import PulseCore

/// One workout: strain, key numbers, heart rate over time, and time in each zone.
/// Mono design (ios/design/DESIGN.md).
struct WorkoutDetailView: View {
    let workout: WorkoutRecord
    /// Deletes this workout (only offered for workouts the user added by hand).
    var onDelete: (() -> Void)? = nil
    @Environment(\.modelContext) private var context
    @Environment(CloudManager.self) private var cloud
    @State private var heartRate: [ChartPoint] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                hero.riseIn(0)
                stats.riseIn(1)
                heart.riseIn(2)
                zones.riseIn(3)
                share.riseIn(4)
                if workout.sourceRaw == DataSource.manual.rawValue, let onDelete {
                    Button("Delete workout") { onDelete() }
                        .buttonStyle(.secondaryPill)
                }
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

    /// Send this workout to Strava (only shown once Strava is connected in Settings).
    @ViewBuilder
    private var share: some View {
        if workout.isSimulated {
            Text("This is a simulated workout. It is never sent to Strava or Apple Health.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
        } else if cloud.stravaConnected {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Button(workout.stravaUploadedAt == nil ? "Send to Strava" : "Sent to Strava") {
                    Task { _ = await cloud.uploadToStrava(workout, context: context) }
                }
                .buttonStyle(.secondaryPill)
                .disabled(cloud.isWorking || workout.stravaUploadedAt != nil)
                if let message = cloud.message {
                    Text(message)
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                }
            }
        } else {
            Text("Connect Strava in Settings to send workouts there.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
        }
    }

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

    /// Workouts found automatically are all "Workout". This lets you say what it was.
    /// The choice is kept when later syncs update the workout (same id, kind is never overwritten).
    private var kindPicker: some View {
        HStack(spacing: DS.Space.m) {
            Text("Type")
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
            Spacer(minLength: DS.Space.s)
            Picker("Type", selection: Binding(
                get: { workout.kind },
                set: { workout.kindRaw = $0.rawValue; try? context.save() })) {
                ForEach(WorkoutKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(DS.Colors.primary)
        }
        .frame(minHeight: 52)
    }

    /// Four numbers, no boxes.
    private var stats: some View {
        VStack(spacing: DS.Space.l) {
            kindPicker
            Hairline()
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
                          valueLabel: { "\(Int($0.value.rounded())) bpm · \($0.date.formatted(date: .omitted, time: .shortened))" },
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
