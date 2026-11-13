import SwiftUI
import PulseCore

// Reusable building blocks shared by several screens.

// MARK: - Recovery ring

/// The big ring on the Home screen. Animates in (unless Reduce Motion is on), colored by zone,
/// grows with Dynamic Type, and VoiceOver reads it as one element.
struct RecoveryRing: View {
    let score: Double?
    var size: CGFloat = 200
    var lineWidth: CGFloat = 16

    @State private var progress: Double = 0
    @ScaledMetric(relativeTo: .largeTitle) private var textScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var zone: RecoveryZone? { score.map(RecoveryZone.init(score:)) }
    private var scaledSize: CGFloat { size * min(max(textScale, 1), 1.3) }

    var body: some View {
        let color = Theme.color(for: zone)
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 10)
            VStack(spacing: 2) {
                Text(score.map(PulseFormat.percent) ?? "--")
                    .font(.system(size: scaledSize * 0.26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5)
                Text("RECOVERY")
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(lineWidth)
        }
        .frame(width: scaledSize, height: scaledSize)
        .onAppear { animate(to: score) }
        .onChange(of: score) { _, newValue in animate(to: newValue) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery")
        .accessibilityValue(accessibilityText)
    }

    private func animate(to value: Double?) {
        let target = (value ?? 0) / 100
        if reduceMotion {
            progress = target
        } else {
            withAnimation(.spring(response: 1.0, dampingFraction: 0.85)) { progress = target }
        }
    }

    private var accessibilityText: String {
        guard let score, let zone else { return "Not enough data yet" }
        return "\(Int(score.rounded())) percent. \(zone.headline)."
    }
}

// MARK: - Metric tile

/// Small card with an icon, a title, a big number and an optional caption.
struct MetricTile: View {
    let title: String
    let value: String
    var unit: String? = nil
    var caption: String? = nil
    let color: Color
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Data source chip

/// Top-left status pill. Until Phase 5 it says "Demo data", so fake numbers are never mistaken
/// for real ones.
struct SyncStatusChip: View {
    @Environment(DemoDataLoader.self) private var loader

    var body: some View {
        HStack(spacing: 6) {
            if loader.isBusy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(dotColor).frame(width: 8, height: 8)
            }
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.08), in: Capsule())
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

    private var dotColor: Color {
        switch loader.state {
        case .ready: Theme.recoveryYellow
        case .failed: Theme.recoveryRed
        default: Theme.secondaryText
        }
    }
}

// MARK: - Workout row

struct WorkoutRow: View {
    let workout: WorkoutRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.kind.symbolName)
                .font(.title3)
                .foregroundStyle(Theme.strain)
                .frame(width: 40, height: 40)
                .background(Theme.strain.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.kind.displayName).font(.headline)
                Text("\(workout.start.formatted(date: .omitted, time: .shortened)) · \(PulseFormat.duration(minutes: workout.durationMinutes)) · avg \(workout.averageHeartRate) bpm")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(PulseFormat.strain(workout.strain))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                Text("strain").font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Strain target bar

/// 0-21 bar with today's strain filled in and the recommended range shaded.
struct StrainTargetBar: View {
    let strain: Double
    let target: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule()
                    .fill(Theme.strain.opacity(0.25))
                    .frame(width: width * (target.upperBound - target.lowerBound) / Strain.maximum)
                    .offset(x: width * target.lowerBound / Strain.maximum)
                Capsule()
                    .fill(Theme.strain.gradient)
                    .frame(width: max(10, width * min(strain, Strain.maximum) / Strain.maximum))
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Strain \(PulseFormat.strain(strain)) of 21. Target \(Int(target.lowerBound)) to \(Int(target.upperBound)).")
    }
}

// MARK: - Contribution bar

/// Centered bar: grows right (green) when a factor helped, left (red) when it hurt.
struct ContributionBar: View {
    let points: Double
    var fullScale: Double = 30

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let length = max(3, min(abs(points) / fullScale, 1) * half)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.06))
                Rectangle().fill(.white.opacity(0.25)).frame(width: 1).offset(x: half)
                Capsule()
                    .fill(points >= 0 ? Theme.recoveryGreen : Theme.recoveryRed)
                    .frame(width: length)
                    .offset(x: points >= 0 ? half : half - length)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)   // the row's text already says "+12 points"
    }
}

// MARK: - Insight card

struct InsightCard: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.symbolName)
                .font(.headline)
                .foregroundStyle(Theme.color(for: insight.tone))
                .frame(width: 36, height: 36)
                .background(Theme.color(for: insight.tone).opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title).font(.headline)
                Text(insight.detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Change badge

/// "▲ 3.2" / "▼ 4" with color depending on whether up is good for this metric.
struct ChangeBadge: View {
    let delta: Double?
    var higherIsBetter = true
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    var body: some View {
        if let delta, abs(delta) >= 0.05 {
            let good = (delta > 0) == higherIsBetter
            Text("\(delta > 0 ? "▲" : "▼") \(format(abs(delta)))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(good ? Theme.recoveryGreen : Theme.recoveryYellow)
                .accessibilityLabel("\(delta > 0 ? "up" : "down") \(format(abs(delta))) from the previous period")
        } else {
            Text("no change")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: - Zone bars

/// Five horizontal bars for heart-rate zones.
struct ZoneBars: View {
    /// Minutes per zone (5 values).
    let minutes: [Int]

    var body: some View {
        let total = max(1, minutes.reduce(0, +))
        VStack(spacing: 8) {
            ForEach(0..<5, id: \.self) { zone in
                let value = zone < minutes.count ? minutes[zone] : 0
                HStack(spacing: 10) {
                    Text("Z\(zone + 1)")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.06))
                            Capsule()
                                .fill(Theme.zoneColors[zone])
                                .frame(width: max(4, geo.size.width * Double(value) / Double(total)))
                        }
                    }
                    .frame(height: 10)
                    Text(PulseFormat.duration(minutes: value))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 56, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Zone \(zone + 1), \(HeartRateZones.names[zone]): \(PulseFormat.duration(minutes: value))")
            }
        }
    }
}
