import SwiftUI
import SwiftData
import Charts
import PulseCore

/// "Why is my recovery what it is?": the factors, today's strain target, and the last 14 days.
struct RecoveryDetailView: View {
    let day: DaySummaryRecord
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]

    private var breakdown: RecoveryBreakdown? {
        RecoveryExplainer.breakdown(for: day.value, history: days.map(\.value))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                VStack(spacing: 12) {
                    RecoveryRing(score: day.recoveryScore, size: 170, lineWidth: 14)
                    if let zone = day.zone {
                        Text(zone.headline)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.color(for: zone))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                factorsCard
                targetCard
                historyCard

                VStack(alignment: .leading, spacing: 6) {
                    Text("How it's calculated").font(.headline)
                    Text(MetricKind.recovery.method)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .card()

                Text("Pulse is for general wellness, not medical advice.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var factorsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "What moved your score")
            if let breakdown {
                ForEach(breakdown.factors) { factor in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(factor.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(pointsText(factor.points))
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(factor.points >= 0 ? Theme.recoveryGreen : Theme.recoveryRed)
                        }
                        ContributionBar(points: factor.points)
                        Text(factor.detail)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Points compared with a night exactly at your normal (which scores 50%).")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Label {
                    Text(day.explanation)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hourglass")
                }
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            }
        }
        .card()
    }

    private var targetCard: some View {
        let target = StrainGuidance.targetRange(recovery: day.recoveryScore)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Today's strain target", trailing: "\(Int(target.lowerBound))–\(Int(target.upperBound))")
            StrainTargetBar(strain: day.strain, target: target)
            Text(StrainGuidance.advice(strain: day.strain, recovery: day.recoveryScore))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .card()
    }

    private var historyCard: some View {
        let recent = days.prefix(14).reversed().filter { $0.recoveryScore != nil }
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Last 14 days")
            Chart {
                ForEach(recent) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Recovery", d.recoveryScore ?? 0))
                        .foregroundStyle(Theme.color(for: d.zone))
                        .cornerRadius(3)
                        .opacity(Calendar.current.isDate(d.date, inSameDayAs: day.date) ? 1 : 0.6)
                }
                RuleMark(y: .value("Your normal", 50))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.white.opacity(0.4))
                    .annotation(position: .top, alignment: .leading) {
                        Text("your normal").font(.caption2).foregroundStyle(Theme.secondaryText)
                    }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 160)
            .accessibilityLabel("Recovery over the last 14 days. Bars above the dashed line are better than your normal.")
        }
        .card()
    }

    private func pointsText(_ points: Double) -> String {
        let rounded = Int(points.rounded())
        if rounded == 0 { return "±0" }
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }
}
