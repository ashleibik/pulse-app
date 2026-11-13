import SwiftUI
import PulseCore

/// OLD design tokens (dark, colorful). Still used by every screen that has not been rebuilt in
/// the Mono design yet. New code uses `DS` (Design.swift). Delete this file when the rollout is done.
enum Theme {
    // MARK: Colors
    static let background = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let card = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let cardStroke = Color.white.opacity(0.06)
    static let secondaryText = Color.white.opacity(0.6)

    static let accent = Color(red: 0.27, green: 0.78, blue: 0.96)
    static let recoveryGreen = Color(red: 0.16, green: 0.86, blue: 0.48)
    static let recoveryYellow = Color(red: 1.00, green: 0.80, blue: 0.22)
    static let recoveryRed = Color(red: 1.00, green: 0.32, blue: 0.32)
    static let strain = Color(red: 0.29, green: 0.56, blue: 1.00)
    static let sleep = Color(red: 0.64, green: 0.52, blue: 1.00)
    static let heart = Color(red: 1.00, green: 0.36, blue: 0.45)

    static func color(for zone: RecoveryZone?) -> Color {
        switch zone {
        case .green: recoveryGreen
        case .yellow: recoveryYellow
        case .red: recoveryRed
        case nil: secondaryText
        }
    }

    static func color(for phase: SleepPhase) -> Color {
        switch phase {
        case .awake: recoveryYellow
        case .light: sleep.opacity(0.5)
        case .restful: sleep
        }
    }

    static func color(for tone: Insight.Tone) -> Color {
        switch tone {
        case .positive: recoveryGreen
        case .neutral: accent
        case .caution: recoveryYellow
        }
    }

    /// Heart-rate zones 1-5, cool to hot.
    static let zoneColors: [Color] = [
        Color(red: 0.55, green: 0.60, blue: 0.70),
        accent, recoveryGreen, recoveryYellow, recoveryRed,
    ]

    // MARK: Layout
    static let cornerRadius: CGFloat = 20
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12
}

/// The rounded "card" look used for every block of content.
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(Theme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    // The two helpers below keep the OLD dark design readable now that the app follows the
    // system's light / dark setting. Each screen drops its helper when it is rebuilt in the Mono
    // design (ios/design/DESIGN.md, "Rollout").

    /// For old-design tabs and pushed screens: they were only ever designed for dark mode.
    func legacyDarkTheme() -> some View {
        environment(\.colorScheme, .dark)
            .tint(Theme.accent)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// For old-design sheets and full-screen covers. A sheet is its own "presentation", so
    /// `preferredColorScheme` changes only the sheet, not the screen underneath.
    func legacyDarkSheet() -> some View {
        preferredColorScheme(.dark)
            .tint(Theme.accent)
    }

    func card() -> some View { modifier(CardStyle()) }

    /// Standard screen background + scroll padding.
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}
