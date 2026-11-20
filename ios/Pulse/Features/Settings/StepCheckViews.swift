import SwiftUI
import SwiftData
import PulseCore

// Settings > Steps: the step test and the Apple Watch comparison (DESIGN.md §4b-8, docs/METRICS.md §15).
// Every difference shown is checked without the entry itself, so it is never flattered by what it is checked on.

/// The owner's entries with Pulse's count for each, compared one at a time.
@MainActor
private func comparisons(_ references: [StepReferenceRecord], sleeps: [SleepRecord], days: [DaySummaryRecord],
                         maxHeartRate: Double, context: ModelContext) -> [Steps.Comparison] {
    Steps.compare(StepsData.checked(references.map(\.value), sleeps: sleeps.map(\.value), days: Array(days),
                                    maxHeartRate: maxHeartRate, context: context))
}

/// "Within 5%" / "More than 5% off", so the color is never the only signal.
private func verdict(_ difference: Double, limit: Double) -> (word: String, color: Color) {
    abs(difference) <= limit
        ? ("Within \(Int(limit * 100))%", DS.Colors.accent)
        : ("More than \(Int(limit * 100))% off", DS.Colors.warn)
}

// MARK: - Step test

/// Walk, count 500 steps by hand, stop: Pulse's count for the same minutes next to yours.
struct StepTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(BandManager.self) private var band
    @Query(sort: \StepReferenceRecord.start, order: .reverse) private var references: [StepReferenceRecord]
    @Query private var sleepRecords: [SleepRecord]
    @Query private var days: [DaySummaryRecord]
    @Query private var profiles: [ProfileRecord]

    /// Kept outside the view, so a walk survives the app going to the background.
    @AppStorage("stepTestStart") private var startedAt: Double = 0
    @AppStorage("stepTestEnd") private var stoppedAt: Double = 0
    /// The band's 100 Hz count of the walk, taken at Stop. -1 = the stream sent nothing.
    @AppStorage("stepTestLive") private var liveCount = -1
    @State private var counted = 500
    /// Pulse's all-day (once a second) count for the walk, with the factor learned before it.
    @State private var pulse: Int?
    @State private var waitingNote = "Waiting for the band…"
    @State private var saved: [Steps.Comparison] = []
    @State private var removing: StepReferenceRecord?

    private var maxHeartRate: Double { profiles.first?.estimatedMaxHeartRate() ?? 190 }
    private var start: Date { Date(timeIntervalSince1970: startedAt) }
    private var end: Date { Date(timeIntervalSince1970: stoppedAt) }
    private var tests: [StepReferenceRecord] { references.filter { $0.kindRaw == Steps.Reference.Kind.stepTest.rawValue } }

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
                        pulse = nil
                        band.startMotionStream(context: context)
                    }
                    .buttonStyle(.primaryPill)
                    Text("During the test the band streams its motion 100 times a second, so Pulse can count each step. It stops at Stop, or after 15 minutes.")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if stoppedAt == 0 {
                    walking
                } else if pulse != nil || liveCount >= 0 {
                    result(pulse)
                } else {
                    waiting
                }

                if !saved.isEmpty { savedTests }
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
        .task(id: references.count) { reloadSaved() }
        .task(id: stoppedAt) { await waitForData() }
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
        if seconds < 15 { return "Waiting for the band's motion stream…" }
        return band.isConnected
            ? "The band isn't sending its 100 Hz motion. Pulse will use its once-a-second estimate."
            : "Not connected to the band (\(band.statusLine)). Pulse will use its once-a-second estimate."
    }

    private func stop() {
        stoppedAt = Date.now.timeIntervalSince1970
        liveCount = band.liveSteps.isEmpty ? -1 : band.liveSteps.steps(from: start, to: end)
        band.stopMotionStream()
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                ProgressView()
                Text(waitingNote)
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Discard") { reset() }
                .buttonStyle(.secondaryPill)
        }
    }

    /// - Parameter pulse: the all-day (once a second) count, nil while its minutes haven't arrived.
    private func result(_ pulse: Int?) -> some View {
        // The band's own 100 Hz count is the headline when the stream ran; the all-day estimate is checked too.
        let headline = liveCount >= 0 ? liveCount : (pulse ?? 0)
        let difference = Double(headline - counted) / Double(max(1, counted))
        let judged = verdict(difference, limit: 0.05)
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                StatBlock(symbol: "waveform.path.ecg", label: "Pulse", number: Double(headline), format: { Int($0).formatted() },
                          caption: liveCount >= 0 ? "100 Hz count" : "estimated", valueStyle: .title)
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
            if liveCount >= 0 {
                Text(pulse.map { "All-day estimate (once a second): \($0.formatted()) steps, \(StepsData.percent(Double($0 - counted) / Double(max(1, counted))))." }
                     ?? "All-day estimate (once a second): \(waitingNote)")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
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
            Text("The all-day estimate uses what Pulse learned before this walk. Saving the walk teaches it your pace.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Save") {
                context.insert(StepReferenceRecord(Steps.Reference(kind: .stepTest, start: start, end: end, steps: counted,
                                                                   createdAt: .now, liveSteps: liveCount >= 0 ? liveCount : nil)))
                try? context.save()
                reset()
            }
            .buttonStyle(.primaryPill)
            Button("Discard") { reset() }
                .buttonStyle(.secondaryPill)
        }
    }

    /// The band's 100 Hz count against yours, for a saved test that has one.
    private func liveDifference(_ reference: Steps.Reference) -> Double? {
        guard let live = reference.liveSteps, reference.steps > 0 else { return nil }
        return Double(live - reference.steps) / Double(reference.steps)
    }

    private var savedTests: some View {
        let liveErrors = saved.compactMap { liveDifference($0.reference) }.map(abs)
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Your step tests",
                         trailing: liveErrors.isEmpty ? nil
                             : String(format: "100 Hz average off %.1f%%", liveErrors.reduce(0, +) / Double(liveErrors.count) * 100))
                .padding(.bottom, DS.Space.s)
            ForEach(Array(saved.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Hairline() }
                let live = liveDifference(item.reference)
                HStack(spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.reference.start.formatted(date: .abbreviated, time: .shortened))
                            .textStyle(.body)
                            .foregroundStyle(DS.Colors.primary)
                        Text("100 Hz \(item.reference.liveSteps.map { $0.formatted() } ?? "--") · all-day \(item.pulse.map { $0.formatted() } ?? "--") (\(item.difference.map(StepsData.percent) ?? "--")) · you \(item.reference.steps.formatted())")
                            .textStyle(.caption)
                            .foregroundStyle(DS.Colors.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DS.Space.s)
                    Text((live ?? item.difference).map(StepsData.percent) ?? "--")
                        .textStyle(.bodyStrong)
                        .monospacedDigit()
                        .foregroundStyle((live ?? item.difference).map { verdict($0, limit: 0.05).color } ?? DS.Colors.secondary)
                    Button("Remove") { removing = references.first { $0.id == item.id } }
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                        .frame(minHeight: 44)
                }
                .frame(minHeight: 60)
            }
            Text("The 100 Hz count is the band's own count of the walk. The all-day estimate is checked with what Pulse learned from your other tests and Apple Watch days, not from this one.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.m)
        }
    }

    private func reloadSaved() {
        saved = comparisons(references, sleeps: sleepRecords, days: days, maxHeartRate: maxHeartRate, context: context)
            .filter { $0.reference.kind == .stepTest }
            .sorted { $0.reference.start > $1.reference.start }
    }

    private func reset() {
        band.stopMotionStream()
        startedAt = 0
        stoppedAt = 0
        liveCount = -1
        pulse = nil
        counted = 500
    }

    /// After Stop: pull the band's newest records, then count once the walk's minutes are in.
    private func waitForData() async {
        guard startedAt > 0, stoppedAt > startedAt, pulse == nil else { return }
        let walkStart = start, walkEnd = end
        let checkedBefore = StepsData.checked(references.map(\.value), sleeps: sleepRecords.map(\.value), days: Array(days),
                                              maxHeartRate: maxHeartRate, context: context)
        let factor = Steps.factor(checkedBefore)
        for attempt in 0..<120 {
            if attempt % 12 == 0, band.stage != .syncing { band.syncNow(context: context) }
            let minutes = PulseStore.minutes(from: walkStart.addingTimeInterval(-60), to: walkEnd.addingTimeInterval(60), in: context)
            let counted = Steps.window(minutes: minutes, sleeps: sleepRecords.map(\.value), from: walkStart, to: walkEnd,
                                       restingHeartRate: StepsData.restingHeartRate(on: walkStart, days: Array(days)),
                                       maxHeartRate: maxHeartRate)
            if counted.coverage >= Steps.fullCoverage {
                pulse = Int((Double(counted.steps) * factor.value).rounded())
                return
            }
            waitingNote = band.isConnected
                ? "Waiting for the band… \(Int((counted.coverage * 100).rounded()))% of your walk is in."
                : "Waiting for the band. \(band.statusLine)."
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
        }
        waitingNote = "The band hasn't sent this walk yet. Keep this screen open near the band, or discard and try again."
    }
}

// MARK: - Apple Watch

/// A day's Apple Watch total next to Pulse's count for the same day.
struct WatchStepsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \StepReferenceRecord.start, order: .reverse) private var references: [StepReferenceRecord]
    @Query private var sleepRecords: [SleepRecord]
    @Query private var days: [DaySummaryRecord]
    @Query private var profiles: [ProfileRecord]

    @State private var day = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now)) ?? .now
    @State private var stepsText = ""
    @State private var compared: [Steps.Comparison] = []
    @State private var removing: StepReferenceRecord?
    @FocusState private var typing: Bool

    private var maxHeartRate: Double { profiles.first?.estimatedMaxHeartRate() ?? 190 }
    private var yesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now)) ?? .now
    }
    private var enteredSteps: Int? { Int(stepsText.filter(\.isNumber)).flatMap { $0 > 0 && $0 < 200_000 ? $0 : nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                if let average = Steps.averageError(compared) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("AVERAGE DIFFERENCE")
                            .textStyle(.label)
                            .foregroundStyle(DS.Colors.secondary)
                        Text(String(format: "%.1f%%", average * 100))
                            .textStyle(.display)
                            .foregroundStyle(verdict(average, limit: 0.10).color)
                        Text("\(verdict(average, limit: 0.10).word), over \(compared.filter { !$0.isPartial && $0.difference != nil }.count) days")
                            .textStyle(.body)
                            .foregroundStyle(DS.Colors.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DS.Space.m) {
                        Text("Day")
                            .textStyle(.body)
                            .foregroundStyle(DS.Colors.primary)
                        Spacer(minLength: DS.Space.s)
                        DatePicker("Day", selection: $day, in: ...yesterday, displayedComponents: .date)
                            .labelsHidden()
                            .tint(DS.Colors.accent)
                    }
                    .frame(minHeight: 52)
                    Hairline()
                    HStack(spacing: DS.Space.m) {
                        Text("Apple Watch steps")
                            .textStyle(.body)
                            .foregroundStyle(DS.Colors.primary)
                        Spacer(minLength: DS.Space.s)
                        TextField("0", text: $stepsText)
                            .keyboardType(.numberPad)
                            .focused($typing)
                            .multilineTextAlignment(.trailing)
                            .textStyle(.bodyStrong)
                            .foregroundStyle(DS.Colors.primary)
                    }
                    .frame(minHeight: 52)
                }
                .monoCard(padding: DS.Space.m)

                Button("Add day") { add() }
                    .buttonStyle(.primaryPill)
                    .disabled(enteredSteps == nil)

                if !compared.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle(title: "Days", trailing: "Pulse · Watch")
                            .padding(.bottom, DS.Space.s)
                        ForEach(Array(compared.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Hairline() }
                            row(item)
                        }
                    }
                }

                Text("Use the Health app's total for the whole day. Each day is checked with what Pulse learned from your other days and step tests, not from itself, so the difference shows how it does on a day it hasn't seen. Days the band measured under 90% of are left out of the average.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Apple Watch", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
        .task(id: references.count) { reload() }
        .confirmationDialog("Remove this day?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { context.delete(removing) }
                try? context.save()
                removing = nil
            }
        }
    }

    private func row(_ item: Steps.Comparison) -> some View {
        HStack(spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.reference.start.formatted(.dateTime.weekday(.abbreviated).month().day()))
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.primary)
                Text("\(item.pulse.map { $0.formatted() } ?? "--") · \(item.reference.steps.formatted())")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                if item.isPartial {
                    Text("Band measured under 90% of the day")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                }
            }
            Spacer(minLength: DS.Space.s)
            Text(item.difference.map(StepsData.percent) ?? "--")
                .textStyle(.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(item.difference.map { verdict($0, limit: 0.10).color } ?? DS.Colors.secondary)
            Button("Remove") { removing = references.first { $0.id == item.id } }
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .frame(minHeight: 44)
        }
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
    }

    private func reload() {
        compared = comparisons(references, sleeps: sleepRecords, days: days, maxHeartRate: maxHeartRate, context: context)
            .filter { $0.reference.kind == .appleWatchDay }
            .sorted { $0.reference.start > $1.reference.start }
    }

    /// One total per day: a new entry for the same day replaces the old one.
    private func add() {
        guard let steps = enteredSteps else { return }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        for old in references where old.kindRaw == Steps.Reference.Kind.appleWatchDay.rawValue && old.start == start {
            context.delete(old)
        }
        context.insert(StepReferenceRecord(Steps.Reference(kind: .appleWatchDay, start: start, end: end, steps: steps, createdAt: .now)))
        try? context.save()
        stepsText = ""
        typing = false
    }
}
