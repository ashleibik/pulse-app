import SwiftUI
import SwiftData
import PulseCore

/// Pairing and syncing, one step at a time: explain -> search -> connect -> download -> done.
/// The screen only shows what `BandManager.stage` says; all the work happens there.
/// Mono design (ios/design/DESIGN.md).
struct PairingView: View {
    @State private var showLog = false
    @Environment(BandManager.self) private var band
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// The real band the user tapped, waiting for the "replace demo data" confirmation.

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.side)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.xl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Your band", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") {
                    if band.isBusy { band.cancel() }
                    dismiss()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .monoSheet()
        .animation(DS.Motion.spring, value: band.stage)
        .sheet(isPresented: $showLog) { BandLogView() }
        .sensoryFeedback(.success, trigger: band.stage == .upToDate)
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch band.stage {
        case .idle:
            step(symbol: "dot.radiowaves.left.and.right", title: "Bring your\nband close",
                 text: "Pulse reads your band directly over Bluetooth. Nothing is sent to WHOOP or anywhere else.")
            VStack(alignment: .leading, spacing: 0) {
                ValueRow(label: "Band charged and nearby", value: "", symbol: "battery.75percent")
                Hairline()
                ValueRow(label: "Official WHOOP app closed", value: "", symbol: "xmark.app")
            }
            Text("A band talks to one app at a time. The first sync can take several minutes if the band holds a lot of old data: keep the app open and the band close.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .unavailable(let message):
            step(symbol: "exclamationmark.triangle", title: "Bluetooth isn't\navailable", text: message)

        case .searching:
            HStack(spacing: DS.Space.m) {
                ProgressView()
                Text("Searching")
                    .textStyle(.display)
                    .foregroundStyle(DS.Colors.primary)
            }
            if band.found.isEmpty {
                Text("If your band doesn't show up, move closer and make sure the official app is closed.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(band.found.enumerated()), id: \.element.id) { index, found in
                        if index > 0 { Hairline() }
                        Button {
                            band.connect(found)
                        } label: {
                            foundRow(found)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }

        case .connecting:
            HStack(spacing: DS.Space.m) {
                ProgressView()
                Text("Connecting")
                    .textStyle(.display)
                    .foregroundStyle(DS.Colors.primary)
            }
            Text("Keep the band close.")
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)

        case .syncing:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Downloading your band's history")
                }
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                HeroNumber(value: Double(band.recordsSaved) / 60) { PulseFormat.duration(minutes: Int($0.rounded())) }
                Text("of data saved so far.")
                    .textStyle(.body)
                    .foregroundStyle(DS.Colors.secondary)
            }
            .accessibilityElement(children: .combine)
            bandFacts
            Text("Keep Pulse open and the band close. A first download can take several minutes.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .upToDate:
            step(symbol: "checkmark.circle", title: "All synced",
                 text: "\(PulseFormat.duration(minutes: band.recordsSaved / 60)) of data saved. Your numbers are up to date.")
            bandFacts

        case .failed(let message):
            step(symbol: "exclamationmark.triangle", title: "That didn't\nwork", text: message)
        }
    }

    /// Thin icon, heavy headline, one paragraph.
    private func step(symbol: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(DS.Colors.primary)
                .accessibilityHidden(true)
            Text(title)
                .textStyle(.display)
                .foregroundStyle(DS.Colors.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func foundRow(_ found: DiscoveredBand) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "applewatch.side.right")
                .font(.title3)
                .foregroundStyle(DS.Colors.primary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(found.name)
                    .textStyle(.bodyStrong)
                    .foregroundStyle(DS.Colors.primary)
                Text(found.distanceWord)
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
            }
            Spacer(minLength: DS.Space.s)
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(DS.Colors.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, DS.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Connects to this band")
    }

    /// What the band told us about itself. Rows appear as the answers arrive.
    @ViewBuilder
    private var bandFacts: some View {
        VStack(alignment: .leading, spacing: 0) {
            ValueRow(label: "Battery",
                     value: band.info.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "Asking…",
                     emphasized: band.info.batteryPercent != nil)
            if band.info.clockWasSet {
                Hairline()
                ValueRow(label: "Band clock", value: "Corrected")
            }
            if band.badFrames > 0 {
                Hairline()
                ValueRow(label: "Damaged packets ignored", value: "\(band.badFrames)")
            }
        }
    }

    // MARK: - Buttons (pinned at the bottom)

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: DS.Space.s) {
            switch band.stage {
            case .idle, .unavailable, .failed:
                Button {
                    band.startPairing(context: context)
                } label: {
                    Text(band.stage == .idle ? "Search for my band" : "Try again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryPill)
                if case .failed = band.stage {
                    Button {
                        showLog = true
                    } label: {
                        Text("See the sync log").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondaryPill)
                }
            case .upToDate:
                Button {
                    dismiss()
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryPill)
            case .searching, .connecting, .syncing:
                Button {
                    band.cancel()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryPill)
            }
        }
        .padding(.horizontal, DS.Space.side)
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.m)
        .background(DS.Colors.sheet)
    }
}

/// The sync log (Settings > Band > Sync log, or after a failed sync): every notification, frame,
/// command and batch of the last sync, with an export as a text file. Memory only: nothing is
/// saved or uploaded unless you share the file yourself.
struct BandLogView: View {
    @Environment(BandManager.self) private var band
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var total = 0
    @State private var exportURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("\(total) lines · \(band.recordsSaved) records saved in \(band.batchesSaved) batches · \(band.badFrames) damaged frames")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                HStack(spacing: DS.Space.s) {
                    if let exportURL {
                        ShareLink(item: exportURL) { Text("Share log file") }
                            .buttonStyle(.primaryPill)
                    } else {
                        Button("Export as text file") { exportURL = band.exportTrace() }
                            .buttonStyle(.primaryPill)
                            .disabled(total == 0)
                    }
                    Button("Refresh") { reload() }
                        .buttonStyle(.secondaryPill)
                }
                Text("The log contains raw band data (your heart rate). It stays on this iPhone unless you share it.")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if lines.isEmpty {
                    Text("Nothing yet. Sync your band and every packet appears here.")
                        .textStyle(.body)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Newest first (last 300 lines; the export has everything)")
                    .textStyle(.label)
                    .foregroundStyle(DS.Colors.secondary)
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(isProblem(line) ? DS.Colors.alert : DS.Colors.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Sync log", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
        .onAppear { reload() }
    }

    private func reload() {
        lines = band.trace.last(300).reversed()
        total = band.trace.total
        exportURL = nil
    }

    private func isProblem(_ line: String) -> Bool {
        line.contains("FAIL") || line.contains("WATCHDOG") || line.contains("RESYNC") || line.contains("Disconnected")
    }
}
