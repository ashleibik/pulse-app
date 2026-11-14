import SwiftUI
import PulseCore

/// Wrapper so a sleep phase can drive `.sheet(item:)`.
struct SleepPhaseSelection: Identifiable {
    let phase: SleepPhase
    var id: String { phase.rawValue }
}

/// The sheet behind the Restful / Light / Awake labels on the Sleep screen: how much of it you
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
                Text("Pulse doesn't guess REM or deep sleep: heart rate and motion alone can't measure them reliably. General wellness information, not medical advice.")
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
        case .restful:
            "The calmest part of your night: you were very still and your heart rate was low. More restful time usually goes with a better recovery score."
        case .light:
            "Asleep, but less settled: small movements or a slightly higher heart rate. It's a normal part of every night and often makes up about half of it."
        case .awake:
            "Short wake-ups: you moved clearly or your heart rate jumped. A few brief ones are normal, and most are forgotten by morning."
        }
    }

    private var method: String {
        switch phase {
        case .restful:
            "A minute counts as restful when there is almost no movement and your heart rate is at or below the night's middle value."
        case .light:
            "Any sleeping minute that is neither restful nor awake."
        case .awake:
            "A minute counts as awake when you moved clearly, your heart rate was 10 or more beats above the night's middle value, or the band had no reading."
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
