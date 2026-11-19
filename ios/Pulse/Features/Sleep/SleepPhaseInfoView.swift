import SwiftUI
import PulseCore

/// Wrapper so a sleep phase can drive `.sheet(item:)`.
struct SleepPhaseSelection: Identifiable {
    let phase: SleepPhase
    var id: String { phase.rawValue }
}

extension SleepPhase {
    /// The stage's color on the Sleep tab and the Sleep page (DESIGN.md §4b-6).
    var tint: Color {
        switch self {
        case .awake: DS.Colors.warn
        case .rem: DS.Colors.accent
        case .light: DS.Colors.sleepTint.opacity(0.45)
        case .deep: DS.Colors.sleepTint
        }
    }
}

/// The sheet behind the Deep / Light / REM / Awake labels on the Sleep screen: how much of it you
/// had, what it means, and how Pulse tells. Mono design (ios/design/DESIGN.md).
struct SleepPhaseInfoView: View {
    let phase: SleepPhase
    /// Minutes of this phase in the night on screen.
    let minutes: Int
    /// Minutes of the whole night (all phases).
    let nightMinutes: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("This night")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                    HeroNumber(value: Double(minutes)) { PulseFormat.duration(minutes: Int($0.rounded())) }
                    if nightMinutes > 0 {
                        Text("\(Int((Double(minutes) / Double(nightMinutes) * 100).rounded()))% of your time in bed.")
                            .textStyle(.body)
                            .foregroundStyle(DS.Colors.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

                block("What it means", meaning)
                block("How Pulse tells", method)
                Text("Stages are estimates from your heart rate and movement, not a sleep-lab measurement. General wellness information, not medical advice.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: phase.title, isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
    }

    private var meaning: String {
        switch phase {
        case .deep:
            "The deepest part of your sleep: your heart rate is low and very steady. It usually comes earlier in the night."
        case .rem:
            "The stage most linked to vivid dreams. Your heart rate rises and varies more, and this stage usually gets longer toward morning."
        case .light:
            "Asleep, but not in deep or REM sleep. It's a normal part of every night and often makes up about half of it."
        case .awake:
            "Short wake-ups: you moved clearly or your heart rate jumped. A few brief ones are normal, and most are forgotten by morning."
        }
    }

    private var method: String {
        switch phase {
        case .deep:
            "Pulse looks for stretches when your heart rate is flat, you are still and your breathing rhythm is regular, mostly earlier in the night."
        case .rem:
            "Pulse looks for a more variable heart rate and a less regular breathing rhythm while you are still, mostly later in the night."
        case .light:
            "Any sleeping minute that doesn't look like deep or REM sleep."
        case .awake:
            "A minute counts as awake when you moved clearly or your heart rate was 10 or more beats above the night's middle value."
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
