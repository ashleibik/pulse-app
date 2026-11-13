import SwiftUI
import UIKit

/// Pulse design system "Mono": black, white and grays only.
///
/// The written spec is `ios/design/DESIGN.md`. Change the spec first, then this file.
/// Screens use these tokens and never hard-code a color, size or animation.
enum DS {

    // MARK: Colors (DESIGN.md section 2)

    enum Colors {
        static let background = dynamic(light: 0xFFFFFF, dark: 0x000000)
        static let surface = dynamic(light: 0xF5F5F5, dark: 0x111111)
        static let border = dynamic(light: 0xEAEAEA, dark: 0x1F1F1F)
        static let primary = dynamic(light: 0x111111, dark: 0xFFFFFF)
        static let secondary = dynamic(light: 0x6B6B6B, dark: 0x8A8A8A)
        /// Too faint for text. Chevrons, target ranges, disabled things only.
        static let tertiary = dynamic(light: 0xA3A3A3, dark: 0x5C5C5C)
        /// Past data in charts.
        static let muted = dynamic(light: 0xD4D4D4, dark: 0x333333)
        /// Text on top of a `primary` fill.
        static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x000000)

        /// One color that switches by itself between light and dark mode.
        private static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(uiColor: UIColor { traits in
                UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
            })
        }
    }

    // MARK: Typography (DESIGN.md section 3)

    /// Two weights only: bold and regular. Every style maps to a system text style, so it
    /// follows the user's Dynamic Type setting.
    enum TextStyle {
        case display, title, heading, body, bodyStrong, caption

        var font: Font {
            switch self {
            case .display: .largeTitle.weight(.bold)      // 34
            case .title: .title.weight(.bold)             // 28
            case .heading: .title2.weight(.bold)          // 22
            case .body: .body                             // 17
            case .bodyStrong: .body.weight(.bold)         // 17
            case .caption: .footnote                      // 13
            }
        }

        /// Tight letter spacing on big type (the Mobbin headline look).
        var tracking: CGFloat {
            switch self {
            case .display: -0.8
            case .title: -0.5
            case .heading: -0.3
            case .body, .bodyStrong, .caption: 0
            }
        }
    }

    // MARK: Layout (DESIGN.md sections 4 and 5)

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        /// Left/right padding of every screen.
        static let side: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 24
    }

    // MARK: Motion (DESIGN.md section 9)

    enum Motion {
        /// Ring drawing in, numbers counting up, bars growing. No bounce, so a number never overshoots.
        static let draw = Animation.smooth(duration: 1.2)
        /// Sections rising in, layout changes.
        static let spring = Animation.spring(response: 0.45, dampingFraction: 0.8)
        /// Buttons while pressed.
        static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)
    }
}

private extension UIColor {
    /// 0xRRGGBB -> UIColor.
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Text and surfaces

extension View {
    /// Font + letter spacing of a design-system text style.
    func textStyle(_ style: DS.TextStyle) -> some View {
        font(style.font).tracking(style.tracking)
    }

    /// Screen background of the Mono design.
    func monoBackground() -> some View {
        background(DS.Colors.background.ignoresSafeArea())
    }

    /// The one card shape: soft gray fill, big radius, no border, no shadow.
    func monoCard(padding: CGFloat = DS.Space.l) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.surface,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    /// Fade + rise when the view first appears. `index` staggers neighbours (60 ms apart).
    func riseIn(_ index: Int = 0) -> some View {
        modifier(RiseIn(index: index))
    }
}

/// 1 pt separator line.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(DS.Colors.border)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

private struct RiseIn: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 16)
            .onAppear {
                let animation = reduceMotion
                    ? Animation.easeOut(duration: 0.2)
                    : DS.Motion.spring.delay(Double(index) * 0.06)
                withAnimation(animation) { shown = true }
            }
    }
}

// MARK: - Buttons

/// Fully rounded button. Primary = black fill, white text. Secondary = light gray fill, black text.
/// (Colors flip in dark mode.)
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.bodyStrong)
            .foregroundStyle(kind == .primary ? DS.Colors.onPrimary : DS.Colors.primary)
            .padding(.horizontal, DS.Space.l)
            .frame(minHeight: 52)
            .background(kind == .primary ? DS.Colors.primary : DS.Colors.surface, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(DS.Motion.press, value: configuration.isPressed)
    }
}

/// For tappable content that is not a pill (rows, stats, cards): a small "give" when pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(DS.Motion.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var primaryPill: PillButtonStyle { PillButtonStyle(kind: .primary) }
    static var secondaryPill: PillButtonStyle { PillButtonStyle(kind: .secondary) }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

/// Round 44 pt button with one SF Symbol (regular weight, monochrome).
struct IconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
                .foregroundStyle(DS.Colors.primary)
                .frame(width: 44, height: 44)
                .background(DS.Colors.surface, in: Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
    }
}

// MARK: - Counting number

/// A number that counts up (or down) when its value changes inside `withAnimation`.
///
/// How it works: SwiftUI sees `animatableData` and, during an animation, calls `body` again and
/// again with in-between values (0, 3, 9, 17 ... 37) instead of jumping straight to the end.
struct CountingText: View, Animatable {
    var value: Double
    var format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(format(value)).monospacedDigit()
    }
}

/// Counts from 0 up to `value` the first time it appears, and again whenever `value` changes.
/// With Reduce Motion on, the final value just shows.
struct CountUpText: View {
    let value: Double
    var format: (Double) -> String

    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CountingText(value: shown, format: format)
            .onAppear { animate(to: value) }
            .onChange(of: value) { _, newValue in animate(to: newValue) }
    }

    private func animate(to target: Double) {
        if reduceMotion {
            shown = target
        } else {
            withAnimation(DS.Motion.draw) { shown = target }
        }
    }
}
