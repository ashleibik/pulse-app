import SwiftUI
import SwiftData
import PulseCore

/// Settings: profile (feeds the formulas), demo data, upcoming connections, about.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DemoDataLoader.self) private var loader
    @Query private var profiles: [ProfileRecord]
    @State private var confirmRegenerate = false

    var body: some View {
        NavigationStack {
            Form {
                if let profile = profiles.first {
                    ProfileSection(profile: profile) {
                        Task { await loader.recompute(context: context) }
                    }
                }

                Section {
                    LabeledContent("Status", value: "Not paired")
                    Button("Pair your band") {}
                        .disabled(true)
                } header: {
                    Text("Band")
                } footer: {
                    Text("Bluetooth pairing arrives in Phase 5. Until then Pulse shows simulated data run through the real metrics engine.")
                }

                Section("Demo data") {
                    LabeledContent("State", value: stateText)
                    Button("Generate a new month", role: .destructive) { confirmRegenerate = true }
                        .disabled(loader.isBusy)
                }

                Section("Connections") {
                    comingSoon("Apple Health", systemImage: "heart.text.square", phase: 6)
                    comingSoon("Strava", systemImage: "figure.run.square.stack", phase: 7)
                    comingSoon("Claude", systemImage: "bubble.left.and.text.bubble.right", phase: 8)
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Metrics", value: "algorithm v\(MetricsEngine.algorithmVersion)")
                    LabeledContent("Your data", value: "Stored on this iPhone")
                } header: {
                    Text("About")
                } footer: {
                    Text("Pulse is a personal project for general wellness, not medical advice. Not affiliated with or endorsed by WHOOP, Inc.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Replace all demo data with a new random month?",
                                isPresented: $confirmRegenerate, titleVisibility: .visible) {
                Button("Generate new data", role: .destructive) {
                    Task { await loader.regenerate(context: context) }
                }
            }
            .task {
                if profiles.isEmpty { _ = ProfileStore.current(in: context) }
            }
        }
    }

    private func comingSoon(_ title: String, systemImage: String, phase: Int) -> some View {
        LabeledContent {
            Text("Phase \(phase)").foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
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

/// Edits the profile in place (@Bindable writes straight to SwiftData, which autosaves).
private struct ProfileSection: View {
    @Bindable var profile: ProfileRecord
    let onRecalculate: () -> Void
    @Environment(DemoDataLoader.self) private var loader
    @State private var changed = false

    private static let currentYear = Calendar.current.component(.year, from: .now)
    private let years: [Int] = Array(((Self.currentYear - 90)...(Self.currentYear - 13)).reversed())

    var body: some View {
        Section {
            Picker("Birth year", selection: Binding(
                get: { profile.birthYear ?? 0 },
                set: { profile.birthYear = $0 == 0 ? nil : $0; changed = true })) {
                Text("Not set").tag(0)
                ForEach(years, id: \.self) { Text(String($0)).tag($0) }
            }
            Picker("Sex", selection: Binding(
                get: { profile.sex },
                set: { profile.sex = $0; changed = true })) {
                Text("Not specified").tag(BiologicalSex.unspecified)
                Text("Female").tag(BiologicalSex.female)
                Text("Male").tag(BiologicalSex.male)
            }
            Stepper(value: Binding(
                get: { profile.sleepGoalMinutes },
                set: { profile.sleepGoalMinutes = $0; changed = true }), in: 360...600, step: 15) {
                LabeledContent("Sleep goal", value: PulseFormat.duration(minutes: profile.sleepGoalMinutes))
            }
            LabeledContent("Max heart rate", value: "\(Int(profile.estimatedMaxHeartRate())) bpm")
            Button {
                onRecalculate()
                changed = false
            } label: {
                if loader.state == .recalculating {
                    HStack { ProgressView(); Text("Recalculating…") }
                } else {
                    Text("Recalculate my metrics")
                }
            }
            .disabled(!changed || loader.isBusy || !loader.rawDataReady)
        } header: {
            Text("Profile")
        } footer: {
            Text("Used only for the formulas: max heart rate is estimated from age (208 − 0.7 × age), sex picks the strain coefficients, and the goal is your baseline sleep need. Stays on this iPhone.")
        }
    }
}
