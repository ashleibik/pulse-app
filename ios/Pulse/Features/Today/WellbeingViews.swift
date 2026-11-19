import SwiftUI
import SwiftData
import PulseCore

// Two sheets opened from Today: the stress monitor and the habit journal.
// The numbers come from PulseCore (StressMonitor, JournalInsights), which is tested.

// MARK: - Stress

/// Today's stress signal: now, minutes per level, and hour by hour.
struct StressView: View {
    let day: StressMonitor.Day?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("RIGHT NOW")
                        .textStyle(.label)
                        .foregroundStyle(DS.Colors.secondary)
                    Text(headline)
                        .textStyle(.display)
                        .foregroundStyle(color(day?.current?.level))
                    Text(detail)
                        .textStyle(.body)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                if let day, !day.isEarlyRead {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle(title: "Today")
                            .padding(.bottom, DS.Space.s)
                        ValueRow(label: "Calm", value: PulseFormat.duration(minutes: day.calmMinutes))
                        Hairline()
                        ValueRow(label: "Moderate", value: PulseFormat.duration(minutes: day.mediumMinutes))
                        Hairline()
                        ValueRow(label: "High", value: PulseFormat.duration(minutes: day.highMinutes))
                    }
                    if !day.hours.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            SectionTitle(title: "Hour by hour", trailing: "taller = more stress")
                            DayBarsChart(bars: hourBars(day.hours), domain: 0...3.2, height: 110,
                                         summary: "Stress by hour today")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SectionTitle(title: "How it works")
                    Text("Each hour from 6 AM to 10 PM is compared with your calmest hours today, using your heart rate and heart rate variability. Hours when you move or sleep are left out.")
                        .textStyle(.body)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Caffeine, heat, a big meal or a cold look the same as stress to a heart-rate sensor. Treat this as a hint, not a measurement. Not medical advice.")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Stress", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
    }

    private var headline: String {
        if let level = day?.current?.level { return level.title }
        if day?.isMovingNow == true { return "Moving" }
        return (day?.scoredHours ?? 0) > 0 ? "Too early to tell" : "Can't tell yet"
    }

    private var detail: String {
        if let hour = day?.current {
            return "Your \(hour.start.formatted(.dateTime.hour())) hour, compared with your calmest hours today."
        }
        if day?.isMovingNow == true { return "Pulse doesn't score hours when you're moving, because exercise raises your heart rate too." }
        if let day, day.scoredHours > 0, day.isEarlyRead {
            return "Pulse compares each hour with your calmest hours today, so it needs \(StressMonitor.settledHours) hours. You have \(day.scoredHours) so far."
        }
        return "Pulse needs at least 5 minutes of heart rate in an hour, between 6 AM and 10 PM."
    }

    private func color(_ level: StressLevel?) -> Color {
        switch level {
        case .calm: DS.Colors.accent
        case .medium: DS.Colors.warn
        case .high: DS.Colors.alert
        case nil: DS.Colors.primary
        }
    }

    /// One bar per hour. Calm hours still get a visible bar (score 0 would be invisible).
    private func hourBars(_ hours: [StressMonitor.Hour]) -> [DayBarsChart.Bar] {
        var bars: [DayBarsChart.Bar] = []
        for (index, hour) in hours.enumerated() {
            let label = index % 3 == 0 ? hour.start.formatted(.dateTime.hour()) : ""
            bars.append(DayBarsChart.Bar(id: "\(hour.start.timeIntervalSince1970)", label: label,
                                         value: hour.score.map { $0 + 0.2 }, isHighlighted: index == hours.count - 1,
                                         spokenName: hour.start.formatted(.dateTime.hour())))
        }
        return bars
    }
}

// MARK: - Journal

/// Log a day's habits, and see what each habit does to the next morning's recovery.
struct JournalView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var records: [JournalRecord]
    @Query private var days: [DaySummaryRecord]

    /// 0 = today, 1 = yesterday.
    @State private var daysAgo = 0

    private var day: Date {
        Calendar.current.startOfDay(for: Date.now.addingTimeInterval(Double(-daysAgo) * 86_400))
    }
    private var record: JournalRecord? { records.first { Calendar.current.isDate($0.day, inSameDayAs: day) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                PillPicker(options: [0, 1], label: { $0 == 0 ? "Today" : "Yesterday" }, selection: $daysAgo)

                VStack(alignment: .leading, spacing: DS.Space.m) {
                    SectionTitle(title: "What happened")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s), GridItem(.flexible(), spacing: DS.Space.s)],
                              spacing: DS.Space.s) {
                        ForEach(Habit.allCases, id: \.self) { habit in
                            habitChip(habit)
                        }
                    }
                    Text("Tap what applies. Days with nothing ticked count too, once you have opened them here.")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(title: "What your habits do")
                        .padding(.bottom, DS.Space.s)
                    let impacts = JournalInsights.impacts(entries: entries, days: days.map(\.value), calendar: .current)
                    if impacts.isEmpty {
                        Text("Nothing to report yet. A habit shows up here after at least 3 days with it and 3 days without.")
                            .textStyle(.body)
                            .foregroundStyle(DS.Colors.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(impacts.enumerated()), id: \.element.id) { index, impact in
                        if index > 0 { Hairline() }
                        HStack(alignment: .top, spacing: DS.Space.m) {
                            Image(systemName: impact.habit.symbolName)
                                .font(.title3)
                                .foregroundStyle(impact.delta < 0 ? DS.Colors.alert : DS.Colors.accent)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                Text(impact.habit.title)
                                    .textStyle(.bodyStrong)
                                    .foregroundStyle(DS.Colors.primary)
                                Text(impact.sentence)
                                    .textStyle(.body)
                                    .foregroundStyle(DS.Colors.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, DS.Space.m)
                        .accessibilityElement(children: .combine)
                    }
                    Text("A simple average, not proof: habits often come together, and a few days is a small sample.")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, DS.Space.m)
                }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Journal", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
        // Opening a day counts as logging it, even with nothing ticked ("none of these happened").
        .task(id: daysAgo) { ensureRecord() }
    }

    private var entries: [Date: Set<Habit>] {
        var result: [Date: Set<Habit>] = [:]
        for record in records { result[record.day] = record.habits }
        return result
    }

    private func habitChip(_ habit: Habit) -> some View {
        let isOn = record?.habits.contains(habit) ?? false
        return Button {
            toggle(habit)
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: habit.symbolName)
                    .accessibilityHidden(true)
                Text(habit.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .textStyle(.caption)
            .foregroundStyle(isOn ? DS.Colors.onAccent : DS.Colors.primary)
            .padding(.horizontal, DS.Space.m)
            .frame(minHeight: 48)
            .background(isOn ? DS.Colors.accent : DS.Colors.border, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isOn)
    }

    private func ensureRecord() {
        guard record == nil else { return }
        context.insert(JournalRecord(day: day, habits: []))
        try? context.save()
    }

    private func toggle(_ habit: Habit) {
        ensureRecord()
        guard let record else { return }
        var habits = record.habits
        if habits.contains(habit) { habits.remove(habit) } else { habits.insert(habit) }
        record.habits = habits
        try? context.save()
    }
}

// MARK: - Report

/// The week or month in a few lines (PulseCore's PeriodReport).
struct ReportView: View {
    let period: Int
    @Query private var days: [DaySummaryRecord]
    @Query private var sleeps: [SleepRecord]
    @Query private var workouts: [WorkoutRecord]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let report = PeriodReport.make(days: days.map(\.value), sleeps: sleeps.map(\.value),
                                       workouts: workouts.map(\.value), period: period, calendar: .current)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if report.lines.isEmpty {
                    Text("Not enough data for a report yet.")
                        .textStyle(.body)
                        .foregroundStyle(DS.Colors.secondary)
                }
                ForEach(Array(report.lines.enumerated()), id: \.element.id) { index, line in
                    if index > 0 { Hairline() }
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.label)
                                .textStyle(.body)
                                .foregroundStyle(DS.Colors.primary)
                            Text(line.note)
                                .textStyle(.caption)
                                .foregroundStyle(DS.Colors.secondary)
                        }
                        Spacer(minLength: DS.Space.s)
                        Text(line.value)
                            .textStyle(.title)
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.primary)
                    }
                    .padding(.vertical, DS.Space.m)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: period == 7 ? "This week" : "This month", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
    }
}
