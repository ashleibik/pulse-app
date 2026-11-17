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
    /// The one band connection of the app (the screens and BackgroundSync share it).
    static let shared = BandManager()

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
    private(set) var batchesSaved = 0
    /// Newest last. Only kept in memory, capped.
    private(set) var log: [BandSession.LogEntry] = []
    private(set) var badFrames = 0
    /// The band's live heart rate while a live workout is open. `nil` = no live reading.
    private(set) var liveHeartRate: Int?
    private var wantsLive = false

    /// The detailed sync log (every notification, frame, command, batch). Memory only; exported
    /// from the debug screen. Not observed: it changes thousands of times per second during a sync.
    @ObservationIgnored private(set) var trace = SyncTrace()

    /// Called after new data was saved and the metrics were recalculated.
    var onDataChanged: (() -> Void)?

    private var link: BandLink?
    private var session: BandSession?
    private var context: ModelContext?
    private var target: DiscoveredBand?
    private static let logLimit = 400

    /// Watchdog: if the band sends nothing for this long during the download, ask again.
    /// Generous on purpose: a first sync can have weeks of data and the band pauses between batches.
    private static let stallSeconds: TimeInterval = 25
    @ObservationIgnored private var lastActivity = Date.now
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    var isBusy: Bool { stage == .searching || stage == .connecting || stage == .syncing }

    // MARK: - What the screens call

    /// Start looking for a band.
    func startPairing(context: ModelContext) {
        prepare(context: context)
        found = []
        stage = .searching
        traceLine("Searching for bands")
        link?.startScanning()
    }

    func connect(_ band: DiscoveredBand) {
        target = band
        stage = .connecting
        traceLine("Connecting to \(band.name) \(band.id) (signal \(band.signal) dBm)")
        link?.stopScanning()
        link?.connect(to: band.id)
    }

    /// Sync again with the band that is already paired.
    func syncNow(context: ModelContext) {
        guard !isBusy, let record = Self.pairedBand(in: context) else { return }
        prepare(context: context)
        target = DiscoveredBand(id: record.peripheralID, name: record.name, signal: 0)
        stage = .connecting
        traceLine("Sync: connecting to \(record.name) \(record.peripheralID)")
        link?.connect(to: record.peripheralID)
    }

    /// Called whenever the app comes to the screen: syncs quietly if a band is paired and
    /// the last sync is more than 15 minutes old.
    func syncIfDue(context: ModelContext) {
        guard !isBusy, !wantsLive, let record = Self.pairedBand(in: context) else { return }
        if let last = record.lastHistorySyncAt, Date.now.timeIntervalSince(last) < 15 * 60 { return }
        syncNow(context: context)
    }

    /// Live workout opened: connect (and sync) if needed, then ask the band to stream heart rate.
    /// Without a paired band nothing happens and `liveHeartRate` stays nil.
    func startLive(context: ModelContext) {
        wantsLive = true
        liveHeartRate = nil
        if !isBusy { syncNow(context: context) }
    }

    /// Live workout closed: stop the stream and let the band go.
    func stopLive() {
        guard wantsLive else { return }
        wantsLive = false
        liveHeartRate = nil
        if var current = session {
            let effects = current.setLive(false)
            session = nil
            run(effects)
        }
        if !isBusy { link?.disconnect() }
    }

    func cancel() {
        traceLine("Cancelled")
        link?.stopScanning()
        link?.disconnect()
        session = nil
        stopWatchdog()
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

    /// The sync log as a text file, for the share sheet. nil if nothing was logged yet.
    func exportTrace() -> URL? {
        guard trace.total > 0 else { return nil }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let started = trace.startedAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .standard) } ?? "?"
        let header = """
        Pulse sync log
        app \(version), exported \(Date.now.formatted(date: .abbreviated, time: .standard)), log started \(started)
        stage: \(stage), records saved: \(recordsSaved), batches: \(batchesSaved), damaged frames: \(badFrames)
        band: battery \(self.info.batteryPercent.map { "\($0)%" } ?? "?"), firmware \(self.info.firmware ?? "?")
        Contains raw band data (heart rate). Only share it with someone you trust.
        """
        let stamp = Int(Date.now.timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-sync-log-\(stamp).txt")
        do {
            try trace.text(header: header).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Link events

    private func prepare(context: ModelContext) {
        link?.disconnect()
        stopWatchdog()
        self.context = context
        session = nil
        recordsSaved = 0
        batchesSaved = 0
        badFrames = 0
        log = []
        trace = SyncTrace()
        let newLink = BluetoothBandLink()
        newLink.onEvent = { [weak self] event in
            // BandLink promises the main thread.
            MainActor.assumeIsolated { self?.handle(event) }
        }
        link = newLink
    }

    private func handle(_ event: BandLinkEvent) {
        switch event {
        case .availability(let availability):
            traceLine("Bluetooth: \(availability)")
            switch availability {
            case .ready: break
            case .poweredOff: stage = .unavailable("Bluetooth is off. Turn it on in Control Centre, then try again.")
            case .notAllowed: stage = .unavailable("Pulse isn't allowed to use Bluetooth. Allow it in Settings > Privacy & Security > Bluetooth.")
            case .unsupported: stage = .unavailable("This device has no Bluetooth.")
            }

        case .discovered(let band):
            if let index = found.firstIndex(where: { $0.id == band.id }) {
                found[index] = band
            } else {
                found.append(band)
                traceLine("Found \(band.name) \(band.id) (signal \(band.signal) dBm)")
            }

        case .note(let text):
            traceLine(text)

        case .connected:
            traceLine("Connected, notifications on")
            startSession()

        case .notification(let characteristic, let bytes):
            lastActivity = .now
            guard var current = session else {
                traceLine("RX (no session) \(characteristic) len=\(bytes.count) \(Whoop.hex(bytes))")
                return
            }
            let effects = current.receive(characteristic: characteristic, bytes: bytes, now: Date().timeIntervalSince1970)
            session = current
            badFrames = current.badFrames
            run(effects)

        case .disconnected(let reason):
            traceLine("Disconnected: \(reason ?? "on purpose")")
            let wasSyncing = stage == .syncing
            session = nil
            liveHeartRate = nil
            stopWatchdog()
            if let reason, isBusy {
                stage = .failed(reason)
            } else if isBusy {
                stage = .idle
            }
            // The link dropped mid-download: what was saved is real data, so show it.
            if wasSyncing && recordsSaved > 0 { recomputeSaved() }
        }
    }

    private func startSession() {
        guard let context, let target else { return }
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
        lastActivity = .now
        run(effects)
        startWatchdog()

        // If the band never answers the clock question, download anyway after 3 seconds.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, var current = self.session, current.phase == .hello else { return }
            self.traceLine("No answer to GET_CLOCK after 3 s: downloading without setting the clock")
            let late = current.clockTimedOut()
            self.session = current
            self.run(late)
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        stopWatchdog()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, var current = self.session, self.stage == .syncing else { continue }
                guard Date.now.timeIntervalSince(self.lastActivity) > Self.stallSeconds else { continue }
                self.traceLine("WATCHDOG: no data for \(Int(Self.stallSeconds)) s")
                self.lastActivity = .now
                let effects = current.stalled()
                self.session = current
                self.run(effects)
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
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

            case .progress(let saved, let batches):
                recordsSaved = saved
                batchesSaved = batches

            case .liveHeartRate(let bpm):
                liveHeartRate = bpm

            case .finished:
                stopWatchdog()
                finish()

            case .failed(let message):
                stopWatchdog()
                stage = .failed(message)
                link?.disconnect()
                if recordsSaved > 0 { recomputeSaved() }

            case .log(let entry):
                log.append(entry)
                if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }

            case .trace(let line):
                trace.add(line, at: Date().timeIntervalSince1970)
            }
        }
    }

    private func traceLine(_ line: String) {
        trace.add(line, at: Date().timeIntervalSince1970)
    }

    /// Saves one batch on a background thread. Only when that is done does the band get its ack.
    private func save(_ records: [Whoop.HistoryRecord], token: [UInt8]) {
        guard let context else { return }
        let container = context.container
        let started = Date.now
        Task { [weak self] in
            do {
                try await BandImporter(modelContainer: container).save(records, source: .history)
                guard let self, var current = self.session else { return }
                self.traceLine("SAVED \(records.count) records in \(Int(Date.now.timeIntervalSince(started) * 1000)) ms: sending ack")
                self.lastActivity = .now
                let effects = current.didPersist(token: token, recordCount: records.count)
                self.session = current
                self.run(effects)
            } catch {
                self?.traceLine("SAVE FAILED: \(error.localizedDescription)")
                self?.stage = .failed("Could not save the band's data: \(error.localizedDescription)")
                self?.link?.disconnect()
            }
        }
    }

    /// History is complete: recalculate every metric from the new raw data, then update the screens.
    private func finish() {
        guard let context else { return }
        traceLine("HISTORY_COMPLETE: \(recordsSaved) records in \(batchesSaved) batches. Recalculating.")
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
            guard let self else { return }
            if self.wantsLive, var current = self.session {
                // A live workout is waiting: keep the connection and switch the stream on.
                let effects = current.setLive(true)
                self.session = current
                self.run(effects)
            } else {
                self.session = nil
                self.link?.disconnect()
            }
        }
    }

    /// The sync stopped early, but some batches are safely saved: show them anyway.
    /// The stage stays `.failed` so the screen still says what went wrong.
    private func recomputeSaved() {
        guard let context else { return }
        traceLine("Recalculating with the \(recordsSaved) records saved before the sync stopped")
        let container = context.container
        let profile = ProfileStore.current(in: context).metricsProfile
        Task { [weak self] in
            guard let output = try? await MetricsRecomputer(modelContainer: container)
                .run(profile: profile, calendar: .current, now: .now, detectWorkouts: true) else { return }
            try? PulseStore.apply(output, to: context)
            self?.onDataChanged?()
        }
    }
}
