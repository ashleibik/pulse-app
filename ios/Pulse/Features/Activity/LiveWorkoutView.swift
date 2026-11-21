import SwiftUI
import SwiftData
import PulseCore

/// The workout you're timing: live heart rate, the running time, the type, Finish (ios/design/DESIGN.md §4b-4).
///
/// A sheet over any tab, presented by RootView. Swiping it down or the chevron keeps the workout running
/// (`WorkoutInProgress`), and the bar above the tab bar (`WorkoutBar`) opens it again. The workout carries on when Pulse is
/// closed. Live heart rate streams only while this sheet is open and Pulse is on screen (it needs the band paired and
/// nearby). The saved numbers (average heart rate, zones, strain) are filled in from the band's stored data, at the next
/// sync at the latest.
///
/// ⚠ The sheet, the bar and keeping a workout through closing Pulse have not run on the phone yet.
struct LiveWorkoutView: View {
    @Environment(BandManager.self) private var band
    @Environment(WorkoutInProgress.self) private var workout
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var profiles: [ProfileRecord]
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]

    /// The workout as last seen running, so the sheet keeps its content while it slides away after Finish or Discard.
    @State private var shown = RunningWorkout(start: .now, kind: .run)
    @State private var confirmDiscard = false
    @State private var confirmTooShort = false

    private var current: RunningWorkout { workout.running ?? shown }
    private var maxHR: Double { profiles.first?.estimatedMaxHeartRate() ?? 190 }

    var body: some View {
        VStack(spacing: DS.Space.l) {
            ScreenHeader(title: "Workout", isSheet: true) {
                IconButton(systemName: "trash", label: "Discard workout") { confirmDiscard = true }
                IconButton(systemName: "chevron.down", label: "Keep it running and go back") { workout.isShowing = false }
            }
            Spacer(minLength: 0)

            ZStack {
                // The ring fills with how hard you're going: heart rate as a share of your maximum.
                GlowOrb(fraction: min(1, Double(band.liveHeartRate ?? 0) / maxHR), color: zoneColor)
                VStack(spacing: 0) {
                    Text(band.liveHeartRate.map(String.init) ?? "--")
                        .font(.system(size: 84, weight: .bold).width(.condensed))
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.primary)
                        .contentTransition(.numericText())
                        .animation(DS.Motion.spring, value: band.liveHeartRate)
                    Text("BPM")
                        .textStyle(.label)
                        .foregroundStyle(DS.Colors.secondary)
                }
            }
            .frame(width: 260, height: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Heart rate")
            .accessibilityValue(band.liveHeartRate.map { "\($0) beats per minute" } ?? "not available")

            // A clock that redraws once a second, counted from the stored start (so it is right after reopening).
            TimelineView(.periodic(from: current.start, by: 1)) { timeline in
                Text(current.elapsedText(at: timeline.date))
                    .textStyle(.display)
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.primary)
            }

            if band.liveHeartRate == nil {
                Text("Live heart rate needs your band paired and nearby. The timer works without it.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.side)
            }
            Spacer(minLength: 0)

            HStack(spacing: DS.Space.m) {
                Text("Type")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.primary)
                Spacer()
                Picker("Type", selection: Binding(get: { current.kind }, set: { workout.setKind($0) })) {
                    ForEach(WorkoutKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(DS.Colors.accent)
            }
            .padding(.horizontal, DS.Space.side)

            Button {
                finish()
            } label: {
                Text("Finish workout").frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryPill)
            .padding(.horizontal, DS.Space.side)
            .padding(.bottom, DS.Space.l)
        }
        .monoSheet()
        .onAppear {
            if let running = workout.running { shown = running }
            band.startLive(.workout, context: context)
        }
        .onDisappear { band.stopLive(.workout) }
        .onChange(of: workout.running) { _, running in
            if let running { shown = running }
        }
        // Nobody sees the live number with Pulse in the background: stop it there (band battery, and pulls carry on).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                band.startLive(.workout, context: context)
            } else if phase == .background {
                band.stopLive(.workout)
            }
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard() }
        }
        .confirmationDialog("Too short. Discard?", isPresented: $confirmTooShort, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("A workout needs at least a minute to be saved.")
        }
    }

    /// Green while easy, yellow when hard, red near your maximum.
    private var zoneColor: Color {
        guard let hr = band.liveHeartRate else { return DS.Colors.tertiary }
        let share = Double(hr) / maxHR
        if share < 0.7 { return DS.Colors.accent }
        return share < 0.9 ? DS.Colors.warn : DS.Colors.alert
    }

    private func discard() {
        band.stopLive(.workout)
        workout.end()
    }

    private func finish() {
        guard let running = workout.running else {
            discard()
            return
        }
        let end = Date.now
        guard !WorkoutDetector.isTooShort(start: running.start, end: end) else {
            confirmTooShort = true
            return
        }
        let raw = PulseStore.minutes(from: running.start, to: end, in: context)
        let rest = days.first { Calendar.current.isDate($0.date, inSameDayAs: running.start) }?.restingHeartRate
        let saved = WorkoutDetector.manual(kind: running.kind, start: running.start, end: end, minutes: raw,
                                           profile: profiles.first?.metricsProfile ?? MetricsProfile(),
                                           body: profiles.first?.calorieBody(), restingHeartRate: rest)
        context.insert(WorkoutRecord(saved))
        try? context.save()
        // Live off first, so the pull below runs straight away.
        band.stopLive(.workout)
        workout.end()
        // The band still holds the last minutes: fetch them so the numbers fill in.
        Task { await band.refresh(context: context) }
    }
}

/// The workout you're timing, above the tab bar on every tab (ios/design/DESIGN.md §4b-4). Tapping it opens the workout
/// sheet. Nothing at all while no workout runs.
struct WorkoutBar: View {
    @Environment(WorkoutInProgress.self) private var workout

    var body: some View {
        if let running = workout.running {
            Button { workout.isShowing = true } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: running.kind.symbolName)
                        .foregroundStyle(DS.Colors.strainTint)
                    Text(running.kind.displayName)
                        .textStyle(.bodyStrong)
                        .foregroundStyle(DS.Colors.primary)
                        .lineLimit(1)
                    TimelineView(.periodic(from: running.start, by: 1)) { timeline in
                        Text(running.elapsedText(at: timeline.date))
                            .textStyle(.body)
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.s)
                    Image(systemName: "chevron.up")
                        .foregroundStyle(DS.Colors.secondary)
                }
                .padding(.horizontal, DS.Space.m)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Capsule().fill(DS.Colors.surface))
                .overlay(Capsule().strokeBorder(DS.Colors.border, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
            .padding(.horizontal, DS.Space.side)
            .padding(.bottom, DS.Space.s)
            .accessibilityLabel("\(running.kind.displayName) workout running")
            .accessibilityHint("Opens the workout")
        }
    }
}
