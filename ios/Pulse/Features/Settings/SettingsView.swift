import SwiftUI
import SwiftData
import PulseCore

/// Settings: profile (feeds the formulas), demo data, upcoming connections, about.
/// Mono design (ios/design/DESIGN.md): plain rows separated by hairlines instead of a grouped form.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DataLoader.self) private var loader
    @Environment(BandManager.self) private var band
    @Environment(HealthExporter.self) private var health
    @Query private var profiles: [ProfileRecord]
    @Query private var bands: [BandRecord]
    @Query private var sleepCorrections: [SleepCorrectionRecord]
    @State private var showMotionCheck = false
    @State private var remindersOn = UserDefaults.standard.bool(forKey: "remindersEnabled")
    /// What the last backup export or import did.
    @State private var backupMessage: String?
    @State private var confirmForget = false
    @State private var confirmDelete = false
    @State private var showPairing = false
    @State private var showLog = false
    /// "Your data starts" (the band was bought used). A later day waits for confirmation.
    @State private var dataStart = BandDataCutoff.date ?? .now
    @State private var pendingDataStart: Date?
    /// Tapping the version row 7 times also opens the sync log.
    @State private var versionTaps = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                if let profile = profiles.first {
                    ProfileSection(profile: profile) {
                        Task { await loader.recompute(context: context) }
                    }
                }

                bandSection

                SettingsSection("Apple Health", footer: healthFooter) {
                    ValueRow(label: "Export", value: health.signing == .missing ? "Not available" : (health.isEnabled ? "On" : "Off"),
                             symbol: "heart.text.square", emphasized: health.isEnabled && health.signing != .missing)
                    Hairline()
                    ValueRow(label: "Last written", value: lastWrittenText)
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
                    Toggle(isOn: Binding(get: { health.writesSleepStages },
                                         set: { on in Task { await health.setWritesSleepStages(on, context: context) } })) {
                        Text("Write sleep stages to Apple Health (estimated)")
                            .textStyle(.body)
                            .foregroundStyle(DS.Colors.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tint(DS.Colors.accent)
                    .disabled(health.status == .working || !health.isAvailable)
                    .padding(.top, DS.Space.m)
                    Button("Copy Apple Health log") { UIPasteboard.general.string = health.traceLines.joined(separator: "\n") }
                        .buttonStyle(.secondaryPill)
                        .disabled(health.traceLines.isEmpty)
                        .padding(.top, DS.Space.s)
                }

                CloudSettingsView()

                SettingsSection("Reminders", footer: "A nudge 30 minutes before tonight's bedtime, and your recovery score after a sync. Created on this iPhone; nothing is sent anywhere.") {
                    ValueRow(label: "Bedtime and recovery", value: remindersOn ? "On" : "Off", symbol: "bell",
                             emphasized: remindersOn)
                    Hairline()
                    Button(remindersOn ? "Turn off" : "Turn on") {
                        Task {
                            if remindersOn {
                                Notifier.disable()
                                remindersOn = false
                            } else {
                                remindersOn = await Notifier.enable()
                                Notifier.refresh(context: context)
                            }
                        }
                    }
                    .buttonStyle(.secondaryPill)
                    .padding(.top, DS.Space.m)
                }

                SettingsSection("Your data", footer: backupMessage ?? (health.signing == .missing ? "This is your main backup, because Apple Health isn't available on this install. " : "") + "The backup is one JSON file with all your band data, workouts, journal and profile. Use it to move Pulse to a new install. Importing adds to what is here and never deletes anything.") {
                    BackupButtons(message: $backupMessage)
                    if !sleepCorrections.isEmpty {
                        Button("Undo my sleep edits (\(sleepCorrections.count))") { undoSleepEdits() }
                            .buttonStyle(.secondaryPill)
                            .disabled(loader.isBusy)
                            .padding(.top, DS.Space.s)
                    }
                    Button("Delete all band data") { confirmDelete = true }
                        .buttonStyle(.secondaryPill)
                        .disabled(band.isBusy || loader.isBusy)
                        .padding(.top, DS.Space.s)
                }

                SettingsSection("About", footer: "Pulse is a personal project for general wellness, not medical advice. Not affiliated with or endorsed by WHOOP, Inc.") {
                    // Whether the home screen widget can see the app's data (App Group kept when signing).
                    ValueRow(label: "Widget link", value: WidgetSnapshot.appGroup ?? "Not available",
                             symbol: "square.grid.2x2")
                    Hairline()
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
        .confirmationDialog("Delete band data from before this day?",
                            isPresented: Binding(get: { pendingDataStart != nil }, set: { if !$0 { pendingDataStart = nil } }),
                            titleVisibility: .visible) {
            Button("Delete older data", role: .destructive) {
                if let day = pendingDataStart { applyDataStart(day) }
                pendingDataStart = nil
            }
            Button("Cancel", role: .cancel) {
                dataStart = BandDataCutoff.date ?? .now
                pendingDataStart = nil
            }
        } message: {
            Text("Records from before this day are deleted from this iPhone and never downloaded again.")
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
        .sheet(isPresented: $showMotionCheck) { MotionCheckView() }
        .task {
            if profiles.isEmpty { _ = ProfileStore.current(in: context) }
        }
    }

    /// "Nov 18, 5:43 PM · 1,204 samples", or dashes before the first write.
    private var lastWrittenText: String {
        guard let date = health.lastWrittenAt else { return "--" }
        return "\(date.formatted(date: .abbreviated, time: .shortened)) · \(health.lastWrittenSamples.formatted()) samples"
    }

    /// What happened last, or what the export does.
    private var healthFooter: String {
        if health.signing == .missing { return HealthAccess.missingMessage }
        switch health.status {
        case .working: "Exporting…"
        case .done(let message): message
        case .failed(let message): message
        case .idle: "Backs up sleep (asleep and awake), heart rate, resting heart rate, HRV and workouts. Sleep stages are estimates from heart rate and motion, so they stay in Pulse unless you turn them on. Steps and calories are never written. Pulse reads Apple Health only to avoid duplicates."
        }
    }

    /// Paired: what we know about the band + sync / forget. Not paired: the way in.
    @ViewBuilder
    private var bandSection: some View {
        if let record = bands.first {
            SettingsSection("Band", footer: "Pulse stays connected and pulls new data by itself every few minutes. These tools are for troubleshooting. Pulse talks to the band directly over Bluetooth and never to WHOOP's servers.") {
                ValueRow(label: "Name", value: record.name)
                Hairline()
                ValueRow(label: "Connection", value: band.statusLine, emphasized: band.isConnected)
                Hairline()
                ValueRow(label: "Firmware", value: record.firmwareVersion ?? "Unknown",
                         emphasized: record.firmwareVersion != nil)
                Hairline()
                ValueRow(label: "Battery", value: record.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "Unknown",
                         emphasized: record.batteryPercent != nil)
                Hairline()
                ValueRow(label: "Last sync",
                         value: record.lastHistorySyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never",
                         emphasized: record.lastHistorySyncAt != nil)
                Hairline()
                dataStartRow
                Hairline()
                HStack(spacing: DS.Space.s) {
                    // Works in place: the Connection row above shows how it goes.
                    Button("Sync now") { band.syncNow(context: context) }
                        .buttonStyle(.secondaryPill)
                        .disabled(band.stage == .syncing)
                    Button("Forget") { confirmForget = true }
                        .buttonStyle(.secondaryPill)
                        .disabled(band.stage == .syncing)
                }
                .padding(.top, DS.Space.m)
                // One manual sync below the low-battery threshold. Automatic syncs still pause.
                if case .paused = band.stage {
                    Button("Sync anyway") { band.syncNow(context: context, overrideLowBattery: true) }
                        .buttonStyle(.secondaryPill)
                        .padding(.top, DS.Space.s)
                }
                // Every packet of the last sync, exportable as a text file (for debugging).
                Button("Sync log") { showLog = true }
                    .buttonStyle(.secondaryPill)
                    .padding(.top, DS.Space.s)
                // Do the band's motion readings change when you move?
                Button("Motion check") { showMotionCheck = true }
                    .buttonStyle(.secondaryPill)
                    .padding(.top, DS.Space.s)
            }
        } else {
            SettingsSection("Band", footer: "Pulse only shows what your band recorded. Pair it to get started.") {
                ValueRow(label: "Status", value: "Not paired", emphasized: false)
                Hairline()
                Button("Pair your band") { showPairing = true }
                    .buttonStyle(.secondaryPill)
                    .padding(.top, DS.Space.m)
            }
        }
    }

    /// Back to what Pulse detected by itself.
    private func undoSleepEdits() {
        let changed = sleepCorrections.map(\.value)
        for record in sleepCorrections { context.delete(record) }
        try? context.save()
        guard let from = changed.map(\.detectedStart).min(), let to = changed.map(\.detectedEnd).max() else { return }
        Task {
            await loader.recompute(context: context)
            await health.sleepChanged(from: from, to: to, context: context)
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// The day your own data starts. The band was bought used: anything older is the previous
    /// owner's and is dropped. Moving it later deletes data (after a confirmation); earlier does not
    /// bring deleted data back.
    private var dataStartRow: some View {
        HStack(spacing: DS.Space.m) {
            Text("Your data starts")
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
            Spacer(minLength: DS.Space.s)
            DatePicker("Your data starts", selection: $dataStart, in: ...Date.now, displayedComponents: .date)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .disabled(band.isBusy || loader.isBusy)
        }
        .frame(minHeight: 52)
        .onChange(of: dataStart) { _, day in
            let current = BandDataCutoff.date ?? .distantPast
            let picked = Calendar.current.startOfDay(for: day)
            guard picked != current else { return }
            if picked > current { pendingDataStart = picked } else { applyDataStart(picked) }
        }
    }

    private func applyDataStart(_ day: Date) {
        Task { await loader.setDataStart(day, context: context) }
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
    @Environment(DataLoader.self) private var loader
    @State private var changed = false

    private static let currentYear = Calendar.current.component(.year, from: .now)
    private static let years: [Int] = Array(((currentYear - 90)...(currentYear - 13)).reversed())

    var body: some View {
        SettingsSection("Profile", footer: "Used only for the formulas: max heart rate is estimated from age (208 − 0.7 × age), sex picks the strain coefficients, the goal is your baseline sleep need, and weight and height feed the calorie estimate. Stays on this iPhone.") {
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
            pickerRow("Weight") {
                Picker("Weight", selection: Binding(
                    get: { Int(profile.weightKg?.rounded() ?? 0) },
                    set: { profile.weightKg = $0 == 0 ? nil : Double($0) })) {
                    Text("Not set").tag(0)
                    ForEach(Array(30...250), id: \.self) { Text("\($0) kg").tag($0) }
                }
            }
            Hairline()
            pickerRow("Height") {
                Picker("Height", selection: Binding(
                    get: { Int(profile.heightCm?.rounded() ?? 0) },
                    set: { profile.heightCm = $0 == 0 ? nil : Double($0) })) {
                    Text("Not set").tag(0)
                    ForEach(Array(120...230), id: \.self) { Text("\($0) cm").tag($0) }
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
