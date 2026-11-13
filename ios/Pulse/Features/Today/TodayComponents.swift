import SwiftUI
import Charts
import PulseCore

// Building blocks of the Today screen in the Mono design (ios/design/DESIGN.md).
// When the other screens are rebuilt, the shared ones move to Features/Shared.

// MARK: - Recovery dial

/// The hero: a thin ring that fills to the recovery score, with the number inside.
/// No color coding. The fill amount and the word under it ("Ready", "Steady", "Rest") carry the meaning.
struct RecoveryDial: View {
    let score: Double?
    var diameter: CGFloat = 232
    var lineWidth: CGFloat = 12

    /// What is drawn right now (0...100). Animates from 0 to `score` on appear.
    @State private var shown: Double = 0
    /// 76 pt at the default text size, grows with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 76
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Capped so the number always fits inside the ring.
    private var hero: CGFloat { min(heroSize, 92) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.Colors.border, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown / 100)
                .stroke(DS.Colors.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))      // start at 12 o'clock

            VStack(spacing: 0) {
                if score != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        CountingText(value: shown) { "\(Int($0.rounded()))" }
                            .font(.system(size: hero, weight: .bold))
                            .tracking(-3)
                        Text("%")
                            .font(.system(size: hero * 0.4, weight: .bold))
                            .foregroundStyle(DS.Colors.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                } else {
                    Text("--")
                        .font(.system(size: hero, weight: .bold))
                        .foregroundStyle(DS.Colors.tertiary)
                }
                Text("Recovery")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
            .foregroundStyle(DS.Colors.primary)
            .padding(.horizontal, lineWidth + DS.Space.m)
        }
        .frame(width: diameter, height: diameter)
        .onAppear { animate(to: score) }
        .onChange(of: score) { _, newValue in animate(to: newValue) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery")
        .accessibilityValue(accessibilityText)
    }

    private func animate(to value: Double?) {
        let target = value ?? 0
        if reduceMotion {
            shown = target
        } else {
            withAnimation(DS.Motion.draw) { shown = target }
        }
    }

    private var accessibilityText: String {
        guard let score else { return "Not enough data yet" }
        return "\(Int(score.rounded())) percent. \(RecoveryZone(score: score).word)."
    }
}

// MARK: - Strain meter

/// 0-21 bar. Light track, darker gray band = today's target range, black fill = strain so far.
struct StrainMeter: View {
    let strain: Double
    let target: ClosedRange<Double>

    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Colors.border)
                Capsule()
                    .fill(DS.Colors.tertiary)
                    .frame(width: width * (target.upperBound - target.lowerBound) / Strain.maximum)
                    .offset(x: width * target.lowerBound / Strain.maximum)
                Capsule()
                    .fill(DS.Colors.primary)
                    .frame(width: max(8, width * min(shown, Strain.maximum) / Strain.maximum))
            }
        }
        .frame(height: 8)
        .onAppear { animate(to: strain) }
        .onChange(of: strain) { _, newValue in animate(to: newValue) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Strain \(PulseFormat.strain(strain)) of 21. Target \(Int(target.lowerBound)) to \(Int(target.upperBound)).")
    }

    private func animate(to value: Double) {
        if reduceMotion {
            shown = value
        } else {
            withAnimation(DS.Motion.draw) { shown = value }
        }
    }
}

// MARK: - Stat

/// A number with a label above and one short line below. No box: spacing and type size separate it.
/// The number counts up when it appears.
struct StatBlock: View {
    let symbol: String
    let label: String
    /// `nil` = no data yet, shown as "--".
    let number: Double?
    /// Turns the (counting) number into text, e.g. 326 -> "5h 26m".
    let format: (Double) -> String
    var unit: String? = nil
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
                Text(label)
            }
            .textStyle(.caption)
            .foregroundStyle(DS.Colors.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Group {
                    if let number {
                        CountUpText(value: number, format: format)
                    } else {
                        Text("--")
                    }
                }
                .textStyle(.title)
                .foregroundStyle(DS.Colors.primary)
                if let unit {
                    Text(unit)
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            Text(caption)
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(number.map(format) ?? "no data") \(unit ?? ""), \(caption)")
    }
}

// MARK: - Status pill

/// Says where the numbers come from, in words. Outline only, so it stays quiet.
struct StatusPill: View {
    @Environment(DemoDataLoader.self) private var loader

    var body: some View {
        HStack(spacing: 6) {
            if loader.isBusy {
                ProgressView().controlSize(.mini)
            }
            Text(text)
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .overlay(Capsule().stroke(DS.Colors.border, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch loader.state {
        case .idle, .generating: "Preparing…"
        case .recalculating: "Recalculating…"
        case .ready: "Demo data"
        case .failed: "Data error"
        }
    }
}

// MARK: - Week chart

/// Recovery for the last 7 days. Past days light gray, today black, no gridlines.
struct WeekRecoveryChart: View {
    struct Day: Identifiable {
        let id: String          // unique per day (the weekday letter alone repeats: T, T, S, S)
        let letter: String      // "M", "T", ...
        let score: Double?
        let isToday: Bool
    }

    /// Oldest first.
    let days: [Day]

    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Chart(days) { day in
            BarMark(x: .value("Day", day.id),
                    // A day without a score still gets a small stub, so the week has no hole.
                    y: .value("Recovery", grown ? max(day.score ?? 0, 3) : 0),
                    width: .ratio(0.5))
                .clipShape(Capsule())
                .foregroundStyle(day.isToday ? DS.Colors.primary : DS.Colors.muted)
        }
        .chartYScale(domain: 0...100)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let id = value.as(String.self) {
                        Text(letter(for: id))
                            .textStyle(.caption)
                            .foregroundStyle(DS.Colors.secondary)
                    }
                }
            }
        }
        .frame(height: 132)
        .onAppear {
            if reduceMotion {
                grown = true
            } else {
                withAnimation(DS.Motion.draw.delay(0.15)) { grown = true }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery, last \(days.count) days")
        .accessibilityValue(summary)
    }

    private func letter(for id: String) -> String {
        days.first { $0.id == id }?.letter ?? ""
    }

    /// The chart in words, for VoiceOver.
    private var summary: String {
        let scores = days.compactMap(\.score)
        guard !scores.isEmpty else { return "No scores yet" }
        let average = Int((scores.reduce(0, +) / Double(scores.count)).rounded())
        let today = days.last?.score.map { "Today \(Int($0.rounded())) percent." } ?? ""
        return "Average \(average) percent. \(today)"
    }
}

// MARK: - Activity row

/// One workout, one line: icon, name + details, strain.
struct ActivityRow: View {
    let workout: WorkoutRecord

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: outlineSymbol)
                .font(.title3)
                .foregroundStyle(DS.Colors.primary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.kind.displayName)
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.primary)
                Text("\(workout.start.formatted(date: .omitted, time: .shortened)) · \(PulseFormat.duration(minutes: workout.durationMinutes))")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
            Spacer(minLength: DS.Space.s)
            Text(PulseFormat.strain(workout.strain))
                .textStyle(.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(DS.Colors.primary)
        }
        .padding(.vertical, DS.Space.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(workout.kind.displayName), \(PulseFormat.duration(minutes: workout.durationMinutes)), strain \(PulseFormat.strain(workout.strain))")
    }

    /// Design rule: outline icons. PulseCore's names end in ".fill" for a few sports.
    private var outlineSymbol: String {
        workout.kind.symbolName.replacingOccurrences(of: ".fill", with: "")
    }
}
