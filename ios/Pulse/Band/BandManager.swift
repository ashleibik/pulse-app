import Foundation
import Observation
import SwiftData
import UIKit
import PulseCore

/// Pairing and syncing, as the screens see it.
///
/// It connects three things that each do one job:
///   BandLink (bytes in / out)  <->  SyncWorker + BandSession (the protocol, off the main thread)  <->  the database
///
/// Packets never touch the main thread: BluetoothBandLink delivers them on its own queue, where
/// SyncWorker parses, logs and saves them. This class only receives what a screen shows.
///
/// The safety rule from Phase 5a still holds: a history batch with records to keep is acknowledged
/// to the band only after `BandImporter.save` has returned, i.e. after the data is on disk.
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
        /// Stopped on purpose (band battery too low). Not an error: it resumes after charging.
        case paused(String)
        case failed(String)
    }

    private(set) var stage: Stage = .idle
    private(set) var found: [DiscoveredBand] = []
    private(set) var info = BandSession.Info()
    /// How far the current download is. Updated once per batch, not per packet.
    private(set) var progress = BandSession.Progress()
    /// Seconds of band data saved in this sync (the band records about one sample per second).
    var recordsSaved: Int { progress.recordsSaved }
    var batchesSaved: Int { progress.batchesSaved }
    /// The previous owner's records thrown away in this sync (acked, never saved).
    var recordsCleared: Int { progress.recordsCleared }
    /// True while the band is still sending records from before your pairing day.
    var clearingOldData: Bool { progress.clearingOldData }
    /// Newest last. Only kept in memory, capped.
    private(set) var log: [BandSession.LogEntry] = []
    private(set) var badFrames = 0
    /// The band's live heart rate while a live workout is open. `nil` = no live reading.
    private(set) var liveHeartRate: Int?
    private var wantsLive = false

    /// Called after new data was saved and the metrics were recalculated.
    var onDataChanged: (() -> Void)?

    @ObservationIgnored private var link: BluetoothBandLink?
    @ObservationIgnored private var worker: SyncWorker?
    /// Changes with every new link: late messages from an old connection are ignored.
    @ObservationIgnored private var generation = 0
    /// True between "connected" and "done / disconnected".
    @ObservationIgnored private var hasSession = false
    /// "Sync anyway": this one manual sync ignores the low-battery pause. Reset by every new sync.
    @ObservationIgnored private var lowBatteryOverride = false
    @ObservationIgnored private var overrideLogged = false
    private var context: ModelContext?
    private var target: DiscoveredBand?
    private static let logLimit = 400

    /// Watchdog: if the band sends nothing for this long during the download, ask again.
    /// Generous on purpose: a first sync can have weeks of data and the band pauses between batches.
    private static let stallSeconds: TimeInterval = 25
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var syncStartedAt = Date.now

    /// Short bursts, not a constant connection: a normal sync connects, downloads what's new
    /// (usually a few seconds), and disconnects. Due every 20 minutes while the app is open, on
    /// every app open, and when iOS wakes the app in the background.
    static let syncInterval: TimeInterval = 20 * 60
    /// Until the first complete download (the previous owner's backlog is still on the band), a
    /// sync that stopped early is resumed after this pause instead of waiting 20 minutes.
    static let backlogRetry: TimeInterval = 2 * 60
    /// Below this the download is paused: a long drain must not run the band flat.
    static let lowBatteryPercent = 5.0
    static let chargeMessage = "Charge your band to keep syncing"

    private static func isLow(_ percent: Double?, charging: Bool?) -> Bool {
        guard let percent else { return false }
        return percent < lowBatteryPercent && charging != true
    }
    /// When the last sync started (finished or not). Before, only a COMPLETE sync was remembered,
    /// so an unfinished drain restarted on every app open and every background wake-up.
    @ObservationIgnored private var lastAttemptAt: Date? = UserDefaults.standard.object(forKey: "lastSyncAttemptAt") as? Date

    var isBusy: Bool { stage == .searching || stage == .connecting || stage == .syncing }

    /// "Clearing old band data… 45%", "Syncing… 80%", "Up to date". For the status pill and the sync screen.
    var statusLine: String {
        switch stage {
        case .searching: return "Searching…"
        case .connecting: return "Connecting…"
        case .syncing:
            let percent = progress.fraction.map { " \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return (clearingOldData ? "Clearing old band data…" : "Syncing…") + percent
        case .paused: return Self.chargeMessage
        case .upToDate: return "Up to date"
        case .failed: return "Sync failed"
        case .idle, .unavailable: return "Not syncing"
        }
    }

    /// Sync log detail: off = history packets summarized once per batch (small log).
    var verboseLog: Bool = UserDefaults.standard.bool(forKey: "syncLogVerbose") {
        didSet { UserDefaults.standard.set(verboseLog, forKey: "syncLogVerbose") }
    }

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
    /// - Parameter overrideLowBattery: "Sync anyway" on the charge screen: this one sync runs even
    ///   below the low-battery threshold. Automatic and background syncs never pass true.
    func syncNow(context: ModelContext, overrideLowBattery: Bool = false) {
        guard !isBusy, let record = Self.pairedBand(in: context) else { return }
        prepare(context: context)
        lowBatteryOverride = overrideLowBattery
        overrideLogged = false
        lastAttemptAt = .now
        UserDefaults.standard.set(Date.now, forKey: "lastSyncAttemptAt")
        target = DiscoveredBand(id: record.peripheralID, name: record.name, signal: 0)
        stage = .connecting
        traceLine("Sync: connecting to \(record.name) \(record.peripheralID)")
        link?.connect(to: record.peripheralID)
    }

    func syncIfDue(context: ModelContext) {
        guard !isBusy, !wantsLive, let record = Self.pairedBand(in: context) else { return }
        // A band that was nearly empty last time: only look again every 20 minutes (maybe it's charged now).
        let backlog = record.lastHistorySyncAt == nil && !Self.isLow(record.batteryPercent, charging: record.isCharging)
        let gap = backlog ? Self.backlogRetry : Self.syncInterval
        let last = [record.lastHistorySyncAt, lastAttemptAt].compactMap { $0 }.max()
        if let last, Date.now.timeIntervalSince(last) < gap { return }
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
        // Keep the session: a sync may still be running (it used to be cut off here).
        if hasSession { worker?.setLive(false) }
        guard !isBusy else { return }   // a running sync disconnects by itself when it is done
        // Give the "stream off" write a moment to reach the band, then let it go.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !self.wantsLive, !self.isBusy else { return }
            self.endSession()
            self.link?.disconnect()
        }
    }

    func cancel() {
        traceLine("Cancelled")
        link?.stopScanning()
        link?.disconnect()
        endSession()
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

    /// A copy of the detailed sync log (every command, response and batch).
    func traceSnapshot() -> SyncTrace {
        worker?.traceSnapshot() ?? SyncTrace()
    }

    /// The sync log as a text file, for the share sheet. nil if nothing was logged yet.
    func exportTrace() -> URL? {
        let trace = traceSnapshot()
        guard trace.total > 0 else { return nil }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let started = trace.startedAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .standard) } ?? "?"
        let header = """
        Pulse sync log
        app \(version), exported \(Date.now.formatted(date: .abbreviated, time: .standard)), log started \(started)
        stage: \(stage), records saved: \(recordsSaved), batches: \(batchesSaved), old records dropped: \(recordsCleared), damaged frames: \(badFrames)
        band: battery \(self.info.batteryPercent.map { "\($0)%" } ?? "?"), firmware \(self.info.firmware ?? "unknown") (raw \(self.info.firmwareRawHex ?? "?"))
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
        endSession()
        self.context = context
        progress = BandSession.Progress()
        lowBatteryOverride = false
        badFrames = 0
        log = []
        generation += 1
        let current = generation
        let newLink = BluetoothBandLink()
        let newWorker = SyncWorker(queue: newLink.queue, link: newLink, container: context.container) { [weak self] effects, bad in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(effects, badFrames: bad, generation: current) }
            }
        }
        newLink.onEvent = { [weak self, newWorker] event in
            // On the Bluetooth queue. Packets stay there; everything else goes to the main thread.
            if case .notification(let characteristic, let bytes) = event {
                newWorker.receive(characteristic: characteristic, bytes: bytes)
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, generation: current) }
            }
        }
        link = newLink
        worker = newWorker
    }

    private func handle(_ event: BandLinkEvent, generation: Int) {
        guard generation == self.generation else { return }      // from a connection that's gone
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

        case .notification:
            break       // handled by the SyncWorker on the Bluetooth queue

        case .disconnected(let reason):
            traceLine("Disconnected: \(reason ?? "on purpose")")
            let wasSyncing = stage == .syncing
            endSession()
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
        // A used band: everything before the day you first paired it is the previous owner's.
        BandDataCutoff.setOnFirstPairing()
        traceLine("Keeping only records from \(BandDataCutoff.date?.formatted(date: .abbreviated, time: .shortened) ?? "?") on; older ones are dropped unread and acked")
        syncStartedAt = .now
        traceLine("Phone battery \(Self.phoneBattery())")

        hasSession = true
        stage = .syncing
        worker?.start(discardBefore: BandDataCutoff.unix, verboseLog: verboseLog)
        startWatchdog()

        // If the band never answers the clock question, download anyway after 3 seconds.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.worker?.clockTimedOut(after: 3)
        }
    }

    private func endSession() {
        hasSession = false
        worker?.end()
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        stopWatchdog()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if self.stage == .syncing { self.worker?.checkStall(after: Self.stallSeconds) }
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: - What the sync worker reports (main thread, once per batch / event, never per packet)

    private func apply(_ effects: [BandSession.Effect], badFrames bad: Int, generation: Int) {
        guard generation == self.generation else { return }
        if bad != badFrames { badFrames = bad }
        for effect in effects {
            switch effect {
            case .info(let newInfo):
                info = newInfo
                if let context, let record = Self.pairedBand(in: context) {
                    record.batteryPercent = newInfo.batteryPercent
                    record.isCharging = newInfo.isCharging ?? false
                    record.firmwareVersion = newInfo.firmware
                }
                if stage == .syncing, Self.isLow(newInfo.batteryPercent, charging: newInfo.isCharging) {
                    if lowBatteryOverride {
                        if !overrideLogged {
                            overrideLogged = true
                            traceLine("FORCED: user override at band battery \(Int((newInfo.batteryPercent ?? 0).rounded()))%")
                        }
                    } else {
                        pauseForLowBattery(newInfo.batteryPercent ?? 0)
                        return
                    }
                }

            case .progress(let newProgress):
                progress = newProgress

            case .liveHeartRate(let bpm):
                liveHeartRate = bpm

            case .finished:
                stopWatchdog()
                finish()

            case .failed(let message):
                stopWatchdog()
                stage = .failed(message)
                endSession()
                link?.disconnect()
                if recordsSaved > 0 { recomputeSaved() }

            case .log(let entry):
                log.append(entry)
                if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }

            case .write, .persist, .trace:
                break       // done by the worker
            }
        }
    }

    /// The band is nearly empty: stop cleanly. Nothing unsaved was acked, so whatever the band
    /// still holds is simply sent again by the next sync (after charging).
    private func pauseForLowBattery(_ percent: Double) {
        traceLine("PAUSED: band battery \(Int(percent.rounded()))% is below \(Int(Self.lowBatteryPercent))% and not charging")
        stopWatchdog()
        stage = .paused(Self.chargeMessage)
        endSession()
        link?.disconnect()
        if recordsSaved > 0 { recomputeSaved() }
    }

    /// For the sync log, to see what a sync costs.
    private static func phoneBattery() -> String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? "?" : "\(Int((level * 100).rounded()))%"
    }

    private func traceLine(_ line: String) {
        worker?.addTrace(line)
    }

    /// History is complete: recalculate every metric from the new raw data (once per sync, in the
    /// background), then update the screens.
    private func finish() {
        guard let context else { return }
        progress.clearingOldData = false
        traceLine("HISTORY_COMPLETE: \(recordsSaved) records in \(batchesSaved) batches, \(recordsCleared) old records dropped, connected \(Int(Date.now.timeIntervalSince(syncStartedAt))) s. Phone battery \(Self.phoneBattery()), band \(info.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "?"). Recalculating.")
        let container = context.container
        let profile = ProfileStore.current(in: context).metricsProfile
        let started = Date.now
        Task { [weak self] in
            do {
                let output = try await MetricsRecomputer(modelContainer: container)
                    .run(profile: profile, calendar: .current, now: .now, detectWorkouts: true)
                let computed = Date.now
                try PulseStore.apply(output, to: context)
                self?.traceLine("RECOMPUTE: \(Int(computed.timeIntervalSince(started) * 1000)) ms in the background, \(Int(Date.now.timeIntervalSince(computed) * 1000)) ms writing results on the main thread")
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
            if self.wantsLive && self.hasSession {
                // A live workout is waiting: keep the connection and switch the stream on.
                self.worker?.setLive(true)
            } else {
                // Done: let the band go. The next sync is a short burst in 20 minutes.
                self.endSession()
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
