import SwiftUI
import SwiftData
import Charts
import PulseCore

/// One night at a time: how long, its stages, overnight heart rate, and why you needed what you needed.
/// Mono design (ios/design/DESIGN.md §4b-6): each stage has its own row, and its color is extra help.
struct SleepView: View {
    @Query(sort: \SleepRecord.end, order: .reverse) private var allSleeps: [SleepRecord]
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Query private var profiles: [ProfileRecord]
    @Environment(\.modelContext) private var context
    @Environment(DataLoader.self) private var loader
    @Environment(BandManager.self) private var band

    @State private var nightIndex = 0          // 0 = last night, 1 = the night before, ...
    /// A sleep found but not finished yet ends here (seconds since 1970, 0 = none). DESIGN.md §4b-2.
    @AppStorage(UnfinishedSleepStore.endKey) private var unfinishedSleepEnd: Double = 0
    @State private var heartRate: [ChartPoint] = []
    @State private var segments: [SleepSegment] = []
    /// Breaths per minute for the night on screen (nil = no clear reading).
    @State private var breathing: Double?
    /// The block tapped in the night chart.
    @State private var selectedSegment: SleepSegment?
    /// The phase whose explanation sheet is open.
    @State private var explainedPhase: SleepPhaseSelection?
    @State private var editing: SleepEditTarget?
    @State private var addingNap = false
    /// The Sleep planner's wake time (minutes after midnight, -1 = your usual one) and goal.
    @AppStorage(Notifier.plannerWakeKey) private var plannerWake = -1
    @AppStorage(Notifier.plannerGoalKey) private var plannerGoal = SleepPlanner.Goal.peak.rawValue

    private var sleeps: [SleepRecord] { allSleeps.filter { !$0.isNap } }

    var body: some View {
        ScrollView {
            Group {
                if sleeps.isEmpty {
                    EmptyState(symbol: "moon.zzz", title: "No sleep yet",
                               text: UnfinishedSleepStore.isWaiting(end: unfinishedSleepEnd)
                                   ? UnfinishedSleepNote.text : "Wear your band to bed and your night will appear here.")
                        .padding(.top, DS.Space.xxl)
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        // The newest night is on screen, and a newer sleep is on its way.
                        if nightIndex == 0 && UnfinishedSleepStore.isWaiting(end: unfinishedSleepEnd) {
                            UnfinishedSleepNote()
                        }
                        content(sleeps[min(nightIndex, sleeps.count - 1)])
                    }
                }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.tabBarClearance)
        }
        .refreshable { await band.refresh(context: context) }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        // Only the screenshot job sets this (to capture the lower half of the screen).
        .defaultScrollAnchor(LaunchOptions.scroll == "bottom" ? UnitPoint.bottom : nil)
        .monoBackground()
        .task(id: "\(nightIndex)-\(loader.rawDataReady)-\(loader.revision)-\(sleeps.count)") { await loadNight() }
        .sensoryFeedback(.selection, trigger: nightIndex)
        .sensoryFeedback(.selection, trigger: selectedSegment)
        .onChange(of: nightIndex) { _, _ in selectedSegment = nil }
        .sheet(item: $editing) { SleepEditView(target: $0) }
        .sheet(isPresented: $addingNap) {
            AddNapView(otherSleeps: allSleeps.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) })
        }
        .sheet(item: $explainedPhase) { item in
            let totals = SleepTimeline.totals(segments)
            SleepPhaseInfoView(phase: item.phase, minutes: totals[item.phase] ?? 0,
                               nightMinutes: totals.values.reduce(0, +))
                .presentationDetents([.medium, .large])
        }
    }

    private func loadNight() async {
        guard !sleeps.isEmpty else { return }
        let night = sleeps[min(nightIndex, sleeps.count - 1)]
        let (start, end) = (night.start, night.end)
        let around = PulseStore.minutes(from: start.addingTimeInterval(-SleepTimeline.stagingPadding),
                                        to: end.addingTimeInterval(SleepTimeline.stagingPadding), in: context)
        let minutes = around.filter { $0.start >= start && $0.start < end }
        heartRate = minutes.compactMap { m in m.averageHeartRate.map { ChartPoint(date: m.start, value: $0) } }
        // The stages take a moment on a full night, so they are worked out off the main thread.
        let built = await Task.detached(priority: .userInitiated) { SleepTimeline.build(minutes: around, from: start, to: end) }.value
        guard !Task.isCancelled else { return }
        segments = built
        // The spectrum takes a moment on a full night, so it runs off the main thread.
        let rate = await Task.detached(priority: .utility) { RespiratoryRate.night(minutes: minutes) }.value
        if !Task.isCancelled { breathing = rate }
    }

    // MARK: - Sections

    /// Title on the left, older / newer night on the right.
    private var header: some View {
        ScreenHeader(title: "Sleep") {
            if !sleeps.isEmpty {
                IconButton(systemName: "pencil", label: "Edit this sleep") {
                    let night = sleeps[min(nightIndex, sleeps.count - 1)]
                    editing = SleepEditTarget(start: night.start, end: night.end)
                }
            }
            IconButton(systemName: "chevron.left", label: "Previous night") { nightIndex += 1 }
                .disabled(nightIndex >= sleeps.count - 1)
            IconButton(systemName: "chevron.right", label: "Next night") { nightIndex -= 1 }
                .disabled(nightIndex == 0)
        }
    }

    private func content(_ night: SleepRecord) -> some View {
        let summary = days.first { Calendar.current.isDate($0.date, inSameDayAs: night.end) }
        let need = summary?.sleepNeedMinutes ?? 480
        return VStack(alignment: .leading, spacing: DS.Space.xxl) {
            hero(night, need: need).riseIn(0)
            if night.value.reviewReason != nil {
                SleepReviewCard(sleep: night).riseIn(1)
            }
            timeline(night).riseIn(1)
            napsCard(after: night).riseIn(2)
            heart.riseIn(2)
            HStack(alignment: .top, spacing: DS.Space.m) {
                StatBlock(symbol: "bed.double", label: "Efficiency",
                          number: efficiency(night) * 100,
                          format: { PulseFormat.percent($0) },
                          caption: "asleep / in bed")
                StatBlock(symbol: "eye", label: "Wake-ups",
                          number: Double(night.disturbances),
                          format: { "\(Int($0.rounded()))" },
                          caption: "\(night.awakeMinutes) min awake")
            }
            .riseIn(3)
            Hairline()
            HStack(alignment: .top, spacing: DS.Space.m) {
                StatBlock(symbol: "calendar", label: "Consistency",
                          number: SleepConsistency.score(sleeps.map(\.value), calendar: .current),
                          format: { PulseFormat.percent($0) },
                          caption: "regular bed and wake times")
                StatBlock(symbol: "lungs", label: "Breathing",
                          number: breathing,
                          format: { String(format: "%.1f", $0) }, unit: "/ min",
                          caption: breathing == nil ? "needs beat-to-beat data" : "breaths while asleep")
            }
            if nightIndex == 0 {
                plannerCard.riseIn(4)
            }
            if let summary {
                needBreakdown(for: summary, night: night).riseIn(4)
            }
        }
    }

    // MARK: - Sleep planner

    private var goal: SleepPlanner.Goal { SleepPlanner.Goal(rawValue: plannerGoal) ?? .peak }
    private var usualWake: Int? { SleepPlanner.usualWake(sleeps: allSleeps.map(\.value), calendar: .current) }

    /// The wake-up time as a time of day for the picker: the one you chose, else your usual one, else 7:00.
    private var wakeTime: Binding<Date> {
        Binding(
            get: {
                let minutes = plannerWake >= 0 ? plannerWake : (usualWake ?? 7 * 60)
                return Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(minutes) * 60)
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                plannerWake = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                Notifier.refresh(context: context)
            })
    }

    /// When to go to bed tonight for a wake-up time and a goal (DESIGN.md §4b-10).
    private var plannerCard: some View {
        let plan = Notifier.plan(context: context)
        let need = Notifier.tonightsNeed(context: context)
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Sleep planner", trailing: "Tonight")
            PillPicker(options: SleepPlanner.Goal.allCases, label: { $0.title },
                       selection: Binding(get: { goal }, set: { plannerGoal = $0.rawValue; Notifier.refresh(context: context) }))
            HStack(spacing: DS.Space.m) {
                Text("Wake up")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.primary)
                Spacer(minLength: DS.Space.s)
                DatePicker("Wake up", selection: wakeTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
            }
            .frame(minHeight: 52)
            if plannerWake >= 0, usualWake != nil {
                Button("Use my usual wake-up time") {
                    plannerWake = -1
                    Notifier.refresh(context: context)
                }
                .buttonStyle(.secondaryPill)
            }
            if let plan, let need {
                Hairline()
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Be in bed by \(plan.bedtime.formatted(date: .omitted, time: .shortened))")
                        .textStyle(.heading)
                        .foregroundStyle(DS.Colors.accent)
                    Text("\(PulseFormat.duration(minutes: plan.sleepMinutes)) of sleep: \(Int((goal.share * 100).rounded()))% of tonight's \(PulseFormat.duration(minutes: Int(need.rounded()))) need.")
                        .textStyle(.body)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(plan.efficiency.map { "Plus \(plan.inBedMinutes - plan.sleepMinutes) minutes for the time you usually lie awake (you're asleep \(Int(($0 * 100).rounded()))% of your time in bed)." }
                         ?? "Once Pulse knows a night, it adds the time you usually lie awake.")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("Pick a wake-up time. After 3 nights Pulse also knows your usual one.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .monoCard()
    }

    /// The answer: how long you slept, and how that compares with what you needed.
    private func hero(_ night: SleepRecord, need: Int) -> some View {
        let fraction = Double(night.asleepMinutes) / Double(max(need, 1))
        let title = nightIndex == 0 ? "Last night" : night.end.formatted(.dateTime.weekday(.wide).month().day())
        let times = "\(night.start.formatted(date: .omitted, time: .shortened)) – \(night.end.formatted(date: .omitted, time: .shortened))"
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("\(title) · \(times)")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
            HeroNumber(value: Double(night.asleepMinutes)) {
                PulseFormat.duration(minutes: Int($0.rounded()))
            }
            ProgressMeter(fraction: fraction)
                .padding(.vertical, DS.Space.xs)
            Text("\(Int((fraction * 100).rounded()))% of the \(PulseFormat.duration(minutes: need)) you needed.")
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), asleep \(PulseFormat.duration(minutes: night.asleepMinutes))")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent of the \(PulseFormat.duration(minutes: need)) you needed")
    }

    /// The one card on this screen: when you were in each sleep stage, or awake.
    /// Tap a block to see its times; tap a label to read what that phase means.
    private func timeline(_ night: SleepRecord) -> some View {
        let totals = SleepTimeline.totals(segments)
        let ticks = SleepTimeline.axisTimes(from: night.start, to: night.end, calendar: .current)
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Your night", trailing: "Stages estimated")
            if segments.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart {
                    // The lines joining one stage to the next, behind the blocks.
                    ForEach(Self.joins(segments)) { join in
                        RuleMark(x: .value("Time", join.time),
                                 yStart: .value("Stage", join.from),
                                 yEnd: .value("Stage", join.to))
                            .foregroundStyle(DS.Colors.tertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    ForEach(segments) { segment in
                        RectangleMark(xStart: .value("Start", segment.start),
                                      xEnd: .value("End", segment.end),
                                      yStart: .value("Stage", Self.row(segment.phase) - Self.blockHalfHeight),
                                      yEnd: .value("Stage", Self.row(segment.phase) + Self.blockHalfHeight))
                            .foregroundStyle(segment.phase.tint)
                            .cornerRadius(3)
                            // With a block selected, the others step back.
                            .opacity(selectedSegment == nil || selectedSegment == segment ? 1 : 0.3)
                    }
                }
                .chartXScale(domain: night.start...night.end)
                .chartYScale(domain: -0.6...Double(SleepPhase.allCases.count) - 0.4)
                .chartYAxis {
                    AxisMarks(position: .leading, values: SleepPhase.allCases.map(Self.row)) { value in
                        AxisValueLabel {
                            if let row = value.as(Double.self) {
                                Text(Self.phase(atRow: row).title)
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: ticks) { value in
                        if let time = value.as(Date.self) {
                            AxisValueLabel(anchor: Self.anchor(time, ticks: ticks)) {
                                Text(Self.tickText(time, ticks: ticks))
                            }
                            .font(.footnote)
                            .foregroundStyle(DS.Colors.secondary)
                        }
                    }
                }
                .chartOverlay { proxy in
                    // A tap picks the block at that time of night (whatever row the finger is on).
                    GeometryReader { geometry in
                        if let plotFrame = proxy.plotFrame {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    let x = location.x - geometry[plotFrame].origin.x
                                    guard let time: Date = proxy.value(atX: x) else { return }
                                    let hit = segments.first { $0.start <= time && time < $0.end }
                                    selectedSegment = (hit == selectedSegment) ? nil : hit
                                }
                        }
                    }
                }
                .frame(height: 160)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(timelineSummary(totals))

                Text(selectionText)
                    .textStyle(.caption)
                    .foregroundStyle(selectedSegment == nil ? DS.Colors.secondary : DS.Colors.primary)

                if !sleeps.isEmpty {
                    UnknownMinutesNote(minutes: sleeps[min(nightIndex, sleeps.count - 1)].value.unknownMinutes)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s, alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: DS.Space.s) {
                    ForEach(SleepPhase.allCases.reversed(), id: \.self) { phase in
                        Button {
                            explainedPhase = SleepPhaseSelection(phase: phase)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(phase.tint)
                                        .frame(width: 10, height: 10)
                                    Text(phase.title)
                                        .textStyle(.caption)
                                        .foregroundStyle(DS.Colors.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(DS.Colors.tertiary)
                                }
                                Text(PulseFormat.duration(minutes: totals[phase] ?? 0))
                                    .textStyle(.bodyStrong)
                                    .monospacedDigit()
                                    .foregroundStyle(DS.Colors.primary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("\(phase.title), \(PulseFormat.duration(minutes: totals[phase] ?? 0))")
                        .accessibilityHint("Explains this part of your night")
                    }
                }

                // Deep + REM: what WHOOP calls restorative sleep (docs/METRICS.md §12).
                if let restorative = RestorativeSleep.make(totals: totals) {
                    Hairline()
                    HStack(spacing: DS.Space.s) {
                        // The two words stack, so the time and share always fit on one line.
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restorative")
                                .textStyle(.body)
                                .foregroundStyle(DS.Colors.primary)
                            Text("deep + REM")
                                .textStyle(.caption)
                                .foregroundStyle(DS.Colors.secondary)
                        }
                        Spacer(minLength: DS.Space.s)
                        Text("\(PulseFormat.duration(minutes: restorative.minutes)) · \(Int((restorative.share * 100).rounded()))%")
                            .textStyle(.bodyStrong)
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.primary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .monoCard()
        .animation(DS.Motion.spring, value: selectedSegment)
    }

    /// One line under the night chart: the tapped block, or how to use the chart.
    private var selectionText: String {
        guard let segment = selectedSegment else { return "Tap a block for its times, or a label to learn what it means." }
        let from = segment.start.formatted(date: .omitted, time: .shortened)
        let to = segment.end.formatted(date: .omitted, time: .shortened)
        return "\(segment.phase.title) · \(from) – \(to) · \(PulseFormat.duration(minutes: segment.minutes))"
    }

    private var heart: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Heart rate", trailing: lowestText)
            if heartRate.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 140)
            } else {
                LineChart(points: heartRate,
                          xValues: .stride(by: .hour, count: 2),
                          xFormat: .dateTime.hour(),
                          height: 140,
                          valueLabel: { "\(Int($0.value.rounded())) bpm · \($0.date.formatted(date: .omitted, time: .shortened))" },
                          summary: "Overnight heart rate. \(lowestText ?? "")")
                Text("Touch and hold the line to read your heart rate at any time of the night.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Why did I need 8h 30m?" Rebuilt from yesterday's numbers with the same formula as the engine.
    private func needBreakdown(for summary: DaySummaryRecord, night: SleepRecord) -> some View {
        let previous = days.first {
            Calendar.current.isDate($0.date, inSameDayAs: summary.date.addingTimeInterval(-86_400))
        }
        // The naps between the night before and this one.
        let nightBefore = sleeps.first { $0.end <= night.start }
        let napped = Recovery.napMinutes(allSleeps.map(\.value), after: nightBefore?.end ?? night.start.addingTimeInterval(-86_400),
                                         upTo: night.start)
        let breakdown = SleepNeedBreakdown(
            goal: Double(profiles.first?.sleepGoalMinutes ?? 480),
            previousStrain: previous?.strain,
            previousNeed: previous.map { Double($0.sleepNeedMinutes) },
            previousAsleep: previous?.sleepMinutes.map { Double($0) },
            napMinutes: Double(napped))
        let capped = breakdown.isCapped
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Why you needed \(PulseFormat.duration(minutes: Int(breakdown.total.rounded())))")
                .padding(.bottom, DS.Space.s)
            ValueRow(label: "Your baseline", value: minutesText(breakdown.goal, sign: ""))
            Hairline()
            ValueRow(label: "Yesterday's strain", value: minutesText(breakdown.strainExtra, sign: "+"),
                     emphasized: breakdown.strainExtra > 0)
            Hairline()
            ValueRow(label: "Recent sleep debt", value: minutesText(breakdown.debtExtra, sign: "+"),
                     emphasized: breakdown.debtExtra > 0)
            if breakdown.napCredit > 0 {
                Hairline()
                ValueRow(label: "Naps", value: minutesText(breakdown.napCredit, sign: "−"), emphasized: true)
            }
            if capped {
                Text("Capped at 10 hours.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .padding(.top, DS.Space.s)
            }
        }
    }

    /// The naps after a night, up to the next night: they lower the next night's sleep need (DESIGN.md §4b-7).
    private func napsCard(after night: SleepRecord) -> some View {
        let nextNight = sleeps.last { $0.start >= night.end }
        let naps = allSleeps
            .filter { nap in nap.isNap && nap.start >= night.end && (nextNight.map { nap.end <= $0.start } ?? true) }
            .sorted { $0.start < $1.start }
        let total = naps.reduce(0) { $0 + $1.asleepMinutes }
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Naps", trailing: naps.isEmpty ? nil : PulseFormat.duration(minutes: total))
            if naps.isEmpty {
                Text("No naps after this night.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
            }
            ForEach(naps) { nap in
                Button { editing = SleepEditTarget(start: nap.start, end: nap.end) } label: {
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: "moon.zzz")
                            .foregroundStyle(DS.Colors.sleepTint)
                            .accessibilityHidden(true)
                        Text("\(nap.start.formatted(date: .omitted, time: .shortened)) – \(nap.end.formatted(date: .omitted, time: .shortened))")
                            .textStyle(.body)
                            .foregroundStyle(DS.Colors.primary)
                        Spacer(minLength: DS.Space.s)
                        Text(PulseFormat.duration(minutes: nap.asleepMinutes))
                            .textStyle(.bodyStrong)
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.primary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(DS.Colors.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Nap from \(nap.start.formatted(date: .omitted, time: .shortened)), \(PulseFormat.duration(minutes: nap.asleepMinutes)) asleep")
                .accessibilityHint("Edit this nap")
            }
            Text("Naps lower your next night's sleep need. They don't change recovery.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { addingNap = true } label: {
                Label("Add nap", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondaryPill)
        }
        .monoCard()
    }

    // MARK: - Helpers

    /// Half the height of a stage block, in rows.
    private static let blockHalfHeight = 0.22

    /// Awake on the top row, deep on the bottom one.
    private static func row(_ phase: SleepPhase) -> Double {
        Double(SleepPhase.allCases.count - 1 - (SleepPhase.allCases.firstIndex(of: phase) ?? 0))
    }

    private static func phase(atRow row: Double) -> SleepPhase {
        let index = SleepPhase.allCases.count - 1 - Int(row.rounded())
        return SleepPhase.allCases[min(max(index, 0), SleepPhase.allCases.count - 1)]
    }

    /// Where one stage meets the next.
    private struct StageJoin: Identifiable {
        let time: Date
        let from: Double
        let to: Double
        var id: Date { time }
    }

    private static func joins(_ segments: [SleepSegment]) -> [StageJoin] {
        zip(segments, segments.dropFirst())
            .filter { $0.end == $1.start }
            .map { StageJoin(time: $1.start, from: row($0.phase), to: row($1.phase)) }
    }

    /// The start and end of the night keep their labels inside the chart.
    private static func anchor(_ time: Date, ticks: [Date]) -> UnitPoint {
        time == ticks.first ? .topLeading : time == ticks.last ? .topTrailing : .top
    }

    /// The start and the end with minutes ("1:12 AM"), the hours between without ("3 AM").
    private static func tickText(_ time: Date, ticks: [Date]) -> String {
        time == ticks.first || time == ticks.last
            ? time.formatted(date: .omitted, time: .shortened)
            : time.formatted(.dateTime.hour())
    }

    private func minutesText(_ minutes: Double, sign: String) -> String {
        sign + PulseFormat.duration(minutes: Int(minutes.rounded()))
    }

    private var lowestText: String? {
        heartRate.map(\.value).min().map { "Lowest \(Int($0.rounded())) bpm" }
    }

    private func efficiency(_ night: SleepRecord) -> Double { night.value.efficiency }

    private func timelineSummary(_ totals: [SleepPhase: Int]) -> String {
        let parts = SleepPhase.allCases.reversed().map { "\($0.title) \(PulseFormat.duration(minutes: totals[$0] ?? 0))" }
        return "Sleep timeline. " + parts.joined(separator: ", ")
    }
}

#Preview("Light") {
    SleepView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DataLoader())
        .environment(BandManager())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SleepView()
        .modelContainer(PulseStore.previewContainer)
        .environment(DataLoader())
        .environment(BandManager())
        .preferredColorScheme(.dark)
}
