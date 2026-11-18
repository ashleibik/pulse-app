import SwiftUI
import SwiftData
import PulseCore

/// The Sleep page (DESIGN.md §4b), opened from the Sleep ring or the sleep row on Today:
/// sleep performance ring, its four parts (Poor / Sufficient / Optimal), one paragraph, the
/// night's heart rate, the phases, and hours vs needed.
struct SleepDetailView: View {
    /// The day the night ends on.
    let day: Date
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Query(sort: \SleepRecord.end, order: .reverse) private var sleeps: [SleepRecord]
    @Query private var profiles: [ProfileRecord]
    @Environment(\.modelContext) private var context
    @State private var explaining = false
    @State private var heartRate: [ChartPoint] = []
    @State private var segments: [SleepSegment] = []
    @State private var sleepStress: Double?

    private var sleep: SleepRecord? { NightVitals.mainSleep(endingOn: day, in: sleeps) }
    private var summary: DaySummaryRecord? { days.first { Calendar.current.isDate($0.date, inSameDayAs: day) } }
    private var needMinutes: Int { summary?.sleepNeedMinutes ?? profiles.first?.sleepGoalMinutes ?? 480 }

    var body: some View {
        ScrollView {
            if let sleep {
                content(sleep)
                    .padding(.horizontal, DS.Space.side)
                    .padding(.top, DS.Space.l)
                    .padding(.bottom, DS.Space.xxl)
            } else {
                EmptyState(symbol: "moon.zzz", title: "No sleep for this day",
                           text: "Wear your band to sleep. The night shows up here once the band has synced.")
                    .padding(DS.Space.side)
            }
        }
        .monoBackground()
        .navigationTitle(Calendar.current.isDateInToday(day) ? "TODAY" : day.formatted(.dateTime.weekday(.wide).month().day()).uppercased())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { explaining = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("How sleep is measured")
            }
        }
        .sheet(isPresented: $explaining) {
            MetricExplainerView(kind: .sleep, today: summary, history: Array(days.prefix(14)))
                .presentationDetents([.medium, .large])
        }
        .task(id: sleep.map { "\($0.id)-\($0.end.timeIntervalSince1970)" }) { load() }
    }

    private func content(_ sleep: SleepRecord) -> some View {
        let p = NightVitals.performance(of: sleep, needMinutes: needMinutes, sleeps: sleeps, sleepStress: sleepStress)
        return VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(spacing: DS.Space.m) {
                BigScoreRing(fraction: p.score / 100, text: "\(Int(p.score.rounded()))%",
                             caption: "SLEEP\nPERFORMANCE", color: DS.Colors.sleepTint)
                LevelIndicator(level: SleepPerformance.scoreLevel(p.score))
            }
            .riseIn(1)

            VStack(spacing: 0) {
                LevelRow(symbol: "bed.double", title: "Hours vs. needed", value: percent(p.hoursVsNeeded),
                         level: SleepPerformance.hoursLevel(p.hoursVsNeeded))
                Hairline()
                LevelRow(symbol: "clock.arrow.circlepath", title: "Sleep consistency", value: p.consistency.map(percent) ?? "--",
                         level: p.consistency.map(SleepPerformance.consistencyLevel))
                Hairline()
                LevelRow(symbol: "chart.bar", title: "Sleep efficiency", value: p.efficiency.map(percent) ?? "--",
                         level: p.efficiency.map(SleepPerformance.efficiencyLevel))
                Hairline()
                LevelRow(symbol: "waveform.path", title: "High sleep stress", value: p.sleepStress.map(percent) ?? "--",
                         level: p.sleepStress.map(SleepPerformance.stressLevel))
                LevelLegend().padding(.top, DS.Space.s)
            }
            .monoCard(padding: DS.Space.m)
            .riseIn(2)

            Text(paragraph(p))
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
                .fixedSize(horizontal: false, vertical: true)
                .monoCard(padding: DS.Space.m)
                .riseIn(3)

            nightCard(sleep).riseIn(4)
            needCard(sleep, p).riseIn(5)
        }
    }

    /// Heart rate through the night, then the phases with their share and duration.
    private func nightCard(_ sleep: SleepRecord) -> some View {
        let totals = SleepTimeline.totals(segments)
        let total = max(1, totals.values.reduce(0, +))
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            if heartRate.count > 1 {
                LineChart(points: heartRate, xValues: .automatic(desiredCount: 3),
                          xFormat: .dateTime.hour().minute(), height: 150,
                          valueLabel: { "\(Int($0.value.rounded())) bpm · \($0.date.formatted(date: .omitted, time: .shortened))" },
                          summary: "Heart rate during the night, from \(sleep.start.formatted(date: .omitted, time: .shortened)) to \(sleep.end.formatted(date: .omitted, time: .shortened)).")
                Hairline()
            }
            HStack {
                Text("PHASES").textStyle(.label).foregroundStyle(DS.Colors.primary)
                Spacer()
                Text("DURATION \(PulseFormat.clock(minutes: sleep.asleepMinutes + sleep.awakeMinutes))")
                    .textStyle(.label)
                    .foregroundStyle(DS.Colors.secondary)
            }
            ForEach(SleepPhase.allCases, id: \.self) { phase in
                let minutes = totals[phase] ?? 0
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack {
                        Text(phase.title.uppercased()).textStyle(.label).foregroundStyle(DS.Colors.primary)
                        Text("\(Int((100 * Double(minutes) / Double(total)).rounded()))%")
                            .textStyle(.caption).foregroundStyle(color(phase))
                        Spacer()
                        Text(PulseFormat.clock(minutes: minutes)).textStyle(.bodyStrong).foregroundStyle(DS.Colors.primary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.Colors.muted)
                            Capsule().fill(color(phase))
                                .frame(width: max(4, geo.size.width * Double(minutes) / Double(total)))
                        }
                    }
                    .frame(height: 10)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Image(systemName: "sparkles").foregroundStyle(DS.Colors.sleepTint)
                Text("RESTFUL SLEEP").textStyle(.label).foregroundStyle(DS.Colors.primary)
                Spacer()
                Text(PulseFormat.clock(minutes: totals[.restful] ?? 0)).textStyle(.heading).foregroundStyle(DS.Colors.primary)
            }
            .padding(.top, DS.Space.s)
            Text("Phases are estimated from heart rate and movement. A wrist band can't tell REM from deep sleep reliably, so Pulse shows how calm the night was instead.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .monoCard(padding: DS.Space.m)
    }

    private func needCard(_ sleep: SleepRecord, _ p: SleepPerformance) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("HOURS VS. NEEDED").textStyle(.label).foregroundStyle(DS.Colors.primary)
            Text(percent(p.hoursVsNeeded)).textStyle(.display).foregroundStyle(DS.Colors.primary)
            HStack {
                StatBlock(label: "Hours of sleep", number: Double(sleep.asleepMinutes),
                          format: { PulseFormat.duration(minutes: Int($0)) }, valueStyle: .heading)
                StatBlock(label: "Sleep needed", number: Double(needMinutes),
                          format: { PulseFormat.duration(minutes: Int($0)) }, valueStyle: .heading)
            }
        }
        .monoCard(padding: DS.Space.m)
    }

    private func paragraph(_ p: SleepPerformance) -> String {
        let level = SleepPerformance.scoreLevel(p.score)
        var parts: [String] = []
        switch level {
        case .optimal: parts.append("Your sleep performance is optimal.")
        case .sufficient: parts.append("Your sleep performance is sufficient.")
        case .poor: parts.append("Your sleep performance is low.")
        }
        parts.append(p.hoursVsNeeded >= 85 ? "You slept close to what you needed" : "You slept less than you needed")
        if let consistency = p.consistency {
            parts[parts.count - 1] += consistency >= 80 ? ", at your usual times." : ", at less regular times than usual."
        } else {
            parts[parts.count - 1] += ". Consistency needs 3 nights."
        }
        if let efficiency = p.efficiency, efficiency < 85 { parts.append("You were awake for a fair part of the night.") }
        return parts.joined(separator: " ")
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    private func color(_ phase: SleepPhase) -> Color {
        switch phase {
        case .awake: DS.Colors.secondary
        case .light: DS.Colors.sleepTint.opacity(0.55)
        case .restful: DS.Colors.sleepTint
        }
    }

    private func load() {
        guard let sleep else { return }
        let minutes = PulseStore.minutes(from: sleep.start, to: sleep.end, in: context)
        segments = SleepTimeline.build(minutes: minutes, from: sleep.start, to: sleep.end)
        heartRate = minutes.compactMap { m in m.averageHeartRate.map { ChartPoint(date: m.start, value: $0) } }
        let profile = profiles.first?.metricsProfile ?? MetricsProfile()
        sleepStress = SleepPerformance.sleepStress(minutes: minutes, restingHR: summary?.restingHeartRate ?? 60,
                                                   maxHR: profile.maxHeartRate)
    }
}
