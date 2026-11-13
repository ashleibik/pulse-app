import SwiftUI
import SwiftData
import Charts
import PulseCore

/// Last night (and earlier nights with the arrows): duration, need, efficiency, overnight HR.
struct SleepView: View {
    @Query(sort: \SleepRecord.end, order: .reverse) private var sleeps: [SleepRecord]
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Environment(\.modelContext) private var context
    @Environment(DemoDataLoader.self) private var loader

    @State private var nightIndex = 0          // 0 = last night, 1 = the night before, ...
    @State private var heartRate: [MinutePoint] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                if sleeps.isEmpty {
                    ContentUnavailableView("No sleep yet", systemImage: "moon.zzz",
                                           description: Text("Wear your band to bed and your night will appear here."))
                        .padding(.top, 80)
                } else {
                    let night = sleeps[min(nightIndex, sleeps.count - 1)]
                    content(night)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                }
            }
            .screenBackground()
            .navigationTitle("Sleep")
            .task(id: "\(nightIndex)-\(loader.rawDataReady)-\(sleeps.count)") {
                guard !sleeps.isEmpty else { return }
                heartRate = MinutePoint.load(from: sleeps[min(nightIndex, sleeps.count - 1)].start,
                                             to: sleeps[min(nightIndex, sleeps.count - 1)].end, context: context)
            }
        }
    }

    @ViewBuilder
    private func content(_ night: SleepRecord) -> some View {
        let need = days.first { Calendar.current.isDate($0.date, inSameDayAs: night.end) }?.sleepNeedMinutes ?? 480
        VStack(spacing: Theme.spacing) {
            nightPicker(night)

            // Headline numbers
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(PulseFormat.duration(minutes: night.asleepMinutes))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("asleep").foregroundStyle(Theme.secondaryText)
                }
                ProgressView(value: min(1, Double(night.asleepMinutes) / Double(need)))
                    .tint(Theme.sleep)
                Text("\(Int((Double(night.asleepMinutes) / Double(need) * 100).rounded()))% of the \(PulseFormat.duration(minutes: need)) you needed")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
            .card()

            // Overnight heart rate
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Heart rate", trailing: lowestText)
                if heartRate.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    Chart(heartRate) { point in
                        LineMark(x: .value("Time", point.date), y: .value("BPM", point.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Theme.heart)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                    .frame(height: 160)
                    .accessibilityLabel("Overnight heart rate chart. \(lowestText ?? "")")
                }
            }
            .card()

            // Details
            HStack(spacing: Theme.spacing) {
                MetricTile(title: "Efficiency", value: PulseFormat.percent(efficiency(night) * 100),
                           caption: "asleep / in bed", color: Theme.sleep, systemImage: "bed.double.fill")
                MetricTile(title: "Wake-ups", value: "\(night.disturbances)",
                           caption: "\(night.awakeMinutes) min awake", color: Theme.sleep, systemImage: "eye.fill")
            }
            Text("Sleep stages (deep/REM) aren't shown: from heart rate and motion alone they're too inaccurate to be useful.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 4)
        }
    }

    private func nightPicker(_ night: SleepRecord) -> some View {
        HStack {
            Button { nightIndex += 1 } label: { Image(systemName: "chevron.left") }
                .disabled(nightIndex >= sleeps.count - 1)
                .accessibilityLabel("Previous night")
            Spacer()
            VStack(spacing: 2) {
                Text(nightIndex == 0 ? "Last night" : night.end.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.headline)
                Text("\(night.start.formatted(date: .omitted, time: .shortened)) – \(night.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button { nightIndex -= 1 } label: { Image(systemName: "chevron.right") }
                .disabled(nightIndex == 0)
                .accessibilityLabel("Next night")
        }
        .font(.title3)
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: nightIndex)
    }

    private var lowestText: String? {
        heartRate.map(\.value).min().map { "lowest \(Int($0.rounded())) bpm" }
    }

    private func efficiency(_ night: SleepRecord) -> Double {
        let inBed = night.end.timeIntervalSince(night.start) / 60
        return inBed > 0 ? Double(night.asleepMinutes) / inBed : 0
    }
}

/// Average HR for one minute, for charts.
struct MinutePoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }

    /// Reads raw minutes in [from, to) and turns them into chart points (skipping off-wrist minutes).
    /// Call it with the view's (main) context, from the main thread.
    static func load(from: Date, to: Date, context: ModelContext) -> [MinutePoint] {
        let descriptor = FetchDescriptor<MinuteRecord>(
            predicate: #Predicate<MinuteRecord> { record in record.start >= from && record.start < to },
            sortBy: [SortDescriptor(\.start)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return records.compactMap { record in
            record.value.averageHeartRate.map { MinutePoint(date: record.start, value: $0) }
        }
    }
}

#Preview {
    SleepView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DemoDataLoader())
        .preferredColorScheme(.dark)
}
