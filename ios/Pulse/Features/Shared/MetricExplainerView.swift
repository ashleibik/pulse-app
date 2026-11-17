import SwiftUI
import PulseCore

/// Every number in the app can be tapped. This sheet explains it in plain language.
enum MetricKind: String, Identifiable, CaseIterable {
    case recovery, strain, sleep, hrv, restingHeartRate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recovery: "Recovery"
        case .strain: "Strain"
        case .sleep: "Sleep"
        case .hrv: "Heart rate variability"
        case .restingHeartRate: "Resting heart rate"
        }
    }

    /// For chart headings, where the long name would not fit next to the average.
    var shortTitle: String {
        switch self {
        case .recovery: "Recovery"
        case .strain: "Strain"
        case .sleep: "Sleep"
        case .hrv: "HRV"
        case .restingHeartRate: "Resting HR"
        }
    }

    /// "What it means": short, no jargon.
    var meaning: String {
        switch self {
        case .recovery:
            "How ready your body is to take on effort today, from 0 to 100%. It compares last night's HRV and resting heart rate with your own normal levels, and checks whether you slept enough."
        case .strain:
            "How hard your heart worked today, on a scale from 0 to 21. Time at higher heart rates counts much more than easy movement. It gets harder to push the number up the higher it goes."
        case .sleep:
            "How long you were actually asleep (not just in bed), compared with how much sleep your body needed after yesterday's effort."
        case .hrv:
            "The tiny variation in time between heartbeats, measured while you sleep. Higher than YOUR normal usually means your body is rested. Lower can mean stress, illness, alcohol or hard training."
        case .restingHeartRate:
            "Your lowest steady heart rate during sleep. A few beats above your normal can be an early sign of fatigue, stress or getting sick."
        }
    }

    /// "How we calculate it": honest and high level. Full formulas + sources: docs/METRICS.md.
    var method: String {
        switch self {
        case .recovery:
            "Last night's HRV and resting heart rate are compared with your own average over the previous 14 nights, and your sleep with what you needed. Being at your normal scores 50%. Pulse needs 4 nights before it shows a score."
        case .strain:
            "Every minute your heart rate is well above resting adds training load (Banister's TRIMP, a sports-science method). Harder minutes count exponentially more. The total is scaled to 0 to 21."
        case .sleep:
            "Sleep is detected from stillness (the Cole–Kripke method) combined with a low heart rate. Wake-ups during the night are subtracted. Your need grows after hard days and short nights."
        case .hrv:
            "RMSSD: how much the time between consecutive heartbeats varies. Measured in 5-minute stretches of sleep after removing missed or extra beats, then the night's median is used."
        case .restingHeartRate:
            "Your lowest average heart rate over any 10 calm minutes of sleep."
        }
    }

    func value(of day: DaySummaryRecord) -> Double? {
        switch self {
        case .recovery: day.recoveryScore
        case .strain: Optional(day.strain)
        case .sleep: day.sleepMinutes.map { Double($0) / 60 }
        case .hrv: day.hrvRMSSD
        case .restingHeartRate: day.restingHeartRate
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .recovery: PulseFormat.percent(value)
        case .strain: PulseFormat.strain(value)
        case .sleep: PulseFormat.duration(minutes: Int((value * 60).rounded()))
        case .hrv: "\(Int(value.rounded())) ms"
        case .restingHeartRate: "\(Int(value.rounded())) bpm"
        }
    }
}

/// The sheet behind every tappable number: what it means, the last 14 days, how it's calculated.
/// Mono design (ios/design/DESIGN.md).
struct MetricExplainerView: View {
    let kind: MetricKind
    let today: DaySummaryRecord?
    let history: [DaySummaryRecord]   // newest first
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                if let today, let value = kind.value(of: today) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Today")
                            .textStyle(.caption)
                            .foregroundStyle(DS.Colors.secondary)
                        HeroNumber(value: value) { kind.format($0) }
                    }
                    .accessibilityElement(children: .combine)
                }
                block("What it means", kind.meaning)
                if kind == .recovery, let today {
                    block("Why it's this today", today.explanation)
                }
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        SectionTitle(title: "Last 14 days")
                        DayBarsChart(bars: DayBarsChart.Bar.from(Array(history.reversed())) { kind.value(of: $0) },
                                     domain: chartDomain,
                                     height: 120,
                                     summary: "\(kind.title) over the last 14 days")
                    }
                }
                block("How we calculate it", kind.method)
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("Pulse is for general wellness, not medical advice.")
                }
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: kind.title, isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
    }

    /// Recovery and strain have a fixed scale. The others start at 0 and end at the biggest value.
    private var chartDomain: ClosedRange<Double>? {
        switch kind {
        case .recovery: return 0...100
        case .strain: return 0...Strain.maximum
        case .sleep, .hrv, .restingHeartRate: return nil
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionTitle(title: title)
            Text(text)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
