import SwiftUI
import SwiftData
import PulseCore

// Settings > Steps > Step test: the band's 100 Hz count of a walk next to the owner's own count (DESIGN.md §4b-8,
// docs/METRICS.md §15). A check only: it never changes how steps are counted.

/// "Within 5%" / "More than 5% off", so the color is never the only signal.
private func verdict(_ difference: Double, limit: Double) -> (word: String, color: Color) {
    abs(difference) <= limit
        ? ("Within \(Int(limit * 100))%", DS.Colors.accent)
        : ("More than \(Int(limit * 100))% off", DS.Colors.warn)
}

/// Walk, count 500 steps by hand, stop: the band's count of the same walk next to yours.
struct StepTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(BandManager.self) private var band
    @Query(sort: \StepReferenceRecord.start, order: .reverse) private var references: [StepReferenceRecord]

    /// Kept outside the view, so a walk survives the app going to the background.
    @AppStorage("stepTestStart") private var startedAt: Double = 0
    @AppStorage("stepTestEnd") private var stoppedAt: Double = 0
    /// The band's 100 Hz count of the walk, taken at Stop. -1 = the stream sent nothing.
    @AppStorage("stepTestLive") private var liveCount = -1
    @State private var counted = 500
    @State private var removing: StepReferenceRecord?

    private static let limit = 0.05
    private var start: Date { Date(timeIntervalSince1970: startedAt) }
    private var end: Date { Date(timeIntervalSince1970: stoppedAt) }
    private var tests: [Steps.Reference] {
        references.map(\.value).filter { $0.kind == .stepTest }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                Text("Walk at your usual pace and count 500 steps in your head. Tap Start as you take the first step and Stop on the 500th. Keep the band on and your iPhone nearby.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if startedAt == 0 {
                    Button("Start") {
                        startedAt = Date.now.timeIntervalSince1970
                        stoppedAt = 0
                        liveCount = -1
                        band.startStepTest(context: context)
                    }
                    .buttonStyle(.primaryPill)
                } else if stoppedAt == 0 {
                    walking
                } else {
                    result
                }

                if !tests.isEmpty { savedTests }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Step test", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
        .confirmationDialog("Remove this step test?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { context.delete(removing) }
                try? context.save()
                removing = nil
            }
        }
    }

    private var walking: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let seconds = max(0, Int(timeline.date.timeIntervalSince(start)))
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .textStyle(.title)
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.accent)
                        .accessibilityLabel("\(seconds / 60) minutes \(seconds % 60) seconds")
                    Text(streamNote(seconds: seconds, now: timeline.date))
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Stop") { stop() }
                .buttonStyle(.primaryPill)
            Button("Cancel") { reset() }
                .buttonStyle(.secondaryPill)
        }
    }

    /// What the stream is doing: the band's count so far, or why there is none.
    private func streamNote(seconds: Int, now: Date) -> String {
        if !band.liveSteps.isEmpty {
            return "The band has counted \(band.liveSteps.steps(from: start, to: now).formatted()) steps so far."
        }
        if seconds < 15 { return "Waiting for the band's motion…" }
        return band.isConnected
            ? "The band isn't sending its motion yet. Keep walking, or cancel and try again."
            : "Not connected to the band (\(band.statusLine)). Keep your iPhone nearby."
    }

    private func stop() {
        stoppedAt = Date.now.timeIntervalSince1970
        liveCount = band.liveSteps.isEmpty ? -1 : band.liveSteps.steps(from: start, to: end)
        band.stopStepTest()
    }

    @ViewBuilder
    private var result: some View {
        if liveCount >= 0 {
            let difference = Double(liveCount - counted) / Double(max(1, counted))
            let judged = verdict(difference, limit: Self.limit)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    StatBlock(symbol: "waveform.path.ecg", label: "Band", number: Double(liveCount), format: { Int($0).formatted() },
                              caption: "counted", valueStyle: .title)
                    StatBlock(symbol: "hand.raised", label: "You", number: Double(counted), format: { Int($0).formatted() },
                              caption: "counted", valueStyle: .title)
                }
                HStack(spacing: DS.Space.s) {
                    Text(StepsData.percent(difference))
                        .textStyle(.heading)
                        .foregroundStyle(judged.color)
                    Text(judged.word)
                        .textStyle(.body)
                        .foregroundStyle(DS.Colors.secondary)
                }
                .accessibilityElement(children: .combine)
                countedRow
                Button("Save") {
                    context.insert(StepReferenceRecord(Steps.Reference(kind: .stepTest, start: start, end: end, steps: counted,
                                                                       createdAt: .now, liveSteps: liveCount)))
                    try? context.save()
                    reset()
                }
                .buttonStyle(.primaryPill)
                Button("Discard") { reset() }
                    .buttonStyle(.secondaryPill)
            }
        } else {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("The band didn't send its motion during this walk, so there is nothing to compare. Keep your iPhone near the band and try again.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { reset() }
                    .buttonStyle(.primaryPill)
            }
        }
    }

    /// "You counted" with minus / plus, 10 steps a click.
    private var countedRow: some View {
        HStack(spacing: DS.Space.s) {
            Text("You counted")
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
            Spacer(minLength: DS.Space.s)
            Text(counted.formatted())
                .textStyle(.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(DS.Colors.primary)
                .padding(.trailing, DS.Space.xs)
            IconButton(systemName: "minus", label: "Fewer steps") { counted = max(100, counted - 10) }
            IconButton(systemName: "plus", label: "More steps") { counted = min(5_000, counted + 10) }
        }
        .frame(minHeight: 60)
    }

    private var savedTests: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Your step tests",
                         trailing: Steps.averageDifference(tests).map { String(format: "Average off %.1f%%", $0 * 100) })
                .padding(.bottom, DS.Space.s)
            ForEach(Array(tests.enumerated()), id: \.element.id) { index, test in
                if index > 0 { Hairline() }
                HStack(spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(test.start.formatted(date: .abbreviated, time: .shortened))
                            .textStyle(.body)
                            .foregroundStyle(DS.Colors.primary)
                        Text("Band \(test.liveSteps.map { $0.formatted() } ?? "--") · you \(test.steps.formatted())")
                            .textStyle(.caption)
                            .foregroundStyle(DS.Colors.secondary)
                    }
                    Spacer(minLength: DS.Space.s)
                    Text(test.difference.map(StepsData.percent) ?? "--")
                        .textStyle(.bodyStrong)
                        .monospacedDigit()
                        .foregroundStyle(test.difference.map { verdict($0, limit: Self.limit).color } ?? DS.Colors.secondary)
                    Button("Remove") { removing = references.first { $0.id == test.id } }
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                        .frame(minHeight: 44)
                }
                .frame(minHeight: 60)
            }
        }
    }

    private func reset() {
        band.stopStepTest()
        startedAt = 0
        stoppedAt = 0
        liveCount = -1
        counted = 500
    }
}
