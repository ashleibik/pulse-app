import SwiftUI
import SwiftData

/// Settings. Most rows are placeholders that later phases switch on.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DemoDataLoader.self) private var loader
    @State private var confirmRegenerate = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status", value: "Not paired")
                    Button("Pair your band") {}
                        .disabled(true)
                } header: {
                    Text("Band")
                } footer: {
                    Text("Bluetooth pairing arrives in Phase 5. Until then Pulse shows simulated demo data.")
                }

                Section("Demo data") {
                    LabeledContent("State", value: stateText)
                    Button("Generate a new month", role: .destructive) { confirmRegenerate = true }
                        .disabled(loader.state == .generating)
                }

                Section("Connections") {
                    comingSoon("Apple Health", systemImage: "heart.text.square", phase: 6)
                    comingSoon("Strava", systemImage: "figure.run.square.stack", phase: 7)
                    comingSoon("Claude", systemImage: "bubble.left.and.text.bubble.right", phase: 8)
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Data", value: "Stored on this iPhone")
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
