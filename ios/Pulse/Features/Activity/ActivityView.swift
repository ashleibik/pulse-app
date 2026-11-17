import SwiftUI
import SwiftData
import PulseCore

/// Today's strain vs target, time in heart-rate zones, and the workout history.
/// Mono design (ios/design/DESIGN.md).
struct ActivityView: View {
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Query(sort: \WorkoutRecord.start, order: .reverse) private var workouts: [WorkoutRecord]
    @Query private var profiles: [ProfileRecord]
    @Environment(\.modelContext) private var context
    @Environment(DataLoader.self) private var loader

    @State private var zoneMinutes: [Int] = []
    /// The open workout (empty = the list is showing).
    @State private var path: [UUID] = []
    @State private var showAdd = false
    @State private var showLive = false
    /// Rough active calories so far today.
    @State private var activeCalories = 0

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    if let today = days.first {
                        strain(today).riseIn(0)
                        zones.riseIn(1)
                    }
                    workoutList.riseIn(2)
                }
                .padding(.horizontal, DS.Space.side)
                .padding(.top, DS.Space.l)
                .padding(.bottom, DS.Space.xxl)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                ScreenHeader(title: "Activity") {
                    IconButton(systemName: "play", label: "Start a workout") { showLive = true }
                    IconButton(systemName: "plus", label: "Add a past workout") { showAdd = true }
                }
            }
            .sheet(isPresented: $showAdd) { AddWorkoutView() }
            .fullScreenCover(isPresented: $showLive) { LiveWorkoutView() }
            .monoBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                if let workout = workouts.first(where: { $0.id == id }) {
                    WorkoutDetailView(workout: workout) {
                        // Go back to the list first, then delete, so the screen never shows a deleted workout.
                        path.removeAll()
                        Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            context.delete(workout)
                            try? context.save()
                        }
                    }
                }
            }
            .task(id: "\(loader.rawDataReady)-\(loader.revision)-\(days.first?.strain ?? 0)") { loadZones() }
            .task {
                // Only the screenshot job sets this: open the hardest workout straight away.
                if LaunchOptions.route == "workout", path.isEmpty,
                   let hardest = workouts.max(by: { $0.strain < $1.strain }) {
                    path = [hardest.id]
                }
            }
        }
    }

    private func loadZones() {
        let start = Calendar.current.startOfDay(for: .now)
        let minutes = PulseStore.minutes(from: start, to: .now, in: context)
        let maxHR = profiles.first?.estimatedMaxHeartRate() ?? 190
        zoneMinutes = HeartRateZones.minutesPerZone(minutes.map(\.averageHeartRate), maxHeartRate: maxHR)
        activeCalories = DailyEnergy.activeCalories(minutes: minutes, restingHR: days.first?.restingHeartRate ?? 60,
                                                    maxHR: maxHR)
    }

    // MARK: - Sections

    /// The answer: how hard today has been, against the target.
    private func strain(_ today: DaySummaryRecord) -> some View {
        let target = StrainGuidance.targetRange(recovery: today.recoveryScore)
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "flame")
                    .accessibilityHidden(true)
                Text("Day strain")
            }
            .textStyle(.caption)
            .foregroundStyle(DS.Colors.secondary)

            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                HeroNumber(value: today.strain) { PulseFormat.strain($0) }
                Text("of 21")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
            StrainMeter(strain: today.strain, target: target)
                .padding(.vertical, DS.Space.xs)
            Text(StrainGuidance.advice(strain: today.strain, recovery: today.recoveryScore))
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("About \(activeCalories) active kcal today (a rough estimate from heart rate).")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one card on this screen.
    private var zones: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Heart rate zones",
                         trailing: "Max HR \(Int(profiles.first?.estimatedMaxHeartRate() ?? 190))")
            if zoneMinutes.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            } else if zoneMinutes.reduce(0, +) == 0 {
                Text("No time above 50% of your max heart rate yet today.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ZoneBars(minutes: zoneMinutes, track: DS.Colors.muted)
            }
        }
        .monoCard()
    }

    private var workoutList: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Workouts", trailing: "Last 14 days")
            if recent.isEmpty {
                Text("No workouts yet. Pulse finds them by itself from your heart rate. Use + to add one it missed.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .padding(.top, DS.Space.s)
            }
            ForEach(groupedByDay) { group in
                Text(dayTitle(group.day))
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .padding(.top, DS.Space.l)
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, workout in
                    if index > 0 { Hairline() }
                    NavigationLink(value: workout.id) {
                        ActivityRow(workout: workout, showsChevron: true)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: - Helpers

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

#Preview("Light") {
    ActivityView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DataLoader())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ActivityView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DataLoader())
        .preferredColorScheme(.dark)
}
