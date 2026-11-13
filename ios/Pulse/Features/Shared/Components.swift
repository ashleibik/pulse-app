import SwiftUI
import PulseCore

// Reusable building blocks shared by several screens.

// MARK: - Recovery ring

/// The big ring on the Home screen. Animates in, colored by zone, VoiceOver reads it as one element.
struct RecoveryRing: View {
    let score: Double?
    var size: CGFloat = 200
    var lineWidth: CGFloat = 16

    @State private var progress: Double = 0

    private var zone: RecoveryZone? { score.map(RecoveryZone.init(score:)) }

    var body: some View {
        let color = Theme.color(for: zone)
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 8)
            VStack(spacing: 2) {
                Text(score.map(PulseFormat.percent) ?? "--")
                    .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("RECOVERY")
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { progress = (score ?? 0) / 100 }
        }
        .onChange(of: score) { _, newValue in
            withAnimation(.easeOut(duration: 0.6)) { progress = (newValue ?? 0) / 100 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery")
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        guard let score, let zone else { return "No data yet" }
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
                    .lineLimit(1)
            }
        }
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

/// Top-left status pill. Until Phase 5 it always says "Demo data", so fake numbers are never
/// mistaken for real ones.
struct SyncStatusChip: View {
    @Environment(DemoDataLoader.self) private var loader

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
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
