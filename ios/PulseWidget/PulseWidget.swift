import WidgetKit
import SwiftUI

// Home screen + lock screen widget: last night's recovery, sleep score and sleep time.
// It never computes anything itself: it shows the snapshot the app wrote (Shared/WidgetSnapshot.swift).

struct PulseEntry: TimelineEntry {
    let date: Date
    /// nil = the app hasn't written anything yet (or the App Group isn't available).
    let snapshot: WidgetSnapshot?
}

struct PulseProvider: TimelineProvider {
    func placeholder(in context: Context) -> PulseEntry {
        PulseEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (PulseEntry) -> Void) {
        let stored = WidgetSnapshot.load()
        completion(PulseEntry(date: .now, snapshot: context.isPreview ? (stored ?? .empty) : stored))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PulseEntry>) -> Void) {
        // The app asks for a reload after every sync. This is only a safety refresh, so the widget
        // notices when the day it shows is over.
        let entry = PulseEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

// MARK: - Look (same tokens as the app's Glow design, ios/design/DESIGN.md)

private enum Glow {
    static let background = Color(red: 0x05 / 255, green: 0x07 / 255, blue: 0x0A / 255)
    static let track = Color(red: 0x23 / 255, green: 0x2A / 255, blue: 0x31 / 255)
    static let secondary = Color(red: 0x9B / 255, green: 0xA3 / 255, blue: 0xAC / 255)
    static let accent = Color(red: 0x1D / 255, green: 0xE9 / 255, blue: 0xA6 / 255)
    static let warn = Color(red: 0xFF / 255, green: 0xD2 / 255, blue: 0x3F / 255)
    static let alert = Color(red: 0xFF / 255, green: 0x5C / 255, blue: 0x5C / 255)

    static func zone(_ raw: String?) -> Color {
        switch raw {
        case "green": return accent
        case "yellow": return warn
        case "red": return alert
        default: return secondary
        }
    }
}

private func numberFont(_ size: CGFloat) -> Font { .system(size: size, weight: .bold).width(.condensed) }

private struct CapsLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Glow.secondary)
    }
}

/// Thin glowing ring with the recovery number inside.
private struct Ring: View {
    let snapshot: WidgetSnapshot
    var lineWidth: CGFloat = 6
    var numberSize: CGFloat = 30

    var body: some View {
        let color = Glow.zone(snapshot.zone)
        ZStack {
            Circle().stroke(Glow.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: (snapshot.recovery ?? 0) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.7), radius: 6)
            Text(snapshot.recoveryText)
                .font(numberFont(numberSize))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(lineWidth * 2)
        }
    }
}

// MARK: - Views per size

struct PulseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PulseEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot)       // a tap opens the app
        } else {
            empty
        }
    }

    @ViewBuilder
    private func content(_ s: WidgetSnapshot) -> some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: s.recovery ?? 0, in: 0...100) {
                Text("REC")
            } currentValueLabel: {
                Text(s.recovery.map { "\(Int($0.rounded()))" } ?? "--")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel("Recovery \(s.recoveryText), \(s.word)")

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Recovery \(s.recoveryText) · \(s.word)")
                    .font(.headline)
                    .widgetAccentable()
                Text("Sleep score \(s.sleepScoreText)")
                Text("Slept \(s.sleepText)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .accessoryInline:
            Text("Recovery \(s.recoveryText) · Sleep \(s.sleepScoreText)")

        case .systemMedium:
            HStack(spacing: 16) {
                Ring(snapshot: s, lineWidth: 7, numberSize: 34)
                    .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.word.uppercased())
                        .font(numberFont(22))
                        .foregroundStyle(Glow.zone(s.zone))
                    stat("Sleep score", s.sleepScoreText)
                    stat("Sleep time", s.sleepText)
                    footer(s)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenSummary(s))

        default:    // systemSmall
            VStack(spacing: 6) {
                Ring(snapshot: s, lineWidth: 5, numberSize: 24)
                HStack(spacing: 8) {
                    smallStat("Sleep", s.sleepScoreText)
                    smallStat("Time", s.sleepText)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenSummary(s))
        }
    }

    private func spokenSummary(_ s: WidgetSnapshot) -> String {
        "Recovery \(s.recoveryText), \(s.word). Sleep score \(s.sleepScoreText), slept \(s.sleepText)."
    }

    private func smallStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(numberFont(15))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            CapsLabel(text: label)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            CapsLabel(text: label)
            Text(value)
                .font(numberFont(18))
                .foregroundStyle(.white)
        }
    }

    /// "Updated 7:42", or the day it is from, so an old number is never mistaken for a fresh one.
    private func footer(_ s: WidgetSnapshot) -> some View {
        let isToday = Calendar.current.isDateInToday(s.day)
        let text = isToday ? "Updated \(s.updated.formatted(date: .omitted, time: .shortened))"
            : "From \(s.day.formatted(.dateTime.weekday(.abbreviated)))"
        return Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Glow.secondary)
    }

    @ViewBuilder
    private var empty: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            Text("Open Pulse")
        default:
            VStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 28, weight: .thin))
                    .foregroundStyle(Glow.accent)
                Text("Open Pulse once to fill this in")
                    .font(.system(size: 12))
                    .foregroundStyle(Glow.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Widget

@main
struct PulseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PulseRecovery", provider: PulseProvider()) { entry in
            PulseWidgetView(entry: entry)
                .containerBackground(Glow.background, for: .widget)
        }
        .configurationDisplayName("Last night")
        .description("Last night's recovery, sleep score and sleep time.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
