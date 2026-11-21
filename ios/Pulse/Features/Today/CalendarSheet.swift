import SwiftUI
import SwiftData
import PulseCore

/// Today's day pill opens this: one month of days, each with its recovery colour (DESIGN.md §4b-12).
struct CalendarSheet: View {
    @Binding var day: Date
    /// The first day with data: nothing before it can be picked.
    let earliest: Date

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DaySummaryRecord.date) private var days: [DaySummaryRecord]
    /// The first day of the month on screen.
    @State private var month: Date

    private var calendar: Calendar { .current }

    init(day: Binding<Date>, earliest: Date) {
        _day = day
        self.earliest = earliest
        let calendar = Calendar.current
        _month = State(initialValue: calendar.dateInterval(of: .month, for: day.wrappedValue)?.start
                       ?? calendar.startOfDay(for: day.wrappedValue))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                monthHeader
                weekdayRow
                grid
                Text("Dots show each day's recovery. Blue: the night is in, recovery is still being learned.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !calendar.isDateInToday(day) {
                    Button("Go to today") { pick(calendar.startOfDay(for: .now)) }
                        .buttonStyle(.secondaryPill)
                }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Calendar", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
    }

    // MARK: - Month

    private var firstMonth: Date { calendar.dateInterval(of: .month, for: earliest)?.start ?? earliest }
    private var thisMonth: Date { calendar.dateInterval(of: .month, for: .now)?.start ?? .now }

    private var monthHeader: some View {
        HStack(spacing: DS.Space.s) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .textStyle(.heading)
                .foregroundStyle(DS.Colors.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DS.Space.s)
            IconButton(systemName: "chevron.left", label: "Previous month") { move(-1) }
                .disabled(month <= firstMonth)
            IconButton(systemName: "chevron.right", label: "Next month") { move(1) }
                .disabled(month >= thisMonth)
        }
    }

    /// "S M T W T F S", starting on the first day of the week where the owner lives.
    private var weekdayRow: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    /// Blank cells before the 1st, then each day of the month.
    private var cells: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let blanks = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        var cells = [Date?](repeating: nil, count: blanks)
        for dayOfMonth in range {
            if let date = calendar.date(byAdding: .day, value: dayOfMonth - 1, to: month) { cells.append(date) }
        }
        return cells
    }

    private var grid: some View {
        var byDay: [Date: DaySummaryRecord] = [:]
        for record in days { byDay[calendar.startOfDay(for: record.date)] = record }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: DS.Space.xs) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                if let date {
                    cell(date, record: byDay[date])
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    private func cell(_ date: Date, record: DaySummaryRecord?) -> some View {
        let selectable = date >= calendar.startOfDay(for: earliest) && date <= calendar.startOfDay(for: .now)
        let selected = calendar.isDate(date, inSameDayAs: day)
        let today = calendar.isDateInToday(date)
        let dot = dotColor(record)
        let number: Color = selected ? DS.Colors.onAccent : (selectable ? DS.Colors.primary : DS.Colors.tertiary)
        return Button { pick(date) } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .textStyle(.body)
                    .monospacedDigit()
                    .foregroundStyle(number)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(selected ? DS.Colors.accent : Color.clear))
                    .overlay(Circle().stroke(today && !selected ? DS.Colors.accent : Color.clear, lineWidth: 1.5))
                Circle()
                    .fill(dot ?? Color.clear)
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityLabel(accessibilityText(date, record: record))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The day's recovery colour, `sleepTint` for a night recorded before recovery is known, nil without data.
    private func dotColor(_ record: DaySummaryRecord?) -> Color? {
        guard let record else { return nil }
        if record.recoveryScore != nil { return DS.Colors.zone(record.zone) }
        if record.sleepMinutes != nil { return DS.Colors.sleepTint }
        return nil
    }

    private func accessibilityText(_ date: Date, record: DaySummaryRecord?) -> String {
        let name = date.formatted(date: .complete, time: .omitted)
        if let score = record?.recoveryScore { return "\(name), recovery \(Int(score.rounded())) percent" }
        if record?.sleepMinutes != nil { return "\(name), night recorded" }
        return "\(name), no data"
    }

    private func move(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(DS.Motion.spring) { month = min(max(next, firstMonth), thisMonth) }
    }

    private func pick(_ date: Date) {
        withAnimation(DS.Motion.spring) { day = calendar.startOfDay(for: date) }
        dismiss()
    }
}

/// Days in a row with a recorded night (DESIGN.md §4b-13). Today wraps it in a button that opens the calendar.
struct StreakCard: View {
    let streak: Streak.Result

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.checkmark")
                Text("STREAK")
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(DS.Colors.tertiary)
            }
            .textStyle(.label)
            .foregroundStyle(DS.Colors.primary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text("\(streak.current)")
                    .textStyle(.title)
                    .foregroundStyle(DS.Colors.primary)
                    .contentTransition(.numericText())
                Text(streak.current == 1 ? "day in a row" : "days in a row")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
            HStack(spacing: 0) {
                ForEach(Array(streak.lastWeek.enumerated()), id: \.offset) { index, counted in
                    let isToday = index == streak.lastWeek.count - 1
                    VStack(spacing: DS.Space.xs) {
                        Circle()
                            .fill(counted ? DS.Colors.accent : Color.clear)
                            .overlay(Circle().stroke(counted || isToday ? DS.Colors.accent : DS.Colors.border, lineWidth: 1.5))
                            .frame(width: 22, height: 22)
                        Text(initial(daysAgo: streak.lastWeek.count - 1 - index))
                            .textStyle(.caption)
                            .foregroundStyle(DS.Colors.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, DS.Space.xs)
            Text("Longest: \(streak.longest == 1 ? "1 day" : "\(streak.longest) days"). A day counts when your band records its night.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .monoCard(padding: DS.Space.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Streak: \(streak.current) \(streak.current == 1 ? "day" : "days") in a row, longest \(streak.longest)")
        .accessibilityHint("Opens the calendar")
    }

    /// "M", "T", ... for a day this many days before today.
    private func initial(daysAgo: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now)) ?? .now
        return date.formatted(.dateTime.weekday(.narrow))
    }
}
