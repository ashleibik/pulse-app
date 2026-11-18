import SwiftUI
import SwiftData
import Charts
import PulseCore

// Reusable building blocks of the Mono design (ios/design/DESIGN.md), shared by all screens.
// Rules they all follow: black / white / grays only, two font weights, meaning in words and fill
// amount (never in color), VoiceOver reads each block as one sentence.

// MARK: - Screen header

/// The slim bar pinned at the top of a screen: title on the left, actions on the right.
/// It replaces the navigation bar. Its solid background also covers the status bar, so scrolled
/// content never runs under the clock.
///
/// Use it with `.safeAreaInset(edge: .top, spacing: 0) { ScreenHeader(...) }`.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    /// Sheets have a drag handle at the top and need a little more room, and use the sheet color.
    let isSheet: Bool
    let trailing: Trailing

    init(title: String, isSheet: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.isSheet = isSheet
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(title)
                .textStyle(.bodyStrong)
                .foregroundStyle(DS.Colors.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)   // the title never truncates
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DS.Space.s)
            trailing
        }
        .frame(minHeight: 44)
        .padding(.horizontal, DS.Space.side)
        .padding(.top, isSheet ? DS.Space.l : DS.Space.s)
        .padding(.bottom, DS.Space.s)
        .background(isSheet ? DS.Colors.sheet : DS.Colors.background)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, isSheet: Bool = false) {
        self.init(title: title, isSheet: isSheet) { EmptyView() }
    }
}

// MARK: - Empty state

/// Shown when a screen has nothing to show yet.
struct EmptyState: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(DS.Colors.primary)
                .padding(.bottom, DS.Space.s)
                .accessibilityHidden(true)
            Text(title)
                .textStyle(.heading)
                .foregroundStyle(DS.Colors.primary)
            Text(text)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Section title

/// Bold section heading with an optional quiet note on the right ("Avg 52%").
struct SectionTitle: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .textStyle(.label)
                .foregroundStyle(DS.Colors.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DS.Space.s)
            if let trailing {
                Text(trailing)
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
        }
    }
}

// MARK: - Hero number

/// The one huge number of a screen. Counts up when it appears.
struct HeroNumber: View {
    let value: Double
    /// Point size at the default text size (the spec allows 64 to 80).
    var size: CGFloat = 64
    let format: (Double) -> String

    /// 1.0 at the default text size, bigger with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1

    var body: some View {
        let points = size * min(max(scale, 1), 1.2)
        CountUpText(value: value, format: format)
            .font(.system(size: points, weight: .bold).width(.condensed))
            .tracking(-points * 0.01)
            .foregroundStyle(DS.Colors.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

// MARK: - Recovery dial

/// The hero: a living ring of glowing particles that fills to the recovery score, with the
/// number inside. The color follows the state (green / yellow / red) and the word under it
/// ("Ready", "Steady", "Rest") says the same, so nothing depends on color alone.
struct RecoveryDial: View {
    let score: Double?
    var diameter: CGFloat = 232
    /// Kept for older call sites. The arc is always thin now.
    var lineWidth: CGFloat = 12

    /// What is drawn right now (0...100). Animates from 0 to `score` on appear.
    @State private var shown: Double = 0
    /// 1.0 at the default text size, bigger with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hero: CGFloat { diameter * 0.36 * min(max(scale, 1), 1.2) }
    private var color: Color { DS.Colors.zone(score.map { RecoveryZone(score: $0) }) }

    var body: some View {
        ZStack {
            GlowOrb(fraction: (score ?? 0) / 100, color: color)
            // A thin exact arc on the rim: the particles give the feeling, this gives the reading.
            Circle()
                .trim(from: 0, to: shown / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))      // start at 12 o'clock
                .padding(2)
                .glow(color, radius: 8)

            VStack(spacing: 0) {
                if score != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        CountingText(value: shown) { "\(Int($0.rounded()))" }
                            .font(.system(size: hero, weight: .bold).width(.condensed))
                            .foregroundStyle(DS.Colors.primary)
                        Text("%")
                            .font(.system(size: hero * 0.4, weight: .bold).width(.condensed))
                            .foregroundStyle(color)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                } else {
                    Text("--")
                        .font(.system(size: hero, weight: .bold).width(.condensed))
                        .foregroundStyle(DS.Colors.tertiary)
                }
                Text("RECOVERY")
                    .textStyle(.label)
                    .foregroundStyle(DS.Colors.secondary)
            }
            .padding(.horizontal, DS.Space.xl)
        }
        .frame(width: diameter, height: diameter)
        .onAppear { animate(to: score) }
        .onChange(of: score) { _, newValue in animate(to: newValue) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery")
        .accessibilityValue(accessibilityText)
    }

    private func animate(to value: Double?) {
        let target = value ?? 0
        if reduceMotion {
            shown = target
        } else {
            withAnimation(DS.Motion.draw) { shown = target }
        }
    }

    private var accessibilityText: String {
        guard let score else { return "Not enough data yet" }
        return "\(Int(score.rounded())) percent. \(RecoveryZone(score: score).word)."
    }
}

// MARK: - Meters

/// 0-21 bar. Light track, darker gray band = today's target range, black fill = strain so far.
struct StrainMeter: View {
    let strain: Double
    let target: ClosedRange<Double>

    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Colors.border)
                Capsule()
                    .fill(DS.Colors.tertiary)
                    .frame(width: width * (target.upperBound - target.lowerBound) / Strain.maximum)
                    .offset(x: width * target.lowerBound / Strain.maximum)
                Capsule()
                    .fill(DS.Colors.accent)
                    .frame(width: max(8, width * min(shown, Strain.maximum) / Strain.maximum))
            }
        }
        .frame(height: 8)
        .onAppear { animate(to: strain) }
        .onChange(of: strain) { _, newValue in animate(to: newValue) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Strain \(PulseFormat.strain(strain)) of 21. Target \(Int(target.lowerBound)) to \(Int(target.upperBound)).")
    }

    private func animate(to value: Double) {
        if reduceMotion {
            shown = value
        } else {
            withAnimation(DS.Motion.draw) { shown = value }
        }
    }
}

/// Plain progress bar, 0...1. Grows in when it appears.
struct ProgressMeter: View {
    /// 0...1 (values outside are clamped).
    let fraction: Double
    var track: Color = DS.Colors.border

    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(DS.Colors.accent)
                    .frame(width: max(8, geo.size.width * min(max(shown, 0), 1)))
            }
        }
        .frame(height: 8)
        .onAppear { animate(to: fraction) }
        .onChange(of: fraction) { _, newValue in animate(to: newValue) }
        .accessibilityHidden(true)      // the text next to it says the same thing
    }

    private func animate(to value: Double) {
        if reduceMotion {
            shown = value
        } else {
            withAnimation(DS.Motion.draw) { shown = value }
        }
    }
}

/// Centered bar for "what moved your score": grows to the right when a factor helped and to the
/// left when it hurt. The signed number next to it ("+3", "-18") says the same in text.
struct ContributionBar: View {
    let points: Double
    var fullScale: Double = 30

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let length = max(4, min(abs(points) / fullScale, 1) * half)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Colors.border)
                    .frame(height: 8)
                Capsule()
                    .fill(points >= 0 ? DS.Colors.accent : DS.Colors.alert)     // helped / hurt
                    .frame(width: length, height: 8)
                    .offset(x: points >= 0 ? half : half - length)
                // The middle = "exactly at your normal".
                Rectangle()
                    .fill(DS.Colors.tertiary)
                    .frame(width: 1, height: 16)
                    .offset(x: half)
            }
            .frame(height: 16)
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

/// Five horizontal bars for heart-rate zones. The bar length is the information; no colors.
struct ZoneBars: View {
    /// Minutes per zone (5 values).
    let minutes: [Int]
    var track: Color = DS.Colors.border

    var body: some View {
        let total = max(1, minutes.reduce(0, +))
        VStack(spacing: DS.Space.m) {
            ForEach(0..<5, id: \.self) { zone in
                let value = zone < minutes.count ? minutes[zone] : 0
                HStack(spacing: DS.Space.m) {
                    Text("Z\(zone + 1)")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.primary)
                        .frame(width: 24, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(track)
                            if value > 0 {
                                Capsule()
                                    .fill(DS.Colors.accent)
                                    .frame(width: max(8, geo.size.width * Double(value) / Double(total)))
                            }
                        }
                    }
                    .frame(height: 8)
                    Text(PulseFormat.duration(minutes: value))
                        .textStyle(.caption)
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Zone \(zone + 1), \(HeartRateZones.names[zone]): \(PulseFormat.duration(minutes: value))")
            }
        }
    }
}

// MARK: - Stat

/// A number with a label above and one short line below. No box: spacing and type size separate it.
/// The number counts up when it appears.
struct StatBlock: View {
    var symbol: String? = nil
    let label: String
    /// `nil` = no data yet, shown as "--".
    let number: Double?
    /// Turns the (counting) number into text, e.g. 326 -> "5h 26m".
    let format: (Double) -> String
    var unit: String? = nil
    var caption: String? = nil
    /// `.title` (28) normally, `.heading` (22) when three stats share one row.
    var valueStyle: DS.TextStyle = .title

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                }
                Text(label)
            }
            .textStyle(.caption)
            .foregroundStyle(DS.Colors.secondary)
            .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Group {
                    if let number {
                        CountUpText(value: number, format: format)
                    } else {
                        Text("--")
                    }
                }
                .textStyle(valueStyle)
                .foregroundStyle(DS.Colors.primary)
                if let unit {
                    Text(unit)
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            if let caption {
                Text(caption)
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(number.map(format) ?? "no data") \(unit ?? ""). \(caption ?? "")")
    }
}

// MARK: - Rows

/// "Label ........ value" on one line. Used for breakdowns and settings.
struct ValueRow: View {
    let label: String
    let value: String
    var symbol: String? = nil
    /// `false` greys the value out (for "+0m"-style rows that did not matter).
    var emphasized = true

    var body: some View {
        HStack(spacing: DS.Space.m) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(DS.Colors.primary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }
            Text(label)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
            Spacer(minLength: DS.Space.s)
            Text(value)
                .textStyle(emphasized ? .bodyStrong : .body)
                .monospacedDigit()
                .foregroundStyle(emphasized ? DS.Colors.primary : DS.Colors.secondary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}

/// One workout, one line: icon, name + details, strain.
struct ActivityRow: View {
    let workout: WorkoutRecord
    /// Shows a chevron when the row opens a detail screen.
    var showsChevron = false

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: workout.kind.symbolName.outlineSymbol)
                .font(.title3)
                .foregroundStyle(DS.Colors.primary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.kind.displayName)
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.primary)
                Text("\(workout.start.formatted(date: .omitted, time: .shortened)) · \(PulseFormat.duration(minutes: workout.durationMinutes))")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
            Spacer(minLength: DS.Space.s)
            Text(PulseFormat.strain(workout.strain))
                .textStyle(.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(DS.Colors.primary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, DS.Space.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(workout.kind.displayName), \(PulseFormat.duration(minutes: workout.durationMinutes)), strain \(PulseFormat.strain(workout.strain))")
    }
}

/// One observation on the Trends screen: icon, title, one or two sentences.
struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: insight.symbolName.outlineSymbol)
                .font(.title3)
                .foregroundStyle(DS.Colors.primary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(insight.title)
                    .textStyle(.bodyStrong)
                    .foregroundStyle(DS.Colors.primary)
                Text(insight.detail)
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DS.Space.m)
        .accessibilityElement(children: .combine)
    }
}

extension String {
    /// Design rule: outline icons. PulseCore's symbol names end in ".fill" for a few items.
    var outlineSymbol: String { replacingOccurrences(of: ".fill", with: "") }
}

// MARK: - Status pill

/// The only sync UI in normal use (like WHOOP's app): the band battery when all is well, a small
/// spinner only while a big chunk is being pulled (e.g. the night), and a short warning only when
/// something needs you (Bluetooth off, band not found for a long time, band battery low).
struct StatusPill: View {
    @Environment(DataLoader.self) private var loader
    @Environment(BandManager.self) private var band
    @Query private var bands: [BandRecord]

    var body: some View {
        // Re-checked every minute: "band not found" depends on how long it has been away.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let record = bands.first
        if let warning = band.attention(record: record, now: now)?.text ?? (loader.state.isFailed ? "Data error" : nil) {
            HStack(spacing: 6) {
                Image(systemName: band.attention(record: record, now: now)?.symbol ?? "exclamationmark.triangle")
                    .foregroundStyle(DS.Colors.warn)
                Text(warning)
                    .foregroundStyle(DS.Colors.primary)
                    .lineLimit(1)
            }
            .textStyle(.caption)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .overlay(Capsule().stroke(DS.Colors.warn.opacity(0.6), lineWidth: 1))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Band: \(warning)")
        } else if band.showsSyncSpinner {
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 28, minHeight: 28)
                .accessibilityLabel("Syncing with your band")
        } else if let record, let battery = record.batteryPercent {
            HStack(spacing: 4) {
                Text("\(Int(battery.rounded()))%")
                    .foregroundStyle(DS.Colors.secondary)
                Image(systemName: record.isCharging ? "battery.100percent.bolt" : Self.batterySymbol(battery))
                    .foregroundStyle(band.isConnected ? DS.Colors.accent : DS.Colors.tertiary)
            }
            .textStyle(.caption)
            .frame(minHeight: 28)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Band battery \(Int(battery.rounded())) percent\(record.isCharging ? ", charging" : "")\(band.isConnected ? ", connected" : "")")
        }
    }

    private static func batterySymbol(_ percent: Double) -> String {
        switch percent {
        case 88...: "battery.100percent"
        case 63..<88: "battery.75percent"
        case 38..<63: "battery.50percent"
        case 13..<38: "battery.25percent"
        default: "battery.0percent"
        }
    }
}

private extension DataLoader.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Pill picker

/// A row of small pills where exactly one is selected (black). Replaces the segmented control.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(DS.Motion.spring) { selection = option }
                } label: {
                    Text(label(option))
                        .textStyle(.caption)
                        .foregroundStyle(isSelected ? DS.Colors.onPrimary : DS.Colors.primary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(isSelected ? DS.Colors.accent : DS.Colors.surface, in: Capsule())
                        .frame(minHeight: 44)       // tap target
                }
                .buttonStyle(.pressable)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Charts

/// One bar per day. Past days light gray, the highlighted day (normally today) black.
/// No gridlines, no Y axis, rounded bars.
///
/// Drawn with plain SwiftUI shapes, not Swift Charts. Why: with Swift Charts the highlighted bar
/// stayed one tap behind (the chart kept the previous colors), and taps had to be converted
/// from screen positions. Here every day is a real button that knows its own day and color, so
/// neither problem can happen.
struct DayBarsChart: View {
    struct Bar: Identifiable {
        let id: String          // unique per day (weekday letters repeat: T, T, S, S)
        let label: String       // shown under the bar; "" = no label
        let value: Double?      // nil = no data that day
        let isHighlighted: Bool
        /// Read by VoiceOver for the tappable bar, e.g. "Tuesday, November 10".
        var spokenName: String = ""
    }

    /// Oldest first.
    let bars: [Bar]
    /// Fixed scale (for example 0...100 for recovery). `nil` = from 0 to the biggest value.
    var domain: ClosedRange<Double>? = nil
    var height: CGFloat = 104
    /// The chart in words, for VoiceOver.
    let summary: String
    /// Called with the tapped bar's id. `nil` = the bars can't be tapped.
    var onSelect: ((String) -> Void)? = nil

    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var top: Double {
        domain?.upperBound ?? max((bars.compactMap(\.value).max() ?? 1) * 1.05, 1)
    }
    private var bottom: Double { domain?.lowerBound ?? 0 }
    private let labelHeight: CGFloat = 22

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(bars) { bar in
                Button {
                    onSelect?(bar.id)
                } label: {
                    column(bar)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bar.spokenName)
                .accessibilityHint("Shows this day")
            }
        }
        .frame(height: height)
        .allowsHitTesting(onSelect != nil)
        .onAppear {
            if reduceMotion {
                grown = true
            } else {
                withAnimation(DS.Motion.draw.delay(0.15)) { grown = true }
            }
        }
        // Tappable: VoiceOver visits each day. Not tappable: the whole chart is one sentence.
        .accessibilityElement(children: onSelect == nil ? .ignore : .contain)
        .accessibilityLabel(summary)
    }

    /// One day: the bar standing on the bottom line, and its label underneath.
    private func column(_ bar: Bar) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                // A day with no (or a tiny) value still gets a small stub, so the row has no hole.
                let fraction = min(max(((bar.value ?? 0) - bottom) / max(top - bottom, 0.0001), 0.03), 1)
                Capsule()
                    .fill(bar.isHighlighted ? DS.Colors.accent : DS.Colors.muted)
                    .glow(bar.isHighlighted ? DS.Colors.accent : .clear, radius: 8)
                    .frame(width: max(3, geometry.size.width * 0.5),
                           height: grown ? geometry.size.height * fraction : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            Text(bar.label)
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize()                    // sparse labels ("13") may be wider than a thin column
                .frame(height: labelHeight)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())              // the whole column is the tap target, not just the bar
    }
}

extension DayBarsChart.Bar {
    /// The bar id for a day (so a tapped bar can be turned back into its day).
    static func id(for date: Date) -> String { "\(date.timeIntervalSince1970)" }

    /// Builds bars from stored days.
    /// - Parameters:
    ///   - days: oldest first.
    ///   - highlight: the day drawn in black. Default: the last one.
    static func from(_ days: [DaySummaryRecord], highlight: Date? = nil,
                     value: (DaySummaryRecord) -> Double?) -> [DayBarsChart.Bar] {
        let target = highlight ?? days.last?.date
        // More than two weeks: a letter under every bar would be unreadable, so label one bar a
        // week with the day of the month instead.
        let sparse = days.count > 14
        var bars: [DayBarsChart.Bar] = []
        for (index, day) in days.enumerated() {
            var label = day.date.formatted(.dateTime.weekday(.narrow))
            if sparse {
                label = (days.count - 1 - index) % 7 == 0 ? day.date.formatted(.dateTime.day()) : ""
            }
            let isTarget = target.map { Calendar.current.isDate(day.date, inSameDayAs: $0) } ?? false
            bars.append(DayBarsChart.Bar(id: id(for: day.date), label: label, value: value(day),
                                         isHighlighted: isTarget,
                                         spokenName: day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())))
        }
        return bars
    }
}

/// One point on a line chart.
struct ChartPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }

    /// Reads raw minutes in [from, to) as heart-rate points (skipping off-wrist minutes).
    /// Use the view's own (main) context.
    static func heartRate(from: Date, to: Date, context: ModelContext) -> [ChartPoint] {
        PulseStore.minutes(from: from, to: to, in: context).compactMap { minute in
            minute.averageHeartRate.map { ChartPoint(date: minute.start, value: $0) }
        }
    }
}

/// A thin black line over time. No gridlines; a few quiet numbers on the right give the scale.
struct LineChart: View {
    let points: [ChartPoint]
    /// Where the X labels go, e.g. `.stride(by: .hour, count: 2)`.
    var xValues: AxisMarkValues = .automatic(desiredCount: 4)
    /// How an X label is written, e.g. `.dateTime.hour()`.
    var xFormat: Date.FormatStyle = .dateTime.month(.abbreviated).day()
    /// Puts a dot on the newest point ("today").
    var marksLast = false
    var height: CGFloat = 132
    /// Give this to make the line readable by touch: touch and hold, and the value under the
    /// finger is shown as this text (for example "62 bpm · 2:14 AM").
    var valueLabel: ((ChartPoint) -> String)? = nil
    /// The chart in words, for VoiceOver.
    let summary: String

    /// Where the finger is on the time axis (nil = not touching).
    @State private var touchedDate: Date?

    /// The lowest value shown (the fade under the line ends here).
    private var floorValue: Double { points.map(\.value).min() ?? 0 }

    /// The data point nearest to the finger.
    private var touchedPoint: ChartPoint? {
        guard valueLabel != nil, let touchedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(touchedDate)) < abs($1.date.timeIntervalSince(touchedDate)) }
    }

    var body: some View {
        Chart {
            if let point = touchedPoint, let valueLabel {
                RuleMark(x: .value("Time", point.date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(DS.Colors.tertiary)
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(valueLabel(point))
                            .textStyle(.caption)
                            .foregroundStyle(DS.Colors.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(DS.Colors.border, in: Capsule())
                    }
                PointMark(x: .value("Time", point.date), y: .value("Value", point.value))
                    .symbolSize(70)
                    .foregroundStyle(DS.Colors.accent)
            }
            ForEach(points) { point in
                // A soft fade under the line, down to the lowest value on the chart.
                AreaMark(x: .value("Time", point.date), yStart: .value("Base", floorValue),
                         yEnd: .value("Value", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [DS.Colors.accent.opacity(0.28), DS.Colors.accent.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.date), y: .value("Value", point.value))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(DS.Colors.accent)
            }
            if marksLast, let last = points.last {
                PointMark(x: .value("Time", last.date), y: .value("Value", last.value))
                    .symbolSize(70)
                    .foregroundStyle(DS.Colors.accent)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXSelection(value: $touchedDate)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel()
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: xValues) { _ in
                AxisValueLabel(format: xFormat)
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.secondary)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }
}
