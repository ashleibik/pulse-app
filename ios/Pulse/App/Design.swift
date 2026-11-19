import SwiftUI
import UIKit
import PulseCore

/// Pulse design system "Glow": a dark app where the data glows.
///
/// The written spec is `ios/design/DESIGN.md`. Change the spec first, then this file.
/// Screens use these tokens and never hard-code a color, size or animation.
/// (History: v2 "Mono" was black / white / gray only. The helper names `monoCard`,
/// `monoBackground` and `monoSheet` are kept from it so the screens didn't have to change.)
enum DS {

    // MARK: Colors (DESIGN.md section 2). Dark only.

    enum Colors {
        static let background = Color(hex: 0x05070A)
        static let surface = Color(hex: 0x12161B)
        static let border = Color(hex: 0x232A31)
        static let primary = Color(hex: 0xFFFFFF)
        static let secondary = Color(hex: 0x9BA3AC)
        /// Too faint for text. Chevrons, target ranges, disabled things only.
        static let tertiary = Color(hex: 0x59626B)
        /// Past data in charts, empty tracks.
        static let muted = Color(hex: 0x2A323A)
        /// Background of sheets: one step lighter than the screen.
        static let sheet = Color(hex: 0x0E1216)

        /// The one accent: a bright green that glows. Today's data, the ring, primary buttons.
        static let accent = Color(hex: 0x1DE9A6)
        /// Text on top of an `accent` fill.
        static let onAccent = Color(hex: 0x03130D)
        /// Middle recovery ("Steady"), wake-ups.
        static let warn = Color(hex: 0xFFD23F)
        /// Low recovery ("Rest"), things that pulled a score down.
        static let alert = Color(hex: 0xFF5C5C)

        /// The Sleep ring and sleep data (Today's three rings: sleep / recovery / strain).
        static let sleepTint = Color(hex: 0x8AB4E8)
        /// The Strain ring and strain data.
        static let strainTint = Color(hex: 0x3D9BFF)

        /// Kept so older call sites compile: text on a primary button.
        static let onPrimary = onAccent

        /// Recovery state as a color. The word (Ready / Steady / Rest) is always shown too, so
        /// nothing depends on color alone.
        static func zone(_ zone: RecoveryZone?) -> Color {
            switch zone {
            case .green: accent
            case .yellow: warn
            case .red: alert
            case nil: tertiary
            }
        }
    }

    // MARK: Typography (DESIGN.md section 3)

    /// Two weights only: bold and regular. Big numbers use the condensed width, which gives
    /// them a sporty, instrument-like look. Every style follows Dynamic Type.
    enum TextStyle {
        case display, title, heading, label, body, bodyStrong, caption

        var font: Font {
            switch self {
            case .display: .largeTitle.weight(.bold).width(.condensed)      // 34
            case .title: .title.weight(.bold).width(.condensed)             // 28
            case .heading: .title2.weight(.bold)                            // 22
            case .label: .footnote.weight(.bold)                            // 13, used in CAPS
            case .body: .body                                               // 17
            case .bodyStrong: .body.weight(.bold)                           // 17
            case .caption: .footnote                                        // 13
            }
        }

        var tracking: CGFloat {
            switch self {
            case .display: -0.4
            case .title: -0.2
            case .heading: -0.3
            case .label: 1.6                // wide letter spacing for small caps labels
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
        /// The space at the end of a tab screen, so its last content scrolls clear of the tab bar.
        static let tabBarClearance: CGFloat = 96
    }

    enum Radius {
        static let card: CGFloat = 22
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

extension Color {
    /// 0xRRGGBB -> Color.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Text and surfaces

extension View {
    /// Font + letter spacing of a design-system text style.
    func textStyle(_ style: DS.TextStyle) -> some View {
        font(style.font).tracking(style.tracking)
    }

    /// Screen background.
    func monoBackground() -> some View {
        background(DS.Colors.background.ignoresSafeArea())
    }

    /// Sheet look: `sheet` background behind everything, drag handle visible.
    func monoSheet() -> some View {
        background(DS.Colors.sheet.ignoresSafeArea())
            .environment(\.isOnSheet, true)
            .presentationBackground(DS.Colors.sheet)
            .presentationDragIndicator(.visible)
    }

    /// The card shape: dark raised surface, soft corners, a hairline edge.
    func monoCard(padding: CGFloat = DS.Space.l) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.surface,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(DS.Colors.border, lineWidth: 1))
    }

    /// A soft halo of the given color: what makes data "glow".
    func glow(_ color: Color, radius: CGFloat = 10) -> some View {
        shadow(color: color.opacity(0.55), radius: radius)
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

// MARK: - Sheets

private struct OnSheetKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `true` inside a sheet. Quiet fills (secondary pills, icon buttons) then use the next
    /// lighter step, because the sheet itself is already lighter than the screen.
    var isOnSheet: Bool {
        get { self[OnSheetKey.self] }
        set { self[OnSheetKey.self] = newValue }
    }
}

extension DS.Colors {
    /// The quiet fill behind secondary buttons and icon buttons.
    static func quietFill(onSheet: Bool) -> Color {
        onSheet ? border : surface
    }
}

// MARK: - Buttons

/// Fully rounded button. Primary = glowing accent fill, dark text. Secondary = quiet dark fill,
/// white text. Disabled buttons fade out.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind)
    }

    /// A separate view, because only views (not button styles) can read the environment.
    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: PillButtonStyle.Kind
        @Environment(\.isOnSheet) private var isOnSheet
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .textStyle(.bodyStrong)
                .foregroundStyle(kind == .primary ? DS.Colors.onAccent : DS.Colors.primary)
                .padding(.horizontal, DS.Space.l)
                .frame(minHeight: 52)
                .background(kind == .primary ? DS.Colors.accent : DS.Colors.quietFill(onSheet: isOnSheet),
                            in: Capsule())
                .glow(kind == .primary && isEnabled ? DS.Colors.accent : .clear, radius: 12)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(DS.Motion.press, value: configuration.isPressed)
        }
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

/// Round 44 pt button with one SF Symbol. Fades when disabled.
struct IconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @Environment(\.isOnSheet) private var isOnSheet
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
                .foregroundStyle(DS.Colors.primary)
                .frame(width: 44, height: 44)
                .background(DS.Colors.quietFill(onSheet: isOnSheet), in: Circle())
                .overlay(Circle().stroke(DS.Colors.border, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.35)
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

// MARK: - Glow orb

/// The living ring behind the recovery score: a few hundred glowing particles drifting on a
/// ring. The lit part of the ring shows the score; the rest stays dim.
///
/// Drawn with `Canvas` (one fast drawing pass per frame) inside a `TimelineView` (which supplies
/// the clock). With Reduce Motion on, the clock is paused and the particles stand still.
struct GlowOrb: View {
    /// 0...1: how much of the ring is lit, clockwise from 12 o'clock.
    let fraction: Double
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Particle {
        let turn: Double        // position around the ring, 0...1
        let radial: Double      // distance from the center, as a share of the radius
        let size: Double
        let alpha: Double
        let speed: Double
        let phase: Double
    }

    /// The same particles every launch (fixed seed), so the ring looks the same each time.
    private static let particles: [Particle] = {
        var state: UInt64 = 0x5EED_1234_ABCD_0042
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var list: [Particle] = []
        for _ in 0..<320 {
            let depth = next()
            // Most particles sit near the rim; a few drift further inside.
            list.append(Particle(turn: next(), radial: 1 - depth * depth * 0.30, size: 1.2 + next() * 2.6,
                                 alpha: 0.45 + next() * 0.55, speed: 0.5 + next() * 1.4, phase: next() * 6.283))
        }
        return list
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let centerX = Double(size.width) / 2
                let centerY = Double(size.height) / 2
                let radius = Double(min(size.width, size.height)) / 2 - 6
                for particle in Self.particles {
                    let pulse = sin(time * particle.speed + particle.phase)
                    let lit = particle.turn <= fraction
                    let angle = (particle.turn + 0.004 * pulse) * 2 * Double.pi - Double.pi / 2
                    let distance = radius * (particle.radial + 0.012 * pulse)
                    let dot = particle.size * (lit ? 1 : 0.7)
                    let x: Double = centerX + cos(angle) * distance - dot / 2
                    let y: Double = centerY + sin(angle) * distance - dot / 2
                    let rect = CGRect(x: x, y: y, width: dot, height: dot)
                    // Lit particles twinkle; unlit ones are a faint trace of the full circle.
                    let alpha = lit ? particle.alpha * (0.45 + 0.55 * (0.5 + 0.5 * pulse)) : 0.10
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                }
            }
        }
        .background {
            // A blurred ring underneath gives the particles their halo.
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(14)
                .blur(radius: 18)
                .opacity(0.55)
        }
        .accessibilityHidden(true)
    }
}
