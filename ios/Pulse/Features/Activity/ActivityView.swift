import SwiftUI
import SwiftData
import PulseCore

/// Today's strain + the workout history.
struct ActivityView: View {
    @Query(sort: \DaySummaryRecord.date, order: .reverse) private var days: [DaySummaryRecord]
    @Query(sort: \WorkoutRecord.start, order: .reverse) private var workouts: [WorkoutRecord]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    if let today = days.first {
                        strainCard(today)
                    }
                    SectionHeader(title: "Workouts", trailing: "last 14 days")
                        .padding(.top, 8)
                    if recent.isEmpty {
                        Text("No workouts recorded.")
                            .foregroundStyle(Theme.secondaryText)
                            .card()
                    }
                    ForEach(groupedByDay) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(dayTitle(group.day))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                            ForEach(group.items) { workout in
                                NavigationLink(value: workout.id) {
                                    WorkoutRow(workout: workout)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .card()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .navigationTitle("Activity")
            .navigationDestination(for: UUID.self) { id in
                if let workout = workouts.first(where: { $0.id == id }) {
                    WorkoutDetailView(workout: workout)
                }
            }
        }
    }

    private func strainCard(_ today: DaySummaryRecord) -> some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().stroke(Theme.strain.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: today.strain / 21)
                    .stroke(Theme.strain, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(PulseFormat.strain(today.strain))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 110, height: 110)
            VStack(alignment: .leading, spacing: 6) {
                Text("Day strain").font(.headline)
                Text(strainVerdict(today.strain))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Day strain \(PulseFormat.strain(today.strain)) of 21. \(strainVerdict(today.strain))")
    }

    private func strainVerdict(_ strain: Double) -> String {
        switch strain {
        case ..<8: "Light day: easy movement only."
        case ..<14: "Moderate: a solid training day."
        case ..<18: "Strenuous: give yourself time to recover."
        default: "All out: plan an easy day tomorrow."
        }
    }

    private var recent: [WorkoutRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
        return workouts.filter { $0.start >= cutoff }
    }

    struct DayGroup: Identifiable {
        let day: Date
        let items: [WorkoutRecord]
        var id: Date { day }
    }

    private var groupedByDay: [DayGroup] {
        let groups = Dictionary(grouping: recent) { Calendar.current.startOfDay(for: $0.start) }
        return groups.keys.sorted(by: >).map { DayGroup(day: $0, items: groups[$0] ?? []) }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

#Preview {
    ActivityView()
        .modelContainer(PulseStore.previewContainer)
        .preferredColorScheme(.dark)
}
