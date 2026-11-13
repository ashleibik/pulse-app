import SwiftUI
import SwiftData
import PulseCore

/// Settings: profile (feeds the formulas), demo data, upcoming connections, about.
/// Mono design (ios/design/DESIGN.md): plain rows separated by hairlines instead of a grouped form.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DemoDataLoader.self) private var loader
    @Query private var profiles: [ProfileRecord]
    @State private var confirmRegenerate = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                if let profile = profiles.first {
                    ProfileSection(profile: profile) {
                        Task { await loader.recompute(context: context) }
                    }
                }

                SettingsSection("Band", footer: "Bluetooth pairing arrives in Phase 5. Until then Pulse shows simulated data run through the real metrics engine.") {
                    ValueRow(label: "Status", value: "Not paired")
                    Hairline()
                    Button("Pair your band") {}
                        .buttonStyle(.secondaryPill)
                        .disabled(true)
                        .padding(.top, DS.Space.m)
                }

                SettingsSection("Demo data") {
                    ValueRow(label: "State", value: stateText)
                    Hairline()
                    Button("Generate a new month") { confirmRegenerate = true }
                        .buttonStyle(.secondaryPill)
                        .disabled(loader.isBusy)
                        .padding(.top, DS.Space.m)
                }

                SettingsSection("Connections") {
                    ValueRow(label: "Apple Health", value: "Phase 6", symbol: "heart.text.square", emphasized: false)
                    Hairline()
                    ValueRow(label: "Strava", value: "Phase 7", symbol: "figure.run", emphasized: false)
                    Hairline()
                    ValueRow(label: "Claude", value: "Phase 8", symbol: "bubble.left.and.text.bubble.right", emphasized: false)
                }

                SettingsSection("About", footer: "Pulse is a personal project for general wellness, not medical advice. Not affiliated with or endorsed by WHOOP, Inc.") {
                    ValueRow(label: "Version", value: appVersion)
                    Hairline()
                    ValueRow(label: "Metrics", value: "Algorithm v\(MetricsEngine.algorithmVersion)")
                    Hairline()
                    ValueRow(label: "Your data", value: "Stored on this iPhone")
                }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Settings", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
        .confirmationDialog("Replace all demo data with a new random month?",
                            isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Generate new data") {
                Task { await loader.regenerate(context: context) }
            }
        }
        .task {
            if profiles.isEmpty { _ = ProfileStore.current(in: context) }
        }
    }

    private var stateText: String {
        switch loader.state {
        case .idle: "Not loaded"
        case .generating: "Generating…"
        case .recalculating: "Recalculating…"
        case .ready: loader.rawDataReady ? "30 days loaded" : "Saving raw data…"
        case .failed(let message): "Error: \(message)"
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// A titled group of rows with an optional small note under it.
private struct SettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: title)
                .padding(.bottom, DS.Space.s)
            content
            if let footer {
                Text(footer)
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Space.m)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Edits the profile in place (@Bindable writes straight to SwiftData, which autosaves).
private struct ProfileSection: View {
    @Bindable var profile: ProfileRecord
    let onRecalculate: () -> Void
    @Environment(DemoDataLoader.self) private var loader
    @State private var changed = false

    private static let currentYear = Calendar.current.component(.year, from: .now)
    private static let years: [Int] = Array(((currentYear - 90)...(currentYear - 13)).reversed())

    var body: some View {
        SettingsSection("Profile", footer: "Used only for the formulas: max heart rate is estimated from age (208 − 0.7 × age), sex picks the strain coefficients, and the goal is your baseline sleep need. Stays on this iPhone.") {
            pickerRow("Birth year") {
                Picker("Birth year", selection: Binding(
                    get: { profile.birthYear ?? 0 },
                    set: { profile.birthYear = $0 == 0 ? nil : $0; changed = true })) {
                    Text("Not set").tag(0)
                    ForEach(Self.years, id: \.self) { Text(String($0)).tag($0) }
                }
            }
            Hairline()
            pickerRow("Sex") {
                Picker("Sex", selection: Binding(
                    get: { profile.sex },
                    set: { profile.sex = $0; changed = true })) {
                    Text("Not specified").tag(BiologicalSex.unspecified)
                    Text("Female").tag(BiologicalSex.female)
                    Text("Male").tag(BiologicalSex.male)
                }
            }
            Hairline()
            sleepGoalRow
            Hairline()
            ValueRow(label: "Max heart rate", value: "\(Int(profile.estimatedMaxHeartRate())) bpm")
            Hairline()
            Button {
                onRecalculate()
                changed = false
            } label: {
                if loader.state == .recalculating {
                    HStack(spacing: DS.Space.s) {
                        ProgressView()
                        Text("Recalculating…")
                    }
                } else {
                    Text("Recalculate my metrics")
                }
            }
            .buttonStyle(.secondaryPill)
            .disabled(!changed || loader.isBusy || !loader.rawDataReady)
            .padding(.top, DS.Space.m)
        }
    }

    /// "Label ........ [menu]". The menu shows the current choice.
    private func pickerRow<P: View>(_ label: String, @ViewBuilder picker: () -> P) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(label)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
            Spacer(minLength: DS.Space.s)
            picker()
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(DS.Colors.primary)
        }
        .frame(minHeight: 52)
    }

    /// Sleep goal with minus / plus buttons (15-minute steps, 6 to 10 hours).
    private var sleepGoalRow: some View {
        HStack(spacing: DS.Space.s) {
            Text("Sleep goal")
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
            Spacer(minLength: DS.Space.s)
            Text(PulseFormat.duration(minutes: profile.sleepGoalMinutes))
                .textStyle(.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(DS.Colors.primary)
                .padding(.trailing, DS.Space.xs)
            IconButton(systemName: "minus", label: "Less sleep goal") {
                profile.sleepGoalMinutes = max(360, profile.sleepGoalMinutes - 15)
                changed = true
            }
            .disabled(profile.sleepGoalMinutes <= 360)
            IconButton(systemName: "plus", label: "More sleep goal") {
                profile.sleepGoalMinutes = min(600, profile.sleepGoalMinutes + 15)
                changed = true
            }
            .disabled(profile.sleepGoalMinutes >= 600)
        }
        .frame(minHeight: 60)
        .accessibilityElement(children: .contain)
    }
}
