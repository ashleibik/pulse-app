import SwiftUI
import SwiftData
import PulseCore

/// Today's strain vs target, time in heart-rate zones, and the workout history.
struct ActivityView: View {
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Query(sort: \WorkoutRecord.start, order: .reverse) private var workouts: [WorkoutRecord]
    @Query private var profiles: [ProfileRecord]
    @Environment(\.modelContext) private var context
    @Environment(DemoDataLoader.self) private var loader

    @State private var zoneMinutes: [Int] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    if let today = days.first {
                        strainCard(today)
                        zonesCard
                    }
                    SectionHeader(title: "Workouts", trailing: "last 14 days")
                        .padding(.top, 8)
                    if recent.isEmpty {
                        ContentUnavailableView("No workouts yet", systemImage: "figure.run",
                                               description: Text("Workouts will appear here automatically."))
                    }
                    ForEach(groupedByDay) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(dayTitle(group.day))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                            ForEach(group.items) { workout in
                                NavigationLink(value: workout.id) {
                                    WorkoutRow(workout: workout)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .card()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .navigationTitle("Activity")
            .navigationDestination(for: UUID.self) { id in
                if let workout = workouts.first(where: { $0.id == id }) {
                    WorkoutDetailView(workout: workout)
                }
            }
            .task(id: "\(loader.rawDataReady)-\(days.first?.strain ?? 0)") { loadZones() }
        }
    }

    private func loadZones() {
        let start = Calendar.current.startOfDay(for: .now)
        let minutes = PulseStore.minutes(from: start, to: .now, in: context)
        let maxHR = profiles.first?.estimatedMaxHeartRate() ?? 190
        zoneMinutes = HeartRateZones.minutesPerZone(minutes.map(\.averageHeartRate), maxHeartRate: maxHR)
    }

    private func strainCard(_ today: DaySummaryRecord) -> some View {
        let target = StrainGuidance.targetRange(recovery: today.recoveryScore)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Day strain").font(.headline)
                    Text("Target \(Int(target.lowerBound))–\(Int(target.upperBound)) based on your recovery")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Text(PulseFormat.strain(today.strain))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            StrainTargetBar(strain: today.strain, target: target)
            Text(StrainGuidance.advice(strain: today.strain, recovery: today.recoveryScore))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .card()
    }

    private var zonesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Heart rate zones today",
                          trailing: "max HR \(Int(profiles.first?.estimatedMaxHeartRate() ?? 190))")
            if zoneMinutes.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            } else if zoneMinutes.reduce(0, +) == 0 {
                Text("No time above 50% of your max heart rate yet today.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ZoneBars(minutes: zoneMinutes)
            }
        }
        .card()
    }

    private var recent: [WorkoutRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
        return workouts.filter { $0.start >= cutoff }
    }

    struct DayGroup: Identifiable {
        let day: Date
        let items: [WorkoutRecord]
        var id: Date { day }
    }

    private var groupedByDay: [DayGroup] {
        let groups = Dictionary(grouping: recent) { Calendar.current.startOfDay(for: $0.start) }
        return groups.keys.sorted(by: >).map { DayGroup(day: $0, items: groups[$0] ?? []) }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

#Preview {
    ActivityView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DemoDataLoader())
        .preferredColorScheme(.dark)
}
