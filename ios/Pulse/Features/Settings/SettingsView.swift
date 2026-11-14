import SwiftUI
import SwiftData
import PulseCore

/// Settings: profile (feeds the formulas), demo data, upcoming connections, about.
/// Mono design (ios/design/DESIGN.md): plain rows separated by hairlines instead of a grouped form.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DemoDataLoader.self) private var loader
    @Environment(BandManager.self) private var band
    @Environment(HealthExporter.self) private var health
    @Query private var profiles: [ProfileRecord]
    @Query private var bands: [BandRecord]
    @AppStorage("appearance") private var appearance = "dark"
    @State private var confirmRegenerate = false
    @State private var confirmForget = false
    @State private var confirmDelete = false
    @State private var showPairing = false
    @State private var showLog = false
    /// Tapping the version row 7 times opens the band log (a hidden debug screen).
    @State private var versionTaps = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                if let profile = profiles.first {
                    ProfileSection(profile: profile) {
                        Task { await loader.recompute(context: context) }
                    }
                }

                SettingsSection("Appearance") {
                    PillPicker(options: ["dark", "light", "system"],
                               label: { $0 == "system" ? "Match iPhone" : $0.capitalized },
                               selection: $appearance)
                }

                bandSection

                SettingsSection("Demo data") {
                    ValueRow(label: "State", value: stateText)
                    Hairline()
                    Button("Generate a new month") { confirmRegenerate = true }
                        .buttonStyle(.secondaryPill)
                        .disabled(loader.isBusy)
                        .padding(.top, DS.Space.m)
                }

                SettingsSection("Apple Health", footer: healthFooter) {
                    ValueRow(label: "Export", value: health.isEnabled ? "On" : "Off",
                             symbol: "heart.text.square", emphasized: health.isEnabled)
                    Hairline()
                    HStack(spacing: DS.Space.s) {
                        Button(health.isEnabled ? "Turn off" : "Turn on") {
                            if health.isEnabled {
                                health.disable()
                            } else {
                                Task { await health.enable(context: context) }
                            }
                        }
                        .buttonStyle(.secondaryPill)
                        if health.isEnabled {
                            Button("Export all") {
                                Task { await health.export(context: context, everything: true) }
                            }
                            .buttonStyle(.secondaryPill)
                        }
                    }
                    .disabled(health.status == .working || !health.isAvailable)
                    .padding(.top, DS.Space.m)
                }

                CloudSettingsView()

                if DataSourceSetting.current == .band {
                    SettingsSection("Your data", footer: "Deletes every heartbeat, night and workout stored on this iPhone. Your band stays paired. Anything you uploaded to your own cloud stays there.") {
                        Button("Delete all band data") { confirmDelete = true }
                            .buttonStyle(.secondaryPill)
                            .disabled(band.isBusy || loader.isBusy)
                    }
                }

                SettingsSection("About", footer: "Pulse is a personal project for general wellness, not medical advice. Not affiliated with or endorsed by WHOOP, Inc.") {
                    ValueRow(label: "Version", value: appVersion)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            versionTaps += 1
                            if versionTaps >= 7 {
                                versionTaps = 0
                                showLog = true
                            }
                        }
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
        // Only the screenshot job sets this (to capture the lower half of the screen).
        .defaultScrollAnchor(LaunchOptions.scroll == "bottom" ? UnitPoint.bottom : nil)
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
        .confirmationDialog("Forget this band?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget band") { band.forget(context: context) }
        } message: {
            Text("The data already downloaded stays on this iPhone.")
        }
        .confirmationDialog("Delete all band data from this iPhone?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete everything") {
                try? PulseStore.deleteAllHealthData(in: context)
                loader.dataChanged()
            }
        } message: {
            Text("This can't be undone. Data the band already handed over is not on the band anymore.")
        }
        .sheet(isPresented: $showPairing) { PairingView() }
        .sheet(isPresented: $showLog) { BandLogView() }
        .task {
            if profiles.isEmpty { _ = ProfileStore.current(in: context) }
        }
    }

    /// What happened last, or what the export does.
    private var healthFooter: String {
        switch health.status {
        case .working: "Exporting…"
        case .done(let message): message
        case .failed(let message): message
        case .idle: "Saves sleep, resting heart rate and workouts to Apple Health. Pulse never reads from Apple Health, and demo data is never written there."
        }
    }

    /// Paired: what we know about the band + sync / forget. Not paired: the way in.
    @ViewBuilder
    private var bandSection: some View {
        if let record = bands.first {
            SettingsSection("Band", footer: "Pulse talks to the band directly over Bluetooth and never to WHOOP's servers.") {
                ValueRow(label: "Name", value: record.name)
                Hairline()
                ValueRow(label: "Battery", value: record.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "Unknown",
                         emphasized: record.batteryPercent != nil)
                Hairline()
                ValueRow(label: "Last sync",
                         value: record.lastHistorySyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never",
                         emphasized: record.lastHistorySyncAt != nil)
                Hairline()
                HStack(spacing: DS.Space.s) {
                    Button("Sync now") {
                        band.syncNow(context: context)
                        showPairing = true
                    }
                    .buttonStyle(.secondaryPill)
                    .disabled(band.isBusy)
                    Button("Forget") { confirmForget = true }
                        .buttonStyle(.secondaryPill)
                        .disabled(band.isBusy)
                }
                .padding(.top, DS.Space.m)
            }
        } else {
            SettingsSection("Band", footer: "Until a band is paired, Pulse shows a simulated month run through the real metrics engine.") {
                ValueRow(label: "Status", value: "Not paired", emphasized: false)
                Hairline()
                Button("Pair your band") { showPairing = true }
                    .buttonStyle(.secondaryPill)
                    .padding(.top, DS.Space.m)
            }
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
