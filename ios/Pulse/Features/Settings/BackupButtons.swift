import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PulseCore

/// Settings > Your data: "Export all data" and "Import data". The file carries raw band data, so it
/// is what moves Pulse to a new install (for example SideStore) without losing anything.
struct BackupButtons: View {
    /// What happened last. Shown under the section.
    @Binding var message: String?

    @Environment(\.modelContext) private var context
    @Environment(DataLoader.self) private var loader
    @Environment(BandManager.self) private var band
    @State private var exportURL: URL?
    @State private var isWorking = false
    @State private var choosingFile = false
    /// A checked file waiting for the user's confirmation.
    @State private var pending: Pending?

    private struct Pending {
        let url: URL
        let summary: PulseBackup.Summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let exportURL {
                ShareLink(item: exportURL) { Text("Save the backup file") }
                    .buttonStyle(.primaryPill)
            } else {
                Button("Export all data") { export() }
                    .buttonStyle(.secondaryPill)
                    .disabled(isWorking)
            }
            Button("Import data") { choosingFile = true }
                .buttonStyle(.secondaryPill)
                .disabled(isWorking || band.isBusy || loader.isBusy)
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): check(url)
            case .failure(let error): message = error.localizedDescription
            }
        }
        .confirmationDialog("Import this backup?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { file in
            Button("Import") { run(file.url) }
            Button("Cancel", role: .cancel) { try? FileManager.default.removeItem(at: file.url) }
        } message: { file in
            Text(describe(file.summary))
        }
        .onDisappear { removeExportFile() }
    }

    // MARK: - Export

    private func export() {
        isWorking = true
        message = "Preparing your backup…"
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let header = PulseBackup.Header(exportedAt: .now, appVersion: version, dataStart: BandDataCutoff.date,
                                        profile: ProfileStore.current(in: context).backup)
        let container = context.container
        let wearSensor = WearSensorStore.shared.observations
        Task {
            do {
                exportURL = try await BackupStore(modelContainer: container).export(header: header, wearSensor: wearSensor)
                message = "Backup ready. Save it somewhere safe, such as Files or iCloud Drive. It contains your health data."
            } catch {
                message = "The backup could not be written: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    private func removeExportFile() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
    }

    // MARK: - Import

    /// Copies the chosen file, then reads it completely. Nothing is changed yet.
    private func check(_ picked: URL) {
        isWorking = true
        message = "Checking the backup…"
        Task {
            do {
                let copy = try await Self.copyToTemporaryFolder(picked)
                do {
                    let summary = try await Task.detached { try BackupFile.summary(of: copy) }.value
                    pending = Pending(url: copy, summary: summary)
                    message = nil
                } catch {
                    try? FileManager.default.removeItem(at: copy)
                    throw error
                }
            } catch {
                message = error.localizedDescription
            }
            isWorking = false
        }
    }

    private static func copyToTemporaryFolder(_ picked: URL) async throws -> URL {
        try await Task.detached {
            let allowed = picked.startAccessingSecurityScopedResource()
            defer { if allowed { picked.stopAccessingSecurityScopedResource() } }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-import-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: picked, to: copy)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: copy.path)
            return copy
        }.value
    }

    private func run(_ url: URL) {
        pending = nil
        isWorking = true
        message = "Importing… Keep Pulse open."
        let container = context.container
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let header = try await Task.detached { try BackupFile.header(of: url) }.value
                let dataStart = PulseBackup.effectiveDataStart(file: header.dataStart, local: BandDataCutoff.date)
                // First, so imported days are never treated as the previous owner's, even if Pulse
                // is closed halfway through.
                if let dataStart { BandDataCutoff.set(dataStart) }
                let result = try await BackupStore(modelContainer: container).importFile(at: url, dataStart: dataStart)
                if let profile = header.profile { ProfileStore.current(in: context).restore(profile) }
                try? context.save()
                await loader.recompute(context: context, detection: .all)
                loader.dataChanged()
                message = "Imported \(PulseFormat.duration(minutes: result.minutesAdded)) of new band data, \(result.workoutsAdded) workouts and \(result.journalDays) journal days."
            } catch {
                message = "Nothing more was imported: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    private func describe(_ summary: PulseBackup.Summary) -> String {
        let span: String
        if let first = summary.firstMinute, let last = summary.lastMinute {
            span = "\(first.formatted(date: .abbreviated, time: .omitted)) to \(last.formatted(date: .abbreviated, time: .omitted))"
        } else {
            span = "no band data"
        }
        return "From \(summary.exportedAt.formatted(date: .abbreviated, time: .shortened)): \(span), \(summary.workouts) workouts, \(summary.journalDays) journal days. It is added to what is on this iPhone, and your profile is replaced."
    }
}
