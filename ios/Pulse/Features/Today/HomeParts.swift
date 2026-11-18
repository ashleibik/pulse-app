import SwiftUI
import SwiftData
import PulseCore

// Building blocks of the home screen and the Sleep / Recovery pages (DESIGN.md §4b).

// MARK: - Rings

/// One of Today's three rings: a thin track, a coloured arc, the value inside, the name below.
struct ScoreRing: View {
    /// 0...1. nil = no data yet (empty track, "--").
    let fraction: Double?
    let text: String
    let label: String
    let color: Color
    var diameter: CGFloat = 96
    var lineWidth: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = 0.0

    var body: some View {
        VStack(spacing: DS.Space.s) {
            ZStack {
                Circle().stroke(DS.Colors.border, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: drawn)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(text)
                    .textStyle(.title)
                    .foregroundStyle(DS.Colors.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, lineWidth + 6)
            }
            .frame(width: diameter, height: diameter)
            HStack(spacing: 3) {
                Text(label)
                Image(systemName: "chevron.right").imageScale(.small)
            }
            .textStyle(.label)
            .foregroundStyle(DS.Colors.secondary)
        }
        .onAppear(perform: draw)
        .onChange(of: fraction) { _, _ in draw() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized): \(text == "--" ? "no data yet" : text)")
        .accessibilityAddTraits(.isButton)
    }

    private func draw() {
        let target = min(1, max(0, fraction ?? 0))
        if reduceMotion { drawn = target } else { withAnimation(DS.Motion.draw) { drawn = target } }
    }
}

/// The big ring at the top of the Sleep and Recovery pages.
struct BigScoreRing: View {
    let fraction: Double?
    let text: String
    let caption: String
    let color: Color
    var diameter: CGFloat = 248
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(DS.Colors.border, lineWidth: 14)
            Circle()
                .trim(from: 0, to: drawn)
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .glow(color)
            VStack(spacing: DS.Space.xs) {
                Text(text)
                    .font(.system(size: 72, weight: .bold, width: .condensed))
                    .foregroundStyle(DS.Colors.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(caption)
                    .textStyle(.label)
                    .foregroundStyle(DS.Colors.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(DS.Space.xl)
        }
        .frame(width: diameter, height: diameter)
        .frame(maxWidth: .infinity)
        .onAppear {
            let target = min(1, max(0, fraction ?? 0))
            if reduceMotion { drawn = target } else { withAnimation(DS.Motion.draw) { drawn = target } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption.capitalized): \(text == "--" ? "not available yet" : text)")
    }
}

// MARK: - Poor / Sufficient / Optimal

extension SleepPerformance.Level {
    var title: String {
        switch self {
        case .poor: "Poor"
        case .sufficient: "Sufficient"
        case .optimal: "Optimal"
        }
    }

    var color: Color {
        switch self {
        case .poor: DS.Colors.warn
        case .sufficient: DS.Colors.secondary
        case .optimal: DS.Colors.accent
        }
    }
}

/// Three short segments; the one for this level is lit. The level is also read out in words.
struct LevelIndicator: View {
    let level: SleepPerformance.Level?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(SleepPerformance.Level.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == level ? step.color : DS.Colors.muted)
                    .frame(width: 14, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level?.title ?? "Unknown")
    }
}

/// "● Poor  ● Sufficient  ● Optimal" under a card of level rows.
struct LevelLegend: View {
    var body: some View {
        HStack(spacing: DS.Space.m) {
            ForEach(SleepPerformance.Level.allCases, id: \.self) { level in
                HStack(spacing: 6) {
                    Capsule().fill(level.color).frame(width: 12, height: 4)
                    Text(level.title)
                }
            }
        }
        .textStyle(.caption)
        .foregroundStyle(DS.Colors.secondary)
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.background))
        .accessibilityHidden(true)
    }
}

/// A row of the Sleep page: icon, name, three-step indicator, value.
struct LevelRow: View {
    let symbol: String
    let title: String
    let value: String
    let level: SleepPerformance.Level?

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(DS.Colors.secondary)
            Text(title.uppercased())
                .textStyle(.label)
                .foregroundStyle(DS.Colors.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: DS.Space.s)
            LevelIndicator(level: level)
            Text(value)
                .textStyle(.heading)
                .foregroundStyle(DS.Colors.primary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Today vs your 30-day average

/// A row of the Recovery page: icon, name, today's value, your average below it, and ▲ / ▼.
struct CompareRow: View {
    let symbol: String
    let title: String
    let value: Double?
    let average: Double?
    let format: (Double) -> String
    /// true = higher is better, false = lower is better, nil = neither (only how far from normal).
    let higherIsBetter: Bool?

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(DS.Colors.secondary)
            Text(title.uppercased())
                .textStyle(.label)
                .foregroundStyle(DS.Colors.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: DS.Space.s)
            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 4) {
                    Text(value.map(format) ?? "--")
                        .textStyle(.heading)
                        .foregroundStyle(DS.Colors.primary)
                    if let arrow { Text(arrow.symbol).textStyle(.caption).foregroundStyle(arrow.color) }
                }
                if let average {
                    Text(format(average))
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                }
            }
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var arrow: (symbol: String, color: Color)? {
        guard let value, let average, abs(value - average) >= 0.05 * max(abs(average), 1) else { return nil }
        let up = value > average
        let color: Color
        if let higherIsBetter { color = up == higherIsBetter ? DS.Colors.accent : DS.Colors.warn } else { color = DS.Colors.secondary }
        return (up ? "▲" : "▼", color)
    }

    private var accessibilityText: String {
        var text = "\(title): \(value.map(format) ?? "no data")"
        if let average { text += ", your 30-day average \(format(average))" }
        return text
    }
}

// MARK: - Monitor cards

/// "HEALTH MONITOR >" with a status line: a small badge, a coloured state word, one detail line.
struct MonitorCard: View {
    let title: String
    let badge: String
    let badgeIsSymbol: Bool
    let state: String
    let stateColor: Color
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text(title).textStyle(.label).foregroundStyle(DS.Colors.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(DS.Colors.tertiary)
            }
            HStack(spacing: DS.Space.s) {
                Group {
                    if badgeIsSymbol { Image(systemName: badge) } else { Text(badge) }
                }
                .textStyle(.bodyStrong)
                .foregroundStyle(stateColor)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.background))
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.uppercased())
                        .textStyle(.label)
                        .foregroundStyle(stateColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(detail)
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Colors.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Day switcher

/// "‹  TODAY  ›": steps through the days that have data.
struct DayPager: View {
    @Binding var day: Date
    /// The first day with data (can't go further back).
    let earliest: Date
    private var calendar: Calendar { .current }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            step(-1, symbol: "chevron.left", label: "Previous day")
                .disabled(day <= calendar.startOfDay(for: earliest))
            Text(title)
                .textStyle(.label)
                .foregroundStyle(DS.Colors.primary)
                .lineLimit(1)
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: 32)
                .background(Capsule().fill(DS.Colors.surface))
                .accessibilityAddTraits(.isHeader)
            step(1, symbol: "chevron.right", label: "Next day")
                .disabled(calendar.isDateInToday(day))
        }
    }

    private var title: String {
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
    }

    private func step(_ by: Int, symbol: String, label: String) -> some View {
        Button {
            withAnimation(DS.Motion.spring) {
                day = calendar.date(byAdding: .day, value: by, to: day).map { calendar.startOfDay(for: $0) } ?? day
            }
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 44)
        }
        .foregroundStyle(DS.Colors.primary)
        .accessibilityLabel(label)
    }
}

// MARK: - Night numbers shared by Today and the two pages

@MainActor
enum NightVitals {
    /// Respiratory rate per sleep (from its raw minutes), cached: it needs the beat-to-beat data.
    private static var respiratoryCache: [String: Double?] = [:]

    static func respiratoryRate(_ sleep: SleepRecord, context: ModelContext) -> Double? {
        let key = "\(sleep.id)-\(sleep.end.timeIntervalSince1970)"
        if let cached = respiratoryCache[key] { return cached }
        let value = RespiratoryRate.night(minutes: PulseStore.minutes(from: sleep.start, to: sleep.end, in: context))
        respiratoryCache[key] = value
        return value
    }

    /// The main (longest non-nap) sleep that ends on `day`.
    static func mainSleep(endingOn day: Date, in sleeps: [SleepRecord], calendar: Calendar = .current) -> SleepRecord? {
        sleeps.filter { !$0.isNap && calendar.isDate($0.end, inSameDayAs: day) }
            .max { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) }
    }

    /// Sleep performance of one night (consistency from the nights up to it).
    static func performance(of sleep: SleepRecord, needMinutes: Int, sleeps: [SleepRecord],
                            sleepStress: Double? = nil) -> SleepPerformance {
        let upToThen = sleeps.filter { $0.end <= sleep.end }.map(\.value)
        return .make(asleepMinutes: sleep.asleepMinutes, awakeMinutes: sleep.awakeMinutes, needMinutes: needMinutes,
                     consistency: SleepConsistency.score(upToThen, calendar: .current), sleepStress: sleepStress)
    }

    /// Sleep performance for the summary of a day (nil without a main sleep).
    static func performance(for day: DaySummaryRecord, sleeps: [SleepRecord]) -> SleepPerformance? {
        guard let sleep = mainSleep(endingOn: day.date, in: sleeps) else { return nil }
        return performance(of: sleep, needMinutes: day.sleepNeedMinutes, sleeps: sleeps)
    }

    /// The previous 30 days (not the day itself), newest first.
    static func previous30(_ days: [DaySummaryRecord], before day: Date) -> [DaySummaryRecord] {
        let from = Calendar.current.date(byAdding: .day, value: -30, to: day) ?? day
        return days.filter { $0.date < day && $0.date >= from }
    }
}
