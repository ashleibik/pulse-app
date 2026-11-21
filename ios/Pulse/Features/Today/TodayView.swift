import SwiftUI
import SwiftData
import PulseCore

/// Home screen (DESIGN.md §4b). Layout modelled on the WHOOP app's home, in Pulse's own Glow look:
///
///   header (settings · ‹ TODAY › · band battery)
///   three rings: Sleep % · Recovery % · Strain
///   Health monitor · Stress monitor
///   calories · steps
///   MY DAY (+): daily outlook, journal, today's activities (sleep, workouts), add / start activity
///   live heart rate
///
/// Syncing is invisible: cached data shows at once, new data slides in, pull down to refresh.
struct TodayView: View {
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Query(sort: \WorkoutRecord.start, order: .reverse) private var workouts: [WorkoutRecord]
    @Query private var profiles: [ProfileRecord]
    @Query(sort: \SleepRecord.end, order: .reverse) private var sleepRecords: [SleepRecord]
    @Query private var journal: [JournalRecord]
    @Environment(\.modelContext) private var context
    @Environment(DataLoader.self) private var loader
    @Environment(BandManager.self) private var band
    @Environment(\.scenePhase) private var scenePhase
    @Query private var bands: [BandRecord]

    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var showSettings = LaunchOptions.route == "settings"
    @State private var showRecovery = LaunchOptions.route == "recovery"
    @State private var showSleep = false
    /// Only opened from here by the screenshot job. Normally pairing starts in Settings.
    @State private var showPairing = LaunchOptions.route == "pairing"
    @State private var showCoach = LaunchOptions.route == "coach"
    @State private var showStress = false
    @State private var showJournal = false
    @State private var showAdd = false
    @State private var showLiveWorkout = false
    @State private var openedWorkout: WorkoutRecord?
    @State private var editingNap: SleepEditTarget?
    @State private var explaining: MetricKind? = LaunchOptions.route == "explainer" ? .hrv : nil
    /// Today's stress picture and numbers so far (from today's raw minutes).
    @State private var stress: StressMonitor.Day?
    @State private var soFar: TodaySoFar?
    /// The selected day's estimated calories (nil = no band data that day, or the profile is incomplete).
    @State private var calories: DailyCalories.Estimate?
    /// The selected day's steps, as the band counted them (nil = it never counted that day).
    @State private var steps: Steps.Day?
    /// Respiratory rate of the selected night and the 30 nights before (for the health monitor).
    @State private var respiratory: (today: Double?, history: [Double]) = (nil, [])
    /// The live heart-rate card is streaming (only while this screen is open).
    @State private var liveOn = false
    /// Goes up by one on every tap that opens something. Drives the light haptic.
    @State private var taps = 0

    private var calendar: Calendar { .current }
    private var isToday: Bool { calendar.isDateInToday(selectedDay) }
    private var summary: DaySummaryRecord? { days.first { calendar.isDate($0.date, inSameDayAs: selectedDay) } }
    private var mainSleep: SleepRecord? { NightVitals.mainSleep(endingOn: selectedDay, in: sleepRecords) }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if bands.isEmpty && days.isEmpty {
                        pairState
                    } else {
                        home
                    }
                }
                .padding(.horizontal, DS.Space.side)
                .padding(.top, DS.Space.m)
                .padding(.bottom, DS.Space.tabBarClearance)
                // New data slides in quietly when a pull saved something.
                .animation(DS.Motion.spring, value: loader.revision)
            }
            // The manual way, like most apps. Returns when the pull is done (or the band is away).
            .refreshable { await band.refresh(context: context) }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .defaultScrollAnchor(LaunchOptions.scroll == "bottom" ? UnitPoint.bottom : nil)
            .monoBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showRecovery) {
                RecoveryDetailView(day: summary ?? days.first, sleeps: sleepRecords, days: days)
            }
            .navigationDestination(isPresented: $showSleep) {
                SleepDetailView(day: selectedDay)
            }
            .navigationDestination(item: $openedWorkout) { workout in
                WorkoutDetailView(workout: workout)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showPairing) { PairingView() }
            .sheet(isPresented: $showCoach) { CoachView() }
            .sheet(isPresented: $showStress) { StressView(day: stress).presentationDetents([.medium, .large]) }
            .sheet(isPresented: $showJournal) { JournalView() }
            .sheet(isPresented: $showAdd) { AddWorkoutView() }
            .sheet(item: $editingNap) { SleepEditView(target: $0) }
            .fullScreenCover(isPresented: $showLiveWorkout) { LiveWorkoutView() }
            .sheet(item: $explaining) { kind in
                MetricExplainerView(kind: kind, today: days.first, history: Array(days.prefix(14)))
                    .presentationDetents([.medium, .large])
            }
            .task(id: "\(loader.revision)-\(loader.rawDataReady)-\(selectedDay.timeIntervalSince1970)-\(String(describing: calorieBody))-\(band.stepsRevision)") { load() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { setLive(false) } }
            .onDisappear { setLive(false) }
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
        }
    }

    // MARK: - Header

    /// Settings on the left, the day switcher in the middle, the band (battery / status) on the right.
    private var header: some View {
        ZStack {
            DayPager(day: $selectedDay, earliest: days.last?.date ?? .now)
            HStack {
                IconButton(systemName: "gearshape", label: "Settings") { open { showSettings = true } }
                Spacer()
                StatusPill()
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, DS.Space.side)
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.s)
        .background(DS.Colors.background)
    }

    // MARK: - Home

    private var home: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            rings.riseIn(1)
            monitors.riseIn(2)
            caloriesCard.riseIn(2)
            stepsCard.riseIn(2)
            myDay.riseIn(3)
            if days.isEmpty { firstNightCard.riseIn(4) }
            liveCard.riseIn(4)
        }
    }

    /// Sleep % · Recovery % · Strain. Each opens its page.
    private var rings: some View {
        let performance = summary.flatMap { NightVitals.performance(for: $0, sleeps: sleepRecords) }
        let recovery = summary?.recoveryScore
        let strain = summary?.strain ?? (isToday ? soFar?.strain : nil)
        return HStack(alignment: .top, spacing: DS.Space.s) {
            Button { open { showSleep = true } } label: {
                ScoreRing(fraction: performance.map { $0.score / 100 }, text: performance.map { "\(Int($0.score.rounded()))%" } ?? "--",
                          label: "SLEEP", color: DS.Colors.sleepTint)
            }
            .frame(maxWidth: .infinity)
            Button { open { showRecovery = true } } label: {
                ScoreRing(fraction: recovery.map { $0 / 100 }, text: recovery.map { "\(Int($0.rounded()))%" } ?? "--",
                          label: "RECOVERY", color: DS.Colors.zone(summary?.zone))
            }
            .frame(maxWidth: .infinity)
            Button { open { explaining = .strain } } label: {
                ScoreRing(fraction: strain.map { $0 / 21 }, text: strain.map(PulseFormat.strain) ?? "--",
                          label: "STRAIN", color: DS.Colors.strainTint)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pressable)
    }

    /// Health: are tonight's vitals within your usual range? Stress: right now.
    private var monitors: some View {
        let health = healthStatus
        let level = stress?.current?.level
        let score = stress?.hours.last(where: { $0.score != nil })
        let noLevel = stress?.isMovingNow == true ? "Moving" : (stress?.scoredHours ?? 0) > 0 ? "Too early" : "No reading"
        return HStack(alignment: .top, spacing: DS.Space.s) {
            Button { open { showRecovery = true } } label: {
                MonitorCard(title: "HEALTH MONITOR", badge: health.symbol, badgeIsSymbol: true,
                            state: health.state, stateColor: health.color, detail: health.detail)
            }
            Button { open { showStress = true } } label: {
                MonitorCard(title: "STRESS MONITOR", badge: score?.score.map { String(format: "%.1f", $0) } ?? "--",
                            badgeIsSymbol: false,
                            state: isToday ? (level?.title ?? noLevel) : "Today only",
                            stateColor: level == .high ? DS.Colors.alert : level == .medium ? DS.Colors.warn : level == .calm ? DS.Colors.accent : DS.Colors.secondary,
                            detail: score.map { $0.start.formatted(date: .omitted, time: .shortened) } ?? "6 AM to 10 PM")
            }
        }
        .buttonStyle(.pressable)
    }

    private var healthStatus: (state: String, detail: String, symbol: String, color: Color) {
        guard let summary else { return ("No night yet", "Wear it to sleep", "moon.zzz", DS.Colors.secondary) }
        let earlier = NightVitals.previous30(days, before: summary.date)
        var checks: [Bool] = []
        if let hrv = summary.hrvRMSSD,
           let ok = HealthMonitor.withinRange(hrv, history: earlier.compactMap(\.hrvRMSSD), minSpread: 5) { checks.append(ok) }
        if let rhr = summary.restingHeartRate,
           let ok = HealthMonitor.withinRange(rhr, history: earlier.compactMap(\.restingHeartRate), minSpread: 2) { checks.append(ok) }
        if let rate = respiratory.today,
           let ok = HealthMonitor.withinRange(rate, history: respiratory.history, minSpread: 1) { checks.append(ok) }
        guard !checks.isEmpty else {
            return ("Learning", "\(min(earlier.count, 3)) of 3 nights", "hourglass", DS.Colors.secondary)
        }
        let inRange = checks.filter { $0 }.count
        return inRange == checks.count
            ? ("Within range", "\(inRange)/\(checks.count) metrics", "checkmark", DS.Colors.accent)
            : ("Out of range", "\(inRange)/\(checks.count) metrics", "exclamationmark", DS.Colors.warn)
    }

    // MARK: - Calories

    private var calorieBody: DailyCalories.Body? { profiles.first?.calorieBody() }

    /// An estimate, and labelled as one.
    private var caloriesCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: 6) {
                Image(systemName: "flame")
                Text("CALORIES")
                Spacer()
                Text("Estimated").textStyle(.caption).foregroundStyle(DS.Colors.secondary)
            }
            .textStyle(.label)
            .foregroundStyle(DS.Colors.primary)
            if calorieBody == nil {
                Button { open { showSettings = true } } label: {
                    Text("Add your weight, height, birth year and sex in Settings to see this.")
                        .textStyle(.body)
                        .foregroundStyle(DS.Colors.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.pressable)
            } else {
                Text(calories.map { $0.total.formatted() } ?? "--")
                    .textStyle(.title)
                    .foregroundStyle(DS.Colors.primary)
                    .contentTransition(.numericText())
                Text(calories.map { "\($0.resting.formatted()) resting + \($0.active.formatted()) active" } ?? "No band data for this day")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                if let calories, calories.isPartial {
                    Text("Counts the \(PulseFormat.duration(minutes: calories.measuredMinutes)) your band measured")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .monoCard(padding: DS.Space.m)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Steps

    private var stepGoal: Int { profiles.first?.stepGoal ?? 10_000 }

    /// The band's own count against the daily goal (DESIGN.md §4b-8).
    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: 6) {
                Image(systemName: "figure.walk")
                Text("STEPS")
            }
            .textStyle(.label)
            .foregroundStyle(DS.Colors.primary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text(steps.map { $0.total.formatted() } ?? "--")
                    .textStyle(.title)
                    .foregroundStyle(DS.Colors.primary)
                    .contentTransition(.numericText())
                Text("of \(stepGoal.formatted())")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
            ProgressMeter(fraction: Double(steps?.total ?? 0) / Double(max(1, stepGoal)))
                .padding(.vertical, DS.Space.xs)
            Text(steps.map(StepsData.countedText) ?? StepsData.notCountedText)
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .monoCard(padding: DS.Space.m)
        .accessibilityElement(children: .combine)
    }

    // MARK: - My Day

    private var myDay: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("My Day")
                    .textStyle(.heading)
                    .foregroundStyle(DS.Colors.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { open { showAdd = true } } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.bold))
                        .foregroundStyle(DS.Colors.onAccent)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(DS.Colors.primary))
                }
                .accessibilityLabel("Add activity")
            }
            outlookRow(symbol: "sun.max", title: "Your daily outlook") { showCoach = true }
            outlookRow(symbol: "square.and.pencil", title: journalTitle) { showJournal = true }
            activities
            if days.isEmpty, isToday { todaySoFar }
        }
    }

    private var journalTitle: String {
        guard let record = journal.first(where: { calendar.isDateInToday($0.day) }) else { return "Journal: log today" }
        return record.habits.isEmpty ? "Journal: logged" : "Journal: \(record.habits.count) logged"
    }

    private func outlookRow(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button { open(action) } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbol).foregroundStyle(DS.Colors.accent)
                Text(title).textStyle(.bodyStrong).foregroundStyle(DS.Colors.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(DS.Colors.tertiary)
            }
            .padding(.horizontal, DS.Space.m)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 14).fill(DS.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.Colors.border, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    /// Sleep and workouts of the day, each with its times. Add / start below.
    private var activities: some View {
        let dayWorkouts = workouts.filter { calendar.isDate($0.start, inSameDayAs: selectedDay) }
        let dayNaps = sleepRecords.filter { $0.isNap && calendar.isDate($0.end, inSameDayAs: selectedDay) }.sorted { $0.start < $1.start }
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(isToday ? "TODAY'S ACTIVITIES" : "ACTIVITIES")
                .textStyle(.label)
                .foregroundStyle(DS.Colors.primary)
                .padding(.bottom, DS.Space.xs)
            if let sleep = mainSleep {
                Button { open { showSleep = true } } label: {
                    activityRow(symbol: "moon.fill", value: PulseFormat.clock(minutes: sleep.asleepMinutes),
                                title: "SLEEP", start: sleep.start, end: sleep.end, tint: DS.Colors.sleepTint)
                }
                .buttonStyle(.pressable)
            }
            ForEach(dayNaps) { nap in
                Button { open { editingNap = SleepEditTarget(start: nap.start, end: nap.end) } } label: {
                    activityRow(symbol: "moon.zzz", value: PulseFormat.clock(minutes: nap.asleepMinutes),
                                title: "NAP", start: nap.start, end: nap.end, tint: DS.Colors.sleepTint)
                }
                .buttonStyle(.pressable)
            }
            ForEach(dayWorkouts) { workout in
                Button { open { openedWorkout = workout } } label: {
                    activityRow(symbol: workout.kind.symbolName.outlineSymbol, value: PulseFormat.strain(workout.strain),
                                title: workout.kind.displayName.uppercased(), start: workout.start, end: workout.end,
                                tint: DS.Colors.strainTint)
                }
                .buttonStyle(.pressable)
            }
            if mainSleep == nil && dayWorkouts.isEmpty && dayNaps.isEmpty {
                Text(isToday ? "Nothing yet today. Sleep and workouts show up here by themselves." : "Nothing recorded.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .padding(.vertical, DS.Space.s)
            }
            if isToday {
                HStack(spacing: DS.Space.s) {
                    Button { open { showAdd = true } } label: {
                        Label("Add activity", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondaryPill)
                    Button { open { showLiveWorkout = true } } label: {
                        Label("Start activity", systemImage: "stopwatch").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondaryPill)
                }
                .padding(.top, DS.Space.s)
            }
        }
        .monoCard(padding: DS.Space.m)
    }

    private func activityRow(symbol: String, value: String, title: String, start: Date, end: Date, tint: Color) -> some View {
        HStack(spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbol)
                Text(value).textStyle(.title)
            }
            .foregroundStyle(DS.Colors.background)
            .frame(width: 112, height: 52)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint))
            Text(title)
                .textStyle(.label)
                .foregroundStyle(DS.Colors.primary)
                .lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(start.formatted(date: .omitted, time: .shortened))
                Text(end.formatted(date: .omitted, time: .shortened))
            }
            .textStyle(.caption)
            .foregroundStyle(DS.Colors.secondary)
            Capsule().fill(tint).frame(width: 3, height: 36)
        }
        .padding(DS.Space.s)
        .background(RoundedRectangle(cornerRadius: 14).fill(DS.Colors.background.opacity(0.6)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title.capitalized), \(value), \(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))")
    }

    /// Before the first night: today's numbers from what the band has synced so far.
    private var todaySoFar: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            StatBlock(symbol: "heart", label: "Resting HR", number: soFar?.restingHeartRate,
                      format: { "\(Int($0.rounded()))" }, unit: "bpm", caption: "lowest so far", valueStyle: .heading)
            StatBlock(symbol: "waveform.path.ecg", label: "Average HR", number: soFar?.averageHeartRate,
                      format: { "\(Int($0.rounded()))" }, unit: "bpm", caption: "today", valueStyle: .heading)
            StatBlock(symbol: "clock", label: "Data", number: soFar.map { Double($0.wornMinutes) },
                      format: { PulseFormat.duration(minutes: Int($0.rounded())) }, caption: "collected", valueStyle: .heading)
        }
        .padding(.top, DS.Space.s)
    }

    /// What happens next. Recovery compares a night with YOUR normal, so the score needs a few nights.
    private var firstNightCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                Text("FIRST NIGHT")
            }
            .textStyle(.label)
            .foregroundStyle(DS.Colors.primary)
            Text("Wear it to sleep tonight. Sleep, HRV and resting HR show tomorrow morning; the recovery score comes once it has learned your normal (\(Recovery.minimumBaselineNights) nights).")
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .monoCard()
        .accessibilityElement(children: .combine)
    }

    /// The band's heart rate right now. Streams only while you ask and this screen is open.
    private var liveCard: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: 6) {
                    Image(systemName: "heart")
                    Text("LIVE HEART RATE")
                }
                .textStyle(.label)
                .foregroundStyle(DS.Colors.primary)
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Text(liveOn ? (band.liveHeartRate.map(String.init) ?? "--") : "--")
                        .textStyle(.title)
                        .foregroundStyle(liveOn && band.liveHeartRate != nil ? DS.Colors.accent : DS.Colors.primary)
                        .contentTransition(.numericText())
                        .animation(DS.Motion.spring, value: band.liveHeartRate)
                    Text("bpm").textStyle(.caption).foregroundStyle(DS.Colors.secondary)
                }
                Text(liveOn ? (band.liveHeartRate == nil ? "Connecting…" : "Stops when you leave this screen.")
                            : "Uses a little band battery.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
            Spacer()
            Button(liveOn ? "Stop" : "Show live") { setLive(!liveOn) }
                .buttonStyle(.secondaryPill)
                .fixedSize()
        }
        .monoCard(padding: DS.Space.m)
    }

    /// No band and no data yet.
    private var pairState: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            EmptyState(symbol: "waveform.path.ecg", title: "Pair your band",
                       text: "Pulse reads your band directly over Bluetooth. Pair it, wear it tonight, and your first night shows up in the morning.")
            Button("Pair your band") { showPairing = true }
                .buttonStyle(.primaryPill)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DS.Space.xl)
    }

    // MARK: - Helpers

    private func setLive(_ on: Bool) {
        guard on != liveOn else { return }
        liveOn = on
        if on { band.startLive(context: context) } else { band.stopLive() }
    }

    /// Every tap that opens something goes through here, so it also gives a light haptic.
    private func open(_ action: () -> Void) {
        taps += 1
        action()
    }

    private func load() {
        let start = calendar.startOfDay(for: .now)
        let minutes = PulseStore.minutes(from: start, to: .now, in: context)
        let profile = profiles.first?.metricsProfile ?? MetricsProfile()
        soFar = TodaySoFar.compute(minutes: minutes, profile: profile)
        let dayEnd = min(calendar.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay, .now)
        let counted = StepsData.minutes(from: selectedDay, to: dayEnd, in: context)
        calories = calorieBody.flatMap { body in
            DailyCalories.estimate(minutes: isToday ? minutes : PulseStore.minutes(from: selectedDay, to: dayEnd, in: context),
                                   steps: counted, body: body, dayStart: selectedDay, end: dayEnd, maxHeartRate: profile.maxHeartRate,
                                   restingHeartRate: days.first { calendar.isDate($0.date, inSameDayAs: selectedDay) }
                                       .flatMap { $0.restingHeartRate ?? $0.baselineRestingHeartRate })
        }
        let sleeps = sleepRecords.map(\.value)
        stress = StressMonitor.day(minutes: minutes, sleeps: sleeps, workouts: workouts.map(\.value),
                                   now: .now, calendar: calendar)
        steps = StepsData.day(selectedDay, context: context)
        // Respiratory rate needs the beat-to-beat data of each night: the selected one and up to 30 before.
        let tonight = mainSleep
        let from = calendar.date(byAdding: .day, value: -30, to: selectedDay) ?? selectedDay
        let earlier = sleepRecords.filter { !$0.isNap && $0.end < (tonight?.start ?? selectedDay) && $0.end >= from }
        Task { respiratory = await NightVitals.respiratoryRates(tonight: tonight, earlier: earlier, context: context) }
    }
}

/// "Text  >" with the icon after the title.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

#Preview {
    TodayView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DataLoader())
        .environment(BandManager())
        .environment(CloudManager())
}
