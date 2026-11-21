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
    @Environment(BandManager.self) private var band

    @State private var zoneMinutes: [Int] = []
    /// The open workout (empty = the list is showing).
    @State private var path: [UUID] = []
    @State private var showAdd = false
    @State private var showLive = false
    /// Active calories so far today, from heart rate and counted steps. nil = not enough details to work them out.
    @State private var activeCalories: Int?
    /// Today's steps, as the band counted them. nil = it hasn't counted today.
    @State private var steps: Steps.Day?
    /// This week's VO₂ max estimate. nil = fewer than 4 nights of resting heart rate.
    @State private var vo2: VO2Max.Estimate?
    @State private var restingNights = 0

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    if let today = days.first {
                        strain(today).riseIn(0)
                        zones.riseIn(1)
                    }
                    stepsByHour.riseIn(1)
                    fitness.riseIn(2)
                    workoutList.riseIn(2)
                }
                .padding(.horizontal, DS.Space.side)
                .padding(.top, DS.Space.l)
                .padding(.bottom, DS.Space.tabBarClearance)
            }
            .refreshable { await band.refresh(context: context) }
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
                        // One Pulse found stays deleted: the next sync doesn't record it again.
                        if workout.sourceRaw == DataSource.history.rawValue { DismissedWorkouts.dismiss(workout.id) }
                        Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            context.delete(workout)
                            try? context.save()
                        }
                    }
                }
            }
            .task(id: "\(loader.rawDataReady)-\(loader.revision)-\(days.first?.strain ?? 0)-\(band.stepsRevision)") { loadZones() }
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
        // The newest resting heart rate: today's row only gets one once last night is in.
        let resting = days.lazy.compactMap { $0.restingHeartRate ?? $0.baselineRestingHeartRate }.first
        let zones = OpenStrapZones.zones(restingHistory: Array(days.prefix(28)).compactMap(\.restingHeartRate), maxHeartRate: maxHR)
        zoneMinutes = OpenStrapZones.secondsInZones(minutes, zones: zones).map { $0 / 60 }
        let counted = StepsData.minutes(from: start, to: .now, in: context)
        activeCalories = profiles.first?.calorieBody().flatMap { body in
            DailyCalories.estimate(minutes: minutes, steps: counted, body: body, dayStart: start, end: .now, maxHeartRate: maxHR,
                                   restingHeartRate: resting)?.active
        }
        steps = Steps.day(counted, dayStart: start, end: .now, calendar: .current)
        let profile = profiles.first
        let week = Calendar.current.date(byAdding: .day, value: -6, to: start) ?? start
        restingNights = days.filter { $0.date >= week && $0.restingHeartRate != nil }.count
        vo2 = VO2Max.estimate(days: days.map(\.value), workouts: workouts.map(\.value), on: .now, calendar: .current,
                              maxHeartRate: maxHR, age: profile?.age(), sex: profile?.sex ?? .unspecified,
                              waistCm: profile?.waistCm)
    }

    /// VO₂ max from the week's resting heart rate (DESIGN.md §4b-9). An estimate, and labelled as one.
    private var fitness: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionTitle(title: "VO₂ max", trailing: "Estimated")
            if let vo2 {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Text("\(Int(vo2.value.rounded()))")
                        .textStyle(.title)
                        .foregroundStyle(DS.Colors.primary)
                    Text(vo2.standardError.map { "± \(Int($0.rounded())) ml/kg/min" } ?? "ml/kg/min")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                }
                Text(vo2.method == .nonExercise
                     ? "From your age, waist, this week's workouts and your resting heart rate (\(Int(vo2.restingHeartRate.rounded())) bpm over \(vo2.nights) nights)."
                     : "From your max heart rate and your resting heart rate (\(Int(vo2.restingHeartRate.rounded())) bpm over \(vo2.nights) nights). Add your waist in Settings to include your activity.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A trend to watch over weeks, not a lab test.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            } else {
                Text("Needs a resting heart rate from \(VO2Max.fewestNights) of the last 7 nights. You have \(restingNights).")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .monoCard()
        .accessibilityElement(children: .combine)
    }

    /// Today's steps, hour by hour (DESIGN.md §4b-8), with the minute the band is counting right now.
    private var stepsByHour: some View {
        let steps = StepsData.live(self.steps, dayStart: .now, band: band)
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Steps")
            if let steps {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Text(steps.total.formatted())
                            .textStyle(.title)
                            .foregroundStyle(DS.Colors.primary)
                            .contentTransition(.numericText())
                        Text("today").textStyle(.caption).foregroundStyle(DS.Colors.secondary)
                    }
                    Text(StepsData.countedText(steps))
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                }
                Text("Steps by hour")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                DayBarsChart(bars: hourBars(steps.hourly), height: 110,
                             summary: "Steps by hour today, \(steps.total) in all")
            } else {
                Text(StepsData.notCountedText)
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .monoCard()
    }

    /// One bar per hour up to now; every third hour labelled.
    private func hourBars(_ hourly: [Int]) -> [DayBarsChart.Bar] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let current = calendar.dateComponents([.hour], from: start, to: .now).hour ?? 0
        return hourly.prefix(current + 1).enumerated().map { index, count in
            let hour = calendar.date(byAdding: .hour, value: index, to: start) ?? start
            return DayBarsChart.Bar(id: "\(index)", label: index % 3 == 0 ? hour.formatted(.dateTime.hour()) : "",
                                    value: Double(count), isHighlighted: index == current,
                                    spokenName: "\(hour.formatted(.dateTime.hour())), \(count) steps")
        }
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
            if let activeCalories {
                Text("About \(activeCalories) active kcal today, from your heart rate and steps.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
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
                Text("No time in your heart rate zones yet today.")
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
                Text("No workouts in the last 14 days. Pulse records walks and runs from your steps and other workouts from your heart rate. Use + to add one it missed.")
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
        // A walk an earlier version asked about stays hidden until the next detection replaces it.
        return workouts.filter { $0.start >= cutoff && $0.isSuggestion != true }
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
        .environment(BandManager())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ActivityView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DataLoader())
        .environment(BandManager())
        .preferredColorScheme(.dark)
}
