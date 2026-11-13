import SwiftUI
import SwiftData
import PulseCore

/// Pairing and syncing, one step at a time: explain -> search -> connect -> download -> done.
/// The screen only shows what `BandManager.stage` says; all the work happens there.
/// Mono design (ios/design/DESIGN.md).
struct PairingView: View {
    @Environment(BandManager.self) private var band
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// The real band the user tapped, waiting for the "replace demo data" confirmation.
    @State private var chosen: DiscoveredBand?

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
        .confirmationDialog("Replace the demo month with this band's data?",
                            isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                            titleVisibility: .visible) {
            Button("Connect and replace") {
                if let chosen { band.connect(chosen) }
                chosen = nil
            }
        } message: {
            Text("The simulated month is deleted. Your band's history is downloaded instead.")
        }
        .task {
            // Only the screenshot job sets this: run the simulated band without any taps.
            if LaunchOptions.route == "pairing-sim", band.stage == .idle {
                band.startPairing(simulated: true, context: context)
            }
        }
        .onChange(of: band.found) { _, found in
            if LaunchOptions.route == "pairing-sim", band.stage == .searching, let first = found.first {
                band.connect(first)
            }
        }
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
                Hairline()
                ValueRow(label: "Demo month gets replaced", value: "", symbol: "arrow.triangle.2.circlepath")
            }
            Text("A band talks to one app at a time. This part of Pulse has not been tried with a real band yet, so expect rough edges.")
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
                            if found.id == SimulatedBandLink.bandID {
                                band.connect(found)         // nothing is deleted for the simulated band
                            } else {
                                chosen = found
                            }
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
                    band.startPairing(simulated: false, context: context)
                } label: {
                    Text(band.stage == .idle ? "Search for my band" : "Try again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryPill)
                Button {
                    band.startPairing(simulated: true, context: context)
                } label: {
                    Text("Try a simulated band")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryPill)
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

/// The hidden debug screen (Settings > tap the version 7 times): the last packets to and from
/// the band. Kept in memory only, never saved or uploaded.
struct BandLogView: View {
    @Environment(BandManager.self) private var band
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("\(band.log.count) lines · \(band.badFrames) damaged packets")
                    .textStyle(.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .padding(.bottom, DS.Space.s)
                if band.log.isEmpty {
                    Text("Nothing yet. Pair or sync a band and its packets appear here.")
                        .textStyle(.body)
                        .foregroundStyle(DS.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(band.log.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.direction == .toBand ? "→" : "←") \(entry.channel) · \(entry.summary)\(entry.crcOK ? "" : " · bad checksum")")
                            .textStyle(.caption)
                            .foregroundStyle(DS.Colors.primary)
                        Text(entry.hex)
                            .font(.caption2.monospaced())
                            .foregroundStyle(DS.Colors.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, DS.Space.s)
                    .accessibilityElement(children: .combine)
                    Hairline()
                }
            }
            .padding(.horizontal, DS.Space.side)
            .padding(.bottom, DS.Space.xxl)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Band log", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .monoSheet()
    }
}
