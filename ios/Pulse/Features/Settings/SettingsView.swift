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
    /// What the search field holds (DESIGN.md §4b-11).
    @State private var query = ""

    /// The sections, with the words that find them.
    private enum SettingsGroup: CaseIterable {
        case profile, steps, band, cloud, reminders, data, about

        var words: String {
            switch self {
            case .profile: "Profile birth year age sex weight height waist sleep goal max heart rate recalculate metrics"
            case .steps: "Steps daily goal step counting step test 100 Hz motion stream walk"
            case .band: "Band WHOOP name connection firmware battery wear sensor last sync your data starts sync now forget sync log motion check pair Bluetooth"
            case .cloud: "Cloud upload sign in sign out account Claude connector Strava workouts"
            case .reminders: "Reminders notifications bedtime recovery"
            case .data: "Your data export all data backup import delete all band data undo sleep edits"
            case .about: "About widget version metrics algorithm"
            }
        }
    }

    /// Every word typed must appear in the section's words; letter case and accents don't matter.
    private func shows(_ section: SettingsGroup) -> Bool {
        let typed = query.split(whereSeparator: \.isWhitespace)
        return typed.allSatisfy { section.words.localizedStandardContains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                if !SettingsGroup.allCases.contains(where: shows) {
                    Text("No settings match “\(query.trimmingCharacters(in: .whitespaces))”.")
                        .textStyle(.body)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let profile = profiles.first {
                    if shows(.profile) {
                        ProfileSection(profile: profile) {
                            Task { await loader.recompute(context: context) }
                        }
                    }
                    if shows(.steps) { StepsSection(profile: profile) }
                }

                if shows(.band) { bandSection }

                if shows(.cloud) { CloudSettingsView() }

                if shows(.reminders) { remindersSection }

                if shows(.data) { dataSection }

                if shows(.about) { aboutSection }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.xxl)
        }
        // Only the screenshot job sets this (to capture the lower half of the screen).
        .defaultScrollAnchor(LaunchOptions.scroll == "bottom" ? UnitPoint.bottom : nil)
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: DS.Space.s) {
                ScreenHeader(title: "Settings", isSheet: true) {
                    IconButton(systemName: "xmark", label: "Close") { dismiss() }
                }
                SettingsSearchField(text: $query)
                    .padding(.horizontal, DS.Space.side)
                    .padding(.bottom, DS.Space.s)
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
                WearSensorStore.shared.clear()
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

    /// Bedtime and recovery notifications.
    private var remindersSection: some View {
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
    }

    /// Backup, import, and deleting band data.
    private var dataSection: some View {
        SettingsSection("Your data", footer: backupMessage ?? "Export all data is your backup. The file is one JSON file with all your band data, workouts, journal and profile. Use it to move Pulse to a new install. Importing adds to what is here and never deletes anything.") {
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
    }

    /// Version, metrics and the widget link. Seven taps on Version open the sync log.
    private var aboutSection: some View {
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
                ValueRow(label: "Wear sensor", value: WearSensorStore.shared.rowText,
                         emphasized: WearSensorStore.shared.status.label == "No errors")
                if WearSensorStore.shared.status.hasError {
                    Text("The band reports an error from its wear sensor. Heart rate comes from a separate optical sensor.")
                        .textStyle(.caption)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, DS.Space.s)
                }
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
        for record in sleepCorrections { context.delete(record) }
        try? context.save()
        Task { await loader.recompute(context: context) }
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

/// A search field pinned under the Settings header (DESIGN.md §4b-11).
private struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DS.Colors.secondary)
                .accessibilityHidden(true)
            TextField("Search settings", text: $text)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
                .tint(DS.Colors.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Colors.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, DS.Space.m)
        .padding(.trailing, text.isEmpty ? DS.Space.m : 0)
        .frame(minHeight: 44)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).stroke(DS.Colors.border, lineWidth: 1))
    }
}

/// The step goal, whether the band is counting, and the step test (DESIGN.md §4b-8).
private struct StepsSection: View {
    @Bindable var profile: ProfileRecord
    @Environment(BandManager.self) private var band
    @State private var showTest = false

    var body: some View {
        SettingsSection("Steps", footer: "The band counts your steps from its motion, 100 times a second, while you wear it and your iPhone is nearby. It pauses while you're still or asleep, and when its battery is low.") {
            goalRow
            Hairline()
            ValueRow(label: "Step counting", value: countingText, emphasized: band.streamDecision == .stream)
            Hairline()
            Button("Step test") { showTest = true }
                .buttonStyle(.secondaryPill)
                .padding(.top, DS.Space.m)
        }
        .sheet(isPresented: $showTest) { StepTestView() }
    }

    private var countingText: String {
        switch band.streamDecision {
        case .stream: "On"
        case .still: "Paused: you're still"
        case .notWorn: "Paused: band not worn"
        case .lowBattery: "Paused: band battery low"
        case nil: "Waiting for the band"
        }
    }

    /// Daily goal with minus / plus buttons (1,000 steps a click, 2,000 to 30,000).
    private var goalRow: some View {
        HStack(spacing: DS.Space.s) {
            Text("Daily goal")
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
            Spacer(minLength: DS.Space.s)
            Text(profile.stepGoal.formatted())
                .textStyle(.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(DS.Colors.primary)
                .padding(.trailing, DS.Space.xs)
            IconButton(systemName: "minus", label: "Lower step goal") {
                profile.stepGoal = max(2_000, profile.stepGoal - 1_000)
            }
            .disabled(profile.stepGoal <= 2_000)
            IconButton(systemName: "plus", label: "Raise step goal") {
                profile.stepGoal = min(30_000, profile.stepGoal + 1_000)
            }
            .disabled(profile.stepGoal >= 30_000)
        }
        .frame(minHeight: 60)
        .accessibilityElement(children: .contain)
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
        SettingsSection("Profile", footer: "Used only for the formulas: max heart rate is estimated from age (208 − 0.7 × age), sex picks the strain coefficients, the goal is your baseline sleep need, weight and height feed the calorie estimate, and your waist (optional) lets the VO₂ max estimate use your activity too. Stays on this iPhone.") {
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
            pickerRow("Waist") {
                Picker("Waist", selection: Binding(
                    get: { Int(profile.waistCm?.rounded() ?? 0) },
                    set: { profile.waistCm = $0 == 0 ? nil : Double($0) })) {
                    Text("Not set").tag(0)
                    ForEach(Array(50...160), id: \.self) { Text("\($0) cm").tag($0) }
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
