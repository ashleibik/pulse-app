import SwiftUI
import SwiftData
import PulseCore

/// "Why is my recovery what it is?": the factors, today's strain target, and the last 14 days.
/// Mono design (ios/design/DESIGN.md): helped / hurt is shown by the direction of a bar and a
/// signed number, never by green / red.
struct RecoveryDetailView: View {
    /// The day it was opened with.
    let day: DaySummaryRecord
    /// A different day picked in the 14-day chart.
    @State private var selected: DaySummaryRecord?
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]

    /// The day on screen.
    private var shown: DaySummaryRecord { selected ?? day }
    private var isToday: Bool { Calendar.current.isDateInToday(shown.date) }

    private var breakdown: RecoveryBreakdown? {
        RecoveryExplainer.breakdown(for: shown.value, history: days.map(\.value))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                hero.riseIn(0)
                factors.riseIn(1)
                target.riseIn(2)
                history.riseIn(3)
                method.riseIn(4)
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.xxl)
        }
        // Only the screenshot job sets this (to capture the lower half of the screen).
        .defaultScrollAnchor(LaunchOptions.scroll == "bottom" ? UnitPoint.bottom : nil)
        .monoBackground()
        .navigationTitle(isToday ? "Recovery" : shown.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
        .sensoryFeedback(.selection, trigger: shown.date)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: DS.Space.l) {
            RecoveryDial(score: shown.recoveryScore, diameter: 184, lineWidth: 10)
            VStack(spacing: DS.Space.xs) {
                Text(shown.zone?.word ?? "Learning")
                    .textStyle(.display)
                    .foregroundStyle(DS.Colors.primary)
                    .accessibilityHidden(true)      // the ring already reads this word
                Text(RecoveryExplainer.oneLine(breakdown))
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var factors: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "What moved it")
                .padding(.bottom, DS.Space.s)
            if let breakdown {
                ForEach(Array(breakdown.factors.enumerated()), id: \.element.id) { index, factor in
                    if index > 0 { Hairline() }
                    factorRow(factor)
                }
                Text("Points compared with a night exactly at your normal, which scores 50%.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Space.s)
            } else {
                // No baseline yet: the stored explanation says how many nights are still needed.
                Text(shown.explanation)
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func factorRow(_ factor: RecoveryFactor) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(factor.title)
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.primary)
                Spacer(minLength: DS.Space.s)
                Text(pointsText(factor.points))
                    .textStyle(.bodyStrong)
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.primary)
            }
            ContributionBar(points: factor.points)
            Text(factor.detail)
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
        }
        .padding(.vertical, DS.Space.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(factor.title)
        .accessibilityValue("\(factor.detail). \(pointsText(factor.points)) points.")
    }

    private var target: some View {
        let range = StrainGuidance.targetRange(recovery: shown.recoveryScore)
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: isToday ? "Strain target" : "Strain that day",
                         trailing: "\(Int(range.lowerBound))–\(Int(range.upperBound)) of 21")
            StrainMeter(strain: shown.strain, target: range)
            Text(isToday ? StrainGuidance.advice(strain: shown.strain, recovery: shown.recoveryScore)
                 : "Strain was \(PulseFormat.strain(shown.strain)). The target that day was \(Int(range.lowerBound))–\(Int(range.upperBound)).")
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The one card on this screen.
    private var history: some View {
        let recent = Array(days.prefix(14).reversed())      // oldest first
        let scores = recent.compactMap(\.recoveryScore)
        let average: Double? = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        let bars = DayBarsChart.Bar.from(recent, highlight: shown.date) { $0.recoveryScore }
        let summary = "Recovery over the last \(recent.count) days. "
            + (average.map { "Average \(PulseFormat.percent($0))." } ?? "No scores yet.")
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionTitle(title: "Last 14 days",
                         trailing: average.map { "Avg \(PulseFormat.percent($0))" })
            DayBarsChart(bars: bars, domain: 0...100, height: 120, summary: summary) { id in
                selected = recent.first { DayBarsChart.Bar.id(for: $0.date) == id }
            }
        }
        .monoCard()
    }

    private var method: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionTitle(title: "How it's calculated")
            Text(MetricKind.recovery.method)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pulse is for general wellness, not medical advice.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .padding(.top, DS.Space.s)
        }
    }

    /// "+3", "-18" or "±0". A real minus sign (−) lines up better than a hyphen.
    private func pointsText(_ points: Double) -> String {
        let rounded = Int(points.rounded())
        if rounded == 0 { return "±0" }
        return rounded > 0 ? "+\(rounded)" : "−\(-rounded)"
    }
}
