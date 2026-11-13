import SwiftUI
import Charts
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

    var color: Color {
        switch self {
        case .recovery: Theme.recoveryGreen
        case .strain: Theme.strain
        case .sleep: Theme.sleep
        case .hrv: Theme.recoveryGreen
        case .restingHeartRate: Theme.heart
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

/// One point on a per-day chart.
struct DayValue: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

struct MetricExplainerView: View {
    let kind: MetricKind
    let today: DaySummaryRecord?
    let history: [DaySummaryRecord]   // newest first
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let today, let value = kind.value(of: today) {
                        Text(kind.format(value))
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(kind.color)
                            .monospacedDigit()
                    }
                    block("What it means", kind.meaning)
                    if kind == .recovery, let today {
                        block("Why it's this today", today.explanation)
                    }
                    if !chartPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Last 14 days").font(.headline)
                            Chart(chartPoints) { point in
                                BarMark(x: .value("Day", point.date, unit: .day), y: .value(kind.title, point.value))
                                    .foregroundStyle(kind.color.gradient)
                                    .cornerRadius(3)
                            }
                            .frame(height: 140)
                            .accessibilityLabel("Chart of \(kind.title) over the last 14 days")
                        }
                    }
                    block("How we calculate it", kind.method)
                    if today?.isSimulated == true {
                        Text("Until your band is paired, the heartbeats are simulated, but every number here is calculated by the real engine.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Text("Pulse is for general wellness, not medical advice.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding()
            }
            .screenBackground()
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var chartPoints: [DayValue] {
        history.reversed().compactMap { day in kind.value(of: day).map { DayValue(date: day.date, value: $0) } }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
}
