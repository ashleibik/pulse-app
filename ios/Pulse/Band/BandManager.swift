import Foundation
import Observation
import SwiftData
import PulseCore

/// Pairing and syncing, as the screens see it.
///
/// It connects three things that each do one job:
///   BandLink (bytes in / out)  <->  BandSession (the protocol, pure + tested)  <->  the database
///
/// The safety rule from Phase 5a still holds here: a history batch is acknowledged to the band
/// only after `BandImporter.save` has returned, i.e. after the data is on disk.
@MainActor
@Observable
final class BandManager {

    enum Stage: Equatable {
        case idle
        /// Bluetooth can't be used right now. The text says why and what to do.
        case unavailable(String)
        case searching
        case connecting
        case syncing
        case upToDate
        case failed(String)
    }

    private(set) var stage: Stage = .idle
    private(set) var found: [DiscoveredBand] = []
    private(set) var info = BandSession.Info()
    /// Seconds of band data saved in this sync (the band records about one sample per second).
    private(set) var recordsSaved = 0
    /// Newest last. Only kept in memory, capped, and only shown on the hidden debug screen.
    private(set) var log: [BandSession.LogEntry] = []
    private(set) var badFrames = 0

    /// Called after new data was saved and the metrics were recalculated.
    var onDataChanged: (() -> Void)?

    private var link: BandLink?
    private var session: BandSession?
    private var context: ModelContext?
    private var target: DiscoveredBand?
    private var usingSimulatedBand = false
    private static let logLimit = 400

    var isBusy: Bool { stage == .searching || stage == .connecting || stage == .syncing }

    // MARK: - What the screens call

    /// Start looking for a band. `simulated: true` uses the pretend band (no Bluetooth needed).
    func startPairing(simulated: Bool, context: ModelContext) {
        prepare(simulated: simulated, context: context)
        found = []
        stage = .searching
        link?.startScanning()
    }

    func connect(_ band: DiscoveredBand) {
        target = band
        stage = .connecting
        link?.stopScanning()
        link?.connect(to: band.id)
    }

    /// Sync again with the band that is already paired.
    func syncNow(context: ModelContext) {
        guard !isBusy, let record = Self.pairedBand(in: context) else { return }
        prepare(simulated: record.peripheralID == SimulatedBandLink.bandID, context: context)
        target = DiscoveredBand(id: record.peripheralID, name: record.name, signal: 0)
        stage = .connecting
        link?.connect(to: record.peripheralID)
    }

    func cancel() {
        link?.stopScanning()
        link?.disconnect()
        session = nil
        if isBusy { stage = .idle }
    }

    /// Forget the band. The data that was already downloaded stays on the phone.
    func forget(context: ModelContext) {
        cancel()
        for record in (try? context.fetch(FetchDescriptor<BandRecord>())) ?? [] { context.delete(record) }
        try? context.save()
        info = BandSession.Info()
        stage = .idle
    }

    static func pairedBand(in context: ModelContext) -> BandRecord? {
        try? context.fetch(FetchDescriptor<BandRecord>()).first
    }

    // MARK: - Link events

    private func prepare(simulated: Bool, context: ModelContext) {
        link?.disconnect()
        self.context = context
        usingSimulatedBand = simulated
        session = nil
        recordsSaved = 0
        badFrames = 0
        log = []
        let newLink: BandLink
        if simulated {
            // The pretend band "recorded" the last two days that are already stored.
            newLink = SimulatedBandLink { [weak self] in
                guard let context = self?.context else { return [] }
                return PulseStore.minutes(from: Date.now.addingTimeInterval(-48 * 3600), to: .now, in: context)
            }
        } else {
            newLink = BluetoothBandLink()
        }
        newLink.onEvent = { [weak self] event in
            // BandLink promises the main thread.
            MainActor.assumeIsolated { self?.handle(event) }
        }
        link = newLink
    }

    private func handle(_ event: BandLinkEvent) {
        switch event {
        case .availability(let availability):
            switch availability {
            case .ready: break
            case .poweredOff: stage = .unavailable("Bluetooth is off. Turn it on in Control Centre, then try again.")
            case .notAllowed: stage = .unavailable("Pulse isn't allowed to use Bluetooth. Allow it in Settings > Privacy & Security > Bluetooth.")
            case .unsupported: stage = .unavailable("This device has no Bluetooth (for example the iOS simulator). You can still try the simulated band.")
            }

        case .discovered(let band):
            if let index = found.firstIndex(where: { $0.id == band.id }) {
                found[index] = band
            } else {
                found.append(band)
            }

        case .connected:
            startSession()

        case .notification(let characteristic, let bytes):
            guard var current = session else { return }
            let effects = current.receive(characteristic: characteristic, bytes: bytes, now: Date().timeIntervalSince1970)
            session = current
            badFrames = current.badFrames
            run(effects)

        case .disconnected(let reason):
            session = nil
            if let reason, isBusy {
                stage = .failed(reason)
            } else if isBusy {
                stage = .idle
            }
        }
    }

    private func startSession() {
        guard let context, let target else { return }
        // First time with a REAL band: its data replaces the demo month, so the two never mix.
        if !usingSimulatedBand && Self.pairedBand(in: context) == nil {
            try? PulseStore.deleteAllHealthData(in: context)
            DataSourceSetting.current = .band
        }
        let record = Self.pairedBand(in: context) ?? {
            let created = BandRecord(peripheralID: target.id, name: target.name)
            context.insert(created)
            return created
        }()
        record.lastSeenAt = .now
        try? context.save()

        var fresh = BandSession()
        let effects = fresh.start()
        session = fresh
        stage = .syncing
        run(effects)

        // If the band never answers the clock question, download anyway after 3 seconds.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, var current = self.session, current.phase == .hello else { return }
            let late = current.clockTimedOut()
            self.session = current
            self.run(late)
        }
    }

    // MARK: - Carrying out what the session asks for

    private func run(_ effects: [BandSession.Effect]) {
        for effect in effects {
            switch effect {
            case .write(let bytes, _):
                link?.write(bytes)

            case .persist(let records, let token):
                save(records, token: token)

            case .info(let newInfo):
                info = newInfo
                if let context, let record = Self.pairedBand(in: context) {
                    record.batteryPercent = newInfo.batteryPercent
                    record.isCharging = newInfo.isCharging ?? false
                    record.firmwareVersion = newInfo.firmware
                }

            case .progress(let saved, _):
                recordsSaved = saved

            case .liveHeartRate:
                break       // the live heart-rate screen is not built yet

            case .finished:
                finish()

            case .failed(let message):
                stage = .failed(message)
                link?.disconnect()

            case .log(let entry):
                log.append(entry)
                if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
            }
        }
    }

    /// Saves one batch on a background thread. Only when that is done does the band get its ack.
    private func save(_ records: [Whoop.HistoryRecord], token: [UInt8]) {
        guard let context else { return }
        let container = context.container
        let source: DataSource = usingSimulatedBand ? .simulated : .history
        Task { [weak self] in
            do {
                try await BandImporter(modelContainer: container).save(records, source: source)
                guard let self, var current = self.session else { return }
                let effects = current.didPersist(token: token, recordCount: records.count)
                self.session = current
                self.run(effects)
            } catch {
                self?.stage = .failed("Could not save the band's data: \(error.localizedDescription)")
                self?.link?.disconnect()
            }
        }
    }

    /// History is complete: recalculate every metric from the new raw data, then update the screens.
    private func finish() {
        guard let context else { return }
        let container = context.container
        let profile = ProfileStore.current(in: context).metricsProfile
        Task { [weak self] in
            do {
                let output = try await MetricsRecomputer(modelContainer: container)
                    .run(profile: profile, calendar: .current, now: .now, detectWorkouts: true)
                try PulseStore.apply(output, to: context)
                if let record = Self.pairedBand(in: context) {
                    record.lastHistorySyncAt = .now
                    try? context.save()
                }
                self?.stage = .upToDate
                self?.onDataChanged?()
            } catch {
                self?.stage = .failed("The data was saved, but the metrics could not be recalculated: \(error.localizedDescription)")
            }
            self?.session = nil
            self?.link?.disconnect()
        }
    }
}

/// Where the numbers on screen come from. Remembered between launches (a UI setting, not health
/// data, so UserDefaults is the right place).
enum DataSourceSetting: String {
    case demo, band

    private static let key = "dataSource"

    static var current: DataSourceSetting {
        get { DataSourceSetting(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .demo }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
