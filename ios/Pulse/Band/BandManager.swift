import Foundation
import Observation
import SwiftData
import UIKit
import PulseCore

/// The band connection, as the screens see it. Works like WHOOP's own app: you never think about
/// syncing.
///
/// - The connection is kept. Once a band is paired, Pulse asks CoreBluetooth for it at launch and
///   after every drop; iOS connects whenever the band is in range, also in the background, and can
///   relaunch Pulse for it (state restoration, see BluetoothBandLink).
/// - While connected, new records are pulled every `pullInterval`, right away when the app opens,
///   and whenever the band wakes Pulse in the background (any event from it). A pull is short: a few
///   commands, the new batches, done. Live heart rate streams only while a live screen asks for it.
/// - The screens show cached data at once; new data slides in when a pull saved something.
///
/// It connects three things that each do one job:
///   BandLink (bytes in / out)  <->  SyncWorker + BandSession (the protocol, off the main thread)  <->  the database
///
/// The safety rule from Phase 5a still holds: a history batch with records to keep is acknowledged
/// to the band only after `BandImporter.save` has returned, i.e. after the data is on disk.
@MainActor
@Observable
final class BandManager {
    /// The one band connection of the app (the screens and BackgroundSync share it).
    static let shared = BandManager()

    enum Stage: Equatable {
        /// Not connected: waiting for the band (it connects by itself when in range).
        case idle
        /// Bluetooth can't be used right now. The text says why and what to do.
        case unavailable(String)
        case searching
        case connecting
        /// A pull (download) is running.
        case syncing
        /// Connected (or was), nothing left to pull.
        case upToDate
        /// Stopped on purpose (band battery too low). Not an error: it resumes after charging.
        case paused(String)
        case failed(String)
    }

    /// What the status pill warns about. `nil` = all good (the pill stays quiet).
    enum Attention: Equatable {
        case bluetoothOff, bluetoothNotAllowed, bandNotFound, batteryLow(Int), syncProblem

        var text: String {
            switch self {
            case .bluetoothOff: "Bluetooth off"
            case .bluetoothNotAllowed: "Bluetooth not allowed"
            case .bandNotFound: "Band not found"
            case .batteryLow(let percent): "Band \(percent)%"
            case .syncProblem: "Sync problem"
            }
        }

        var symbol: String {
            switch self {
            case .bluetoothOff, .bluetoothNotAllowed: "antenna.radiowaves.left.and.right.slash"
            case .bandNotFound: "questionmark.circle"
            case .batteryLow: "battery.25percent"
            case .syncProblem: "exclamationmark.triangle"
            }
        }
    }

    private(set) var stage: Stage = .idle
    private(set) var found: [DiscoveredBand] = []
    private(set) var info = BandSession.Info()
    /// Connected to the band right now.
    private(set) var isConnected = false
    /// A pull has been running a while (a big chunk, e.g. the night): the status pill shows a spinner.
    /// Short pulls never show anything.
    private(set) var showsSyncSpinner = false
    /// How far the current download is. Updated once per batch, not per packet.
    private(set) var progress = BandSession.Progress()
    /// Seconds of band data saved in this pull (the band records about one sample per second).
    var recordsSaved: Int { progress.recordsSaved }
    var batchesSaved: Int { progress.batchesSaved }
    /// The previous owner's records thrown away in this pull (acked, never saved).
    var recordsCleared: Int { progress.recordsCleared }
    /// True while the band is still sending records from before your pairing day.
    var clearingOldData: Bool { progress.clearingOldData }
    /// Newest last. Only kept in memory, capped.
    private(set) var log: [BandSession.LogEntry] = []
    private(set) var badFrames = 0
    /// The band's live heart rate while a live screen asks for it. `nil` = no live reading.
    private(set) var liveHeartRate: Int?
    private var wantsLive = false
    /// The 100 Hz motion stream's seconds while a step test runs (docs/METRICS.md §15).
    private(set) var liveSteps = LiveSteps()
    /// True while a step test wants the 100 Hz stream.
    private(set) var isStreamingMotion = false
    @ObservationIgnored private var motionStreamCap: Task<Void, Never>?
    /// The stream turns itself off after this long, whatever happens to the step test.
    static let motionStreamLimit: TimeInterval = 15 * 60

    /// Called after new data was saved and the metrics were recalculated.
    var onDataChanged: (() -> Void)?

    @ObservationIgnored private var link: BluetoothBandLink?
    @ObservationIgnored private var worker: SyncWorker?
    /// Changes with every new link: late messages from an old connection are ignored.
    @ObservationIgnored private var generation = 0
    /// True between "connected" and "disconnected" (a BandSession exists).
    @ObservationIgnored private var hasSession = false
    /// A connection request is open (CoreBluetooth keeps it until the band shows up).
    @ObservationIgnored private var connectRequested = false
    /// "Sync anyway": the next pull ignores the low-battery pause.
    @ObservationIgnored private var lowBatteryOverride = false
    @ObservationIgnored private var overrideLogged = false
    private var context: ModelContext?
    private var target: DiscoveredBand?
    private static let logLimit = 400

    // MARK: - Timing

    /// While connected, new records are pulled this often (and right away when the app opens).
    static let pullInterval: TimeInterval = 5 * 60
    /// How often to ask iOS for a background wake-up (iOS decides when, often less often).
    static let backgroundInterval: TimeInterval = 15 * 60
    /// The status pill says "Band not found" after this long without the band.
    static let lostAfter: TimeInterval = 30 * 60
    /// A pull still running after this long is a big chunk: only then a spinner appears.
    static let spinnerAfter: Duration = .seconds(4)
    /// Warn about the band battery below this (pulls pause below `lowBatteryPercent`).
    static let batteryWarnPercent = 15.0
    static let lowBatteryPercent = 5.0
    /// After a low-battery pause the band is left alone this long, then asked again.
    static let lowBatteryRetry: TimeInterval = 20 * 60
    static let chargeMessage = "Charge your band to keep syncing"

    /// Watchdog: if the band sends nothing for this long during a pull, ask again.
    private static let stallSeconds: TimeInterval = 25
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var syncStartedAt = Date.now
    @ObservationIgnored private var lastPullAt: Date?
    @ObservationIgnored private var pullNumber = 0
    @ObservationIgnored private var pausedUntil: Date?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectFailures = 0

    private static func isLow(_ percent: Double?, charging: Bool?) -> Bool {
        guard let percent else { return false }
        return percent < lowBatteryPercent && charging != true
    }

    /// The newest battery reading in this connection (the stored one may be older).
    @ObservationIgnored private var lastBatteryReading: Double?
    /// Set once the battery was seen rising: it is on the charger.
    @ObservationIgnored private var batteryRose = false

    /// Is the band charging right now? The band's own report wins (CHARGING_ON / CHARGING_OFF events,
    /// or the charging flag in its BATTERY_LEVEL event). Without one: a battery that went up by 1 %
    /// or more since the last reading is on the charger. nil = unknown.
    private func chargingState(_ newInfo: BandSession.Info, previousPercent: Double?) -> Bool? {
        if let reported = newInfo.isCharging { return reported }
        if !batteryRose, let now = newInfo.batteryPercent, let before = previousPercent, now >= before + 1 {
            batteryRose = true
            traceLine(String(format: "CHARGING (inferred): band battery rose from %.1f%% to %.1f%%", before, now))
        }
        return batteryRose ? true : nil
    }

    var isBusy: Bool { stage == .searching || stage == .connecting || stage == .syncing }

    /// "Clearing old band data… 45%", "Syncing… 80%", "Up to date". For the debug sheet.
    var statusLine: String {
        switch stage {
        case .searching: return "Searching…"
        case .connecting: return "Connecting…"
        case .syncing:
            let percent = progress.fraction.map { " \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return (clearingOldData ? "Clearing old band data…" : "Syncing…") + percent
        case .paused: return Self.chargeMessage
        case .upToDate: return isConnected ? "Connected, up to date" : "Up to date"
        case .failed: return "Sync failed"
        case .idle: return "Waiting for the band"
        case .unavailable: return "Bluetooth unavailable"
        }
    }

    /// The one thing the status pill should warn about, or nil when all is well.
    func attention(record: BandRecord?, now: Date = .now) -> Attention? {
        if case .unavailable(let why) = stage {
            return why.contains("allowed") ? .bluetoothNotAllowed : .bluetoothOff
        }
        guard let record else { return nil }
        if case .paused = stage { return .batteryLow(Int((record.batteryPercent ?? 0).rounded())) }
        if let battery = record.batteryPercent, battery < Self.batteryWarnPercent, !record.isCharging {
            return .batteryLow(Int(battery.rounded()))
        }
        if !isConnected, now.timeIntervalSince(record.lastSeenAt ?? .distantPast) > Self.lostAfter { return .bandNotFound }
        if case .failed = stage { return .syncProblem }
        return nil
    }

    /// Sync log detail: off = history packets summarized once per batch (small log).
    var verboseLog: Bool = UserDefaults.standard.bool(forKey: "syncLogVerbose") {
        didSet { UserDefaults.standard.set(verboseLog, forKey: "syncLogVerbose") }
    }

    // MARK: - Staying connected

    /// App launch, including when iOS relaunches Pulse in the background for the band: if a band
    /// is paired, ask for its connection (this also receives a connection restored by iOS).
    func launch(context: ModelContext) {
        self.context = context
        keepConnected()
    }

    /// The app came to the front: connect if needed and pull right away (cached data is already on screen).
    func appBecameActive(context: ModelContext) {
        self.context = context
        keepConnected()
        pullIfDue(olderThan: 30)
    }

    /// Pull new records if the last pull is older than `olderThan` seconds. Cheap to call often.
    func pullIfDue(olderThan interval: TimeInterval = pullInterval) {
        guard isConnected, hasSession, !wantsLive, stage != .syncing else { return }
        if let lastPullAt, Date.now.timeIntervalSince(lastPullAt) < interval { return }
        pull()
    }

    /// Pull to refresh (Today) and "Sync now" (Settings > Band). Returns when the pull is done, or
    /// after `timeout` seconds if the band isn't around.
    func refresh(context: ModelContext, timeout: TimeInterval = 30) async {
        syncNow(context: context)
        let deadline = Date.now.addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(300))
        while (stage == .syncing || stage == .connecting) && Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Pull now, connecting first if needed (debug "Sync now", pull to refresh).
    /// - Parameter overrideLowBattery: "Sync anyway": this one pull runs even below the
    ///   low-battery threshold. Automatic pulls never pass true.
    func syncNow(context: ModelContext, overrideLowBattery: Bool = false) {
        self.context = context
        lowBatteryOverride = overrideLowBattery
        overrideLogged = false
        if overrideLowBattery { pausedUntil = nil }
        if isConnected && hasSession {
            pull()
        } else if Self.pairedBand(in: context) != nil {
            stage = .connecting
            keepConnected(force: true)
            // The band may be away: don't leave the screens on "Connecting…" forever.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.stage == .connecting, !self.isConnected else { return }
                self.stage = .idle
            }
        }
    }

    /// Ask for the connection if there is a paired band and none yet.
    private func keepConnected(force: Bool = false) {
        guard let context, let record = Self.pairedBand(in: context) else { return }
        if !force, let pausedUntil, Date.now < pausedUntil { return }
        ensureLink(context: context)
        guard !isConnected, !connectRequested || force else { return }
        connectRequested = true
        target = DiscoveredBand(id: record.peripheralID, name: record.name, signal: 0)
        traceLine("Asking for \(record.name) \(record.peripheralID): connects whenever it is in range")
        link?.connect(to: record.peripheralID)
    }

    private func scheduleReconnect(after seconds: TimeInterval) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.keepConnected()
        }
    }

    /// Start a pull on the open connection.
    private func pull() {
        guard isConnected, hasSession, stage != .syncing else { return }
        if let pausedUntil, Date.now < pausedUntil, !lowBatteryOverride { return }
        progress = BandSession.Progress()
        lastPullAt = .now
        syncStartedAt = .now
        stage = .syncing
        pullNumber += 1
        armSpinner()
        startWatchdog()
        worker?.pullAgain { [weak self] started in
            guard !started else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The session can't pull (still busy or broken): start over with a fresh connection.
                    guard let self, self.stage == .syncing else { return }
                    self.traceLine("PULL not possible on this connection: reconnecting")
                    self.stopWatchdog()
                    self.stage = .idle
                    self.endSession()
                    self.link?.disconnect()
                    self.scheduleReconnect(after: 2)
                }
            }
        }
    }

    /// The spinner only appears if the pull is still running after a few seconds (a big chunk).
    private func armSpinner() {
        showsSyncSpinner = false
        let number = pullNumber
        Task { [weak self] in
            try? await Task.sleep(for: Self.spinnerAfter)
            guard let self, self.pullNumber == number, self.stage == .syncing else { return }
            self.showsSyncSpinner = true
        }
    }

    // MARK: - Pairing and live heart rate

    /// Start looking for a band.
    func startPairing(context: ModelContext) {
        ensureLink(context: context)
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
        connectRequested = true
        link?.connect(to: band.id)
    }

    /// A live screen opened: stream heart rate (connecting first if needed).
    func startLive(context: ModelContext) {
        self.context = context
        wantsLive = true
        liveHeartRate = nil
        if isConnected && hasSession && stage != .syncing {
            worker?.setLive(true)
        } else {
            keepConnected(force: true)      // the stream starts after the first pull
        }
    }

    /// The live screen closed: stop the stream. The connection stays.
    func stopLive() {
        guard wantsLive else { return }
        wantsLive = false
        liveHeartRate = nil
        if hasSession { worker?.setLive(false) }
    }

    /// A step test started: stream the band's 100 Hz motion. It stops by itself after `motionStreamLimit`, and every
    /// new connection turns it off (BandSession.start), so a test cut short can't leave it running.
    func startMotionStream(context: ModelContext) {
        self.context = context
        liveSteps = LiveSteps()
        isStreamingMotion = true
        traceLine("STEP TEST: asking for the 100 Hz motion stream")
        if isConnected && hasSession {
            worker?.setRawStream(true)
        } else {
            keepConnected(force: true)      // switched on after the first pull
        }
        motionStreamCap?.cancel()
        motionStreamCap = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.motionStreamLimit))
            guard !Task.isCancelled else { return }
            self?.stopMotionStream()
        }
    }

    /// The step test stopped: stream off. The seconds received stay in `liveSteps` until the next test.
    func stopMotionStream() {
        motionStreamCap?.cancel()
        motionStreamCap = nil
        guard isStreamingMotion else { return }
        isStreamingMotion = false
        let scale = liveSteps.medianG.map { String(format: "%.3f g", $0) } ?? "no readings"
        traceLine("STEP TEST: stream off after \(liveSteps.seconds.count) seconds of motion (median size \(scale))")
        if hasSession { worker?.setRawStream(false) }
    }

    /// Stop pairing (scan / connect to a new band). A paired band's connection is kept.
    func cancel() {
        link?.stopScanning()
        if let context, Self.pairedBand(in: context) != nil {
            if stage == .searching || stage == .connecting { stage = isConnected ? .upToDate : .idle }
            return
        }
        traceLine("Cancelled")
        link?.disconnect()
        endSession()
        stopWatchdog()
        connectRequested = false
        if isBusy { stage = .idle }
    }

    /// Forget the band. The data that was already downloaded stays on the phone.
    func forget(context: ModelContext) {
        reconnectTask?.cancel()
        link?.stopScanning()
        link?.disconnect()
        endSession()
        stopWatchdog()
        connectRequested = false
        isConnected = false
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
        stage: \(stage), connected: \(isConnected), pulls: \(pullNumber), last pull: records saved \(recordsSaved), batches \(batchesSaved), old records dropped \(recordsCleared), damaged frames: \(badFrames)
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

    /// One link and one worker for the whole app run (the connection is kept).
    private func ensureLink(context: ModelContext) {
        self.context = context
        guard link == nil else { return }
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
            case .ready:
                if case .unavailable = stage { stage = .idle }
                connectRequested = false        // requests don't survive Bluetooth being off
                keepConnected()
            case .poweredOff:
                lostConnection()
                stage = .unavailable("Bluetooth is off. Turn it on in Control Centre.")
            case .notAllowed:
                stage = .unavailable("Pulse isn't allowed to use Bluetooth. Allow it in Settings > Privacy & Security > Bluetooth.")
            case .unsupported:
                stage = .unavailable("This device has no Bluetooth.")
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
            isConnected = true
            connectRequested = false
            reconnectFailures = 0
            reconnectTask?.cancel()
            startSession()

        case .notification:
            break       // handled by the SyncWorker on the Bluetooth queue

        case .disconnected(let reason):
            traceLine("Disconnected: \(reason ?? "on purpose")")
            let wasSyncing = stage == .syncing
            let wasConnected = isConnected
            lostConnection()
            let paired = context.flatMap { Self.pairedBand(in: $0) }
            guard let paired else {
                // Pairing a new band went wrong: say so on the pairing screen.
                if let reason, isBusy { stage = .failed(reason) } else if isBusy { stage = .idle }
                return
            }
            if wasConnected { paired.lastSeenAt = .now; try? context?.save() }
            // Not an error for the screens: it reconnects by itself. Pause and failure keep their message.
            switch stage {
            case .paused, .failed, .unavailable: break
            default: stage = .idle
            }
            if wasSyncing && recordsSaved > 0 { recomputeSaved() }
            if reason != nil {
                // Out of range or a hiccup: ask again (CoreBluetooth then waits for the band).
                // Back off if the request itself keeps failing.
                reconnectFailures += 1
                scheduleReconnect(after: min(300, 2 * pow(2, Double(min(reconnectFailures - 1, 8)))))
            }
        }
    }

    /// Whatever ended the connection: forget the session and the stream.
    private func lostConnection() {
        isConnected = false
        connectRequested = false
        endSession()
        liveHeartRate = nil
        stopWatchdog()
        showsSyncSpinner = false
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
        traceLine("Phone battery \(Self.phoneBattery())")

        progress = BandSession.Progress()
        lastBatteryReading = nil
        batteryRose = false
        badFrames = 0
        hasSession = true
        stage = .syncing
        syncStartedAt = .now
        lastPullAt = .now
        pullNumber += 1
        armSpinner()
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
                let record = context.flatMap { Self.pairedBand(in: $0) }
                let charging = chargingState(newInfo, previousPercent: lastBatteryReading ?? record?.batteryPercent)
                if let percent = newInfo.batteryPercent { lastBatteryReading = percent }
                if let record {
                    // Only what the band actually reported: an unknown value never wipes the last one.
                    if let percent = newInfo.batteryPercent { record.batteryPercent = percent }
                    if let charging { record.isCharging = charging }
                    if let firmware = newInfo.firmware { record.firmwareVersion = firmware }
                    record.lastSeenAt = .now
                }
                if stage == .syncing, Self.isLow(newInfo.batteryPercent, charging: charging) {
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
                // The band woke Pulse (e.g. an event in the background): a chance to pull.
                if stage != .syncing { pullIfDue() }

            case .progress(let newProgress):
                progress = newProgress

            case .liveHeartRate(let bpm):
                liveHeartRate = bpm

            case .rawMotion(let motion):
                if isStreamingMotion { liveSteps.add(motion) }

            case .finished:
                stopWatchdog()
                finish()

            case .failed(let message):
                stopWatchdog()
                showsSyncSpinner = false
                stage = .failed(message)
                endSession()
                link?.disconnect()
                if recordsSaved > 0 { recomputeSaved() }
                scheduleReconnect(after: 60)        // a fresh connection, a fresh session

            case .log(let entry):
                log.append(entry)
                if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }

            case .write, .persist, .trace:
                break       // done by the worker
            }
        }
    }

    /// The band is nearly empty: stop cleanly and leave it alone for a while. Nothing unsaved was
    /// acked, so whatever the band still holds is simply sent again later (after charging).
    private func pauseForLowBattery(_ percent: Double) {
        traceLine("PAUSED: band battery \(Int(percent.rounded()))% is below \(Int(Self.lowBatteryPercent))% and not charging")
        stopWatchdog()
        showsSyncSpinner = false
        stage = .paused(Self.chargeMessage)
        pausedUntil = Date.now.addingTimeInterval(Self.lowBatteryRetry)
        endSession()
        link?.disconnect()
        if recordsSaved > 0 { recomputeSaved() }
        scheduleReconnect(after: Self.lowBatteryRetry)
    }

    /// For the sync log, to see what a pull costs.
    private static func phoneBattery() -> String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? "?" : "\(Int((level * 100).rounded()))%"
    }

    private func traceLine(_ line: String) {
        worker?.addTrace(line)
    }

    /// A pull is complete. If it saved anything, recalculate every metric (in the background),
    /// then the screens update. The connection stays open for the next pull.
    private func finish() {
        guard let context else { return }
        progress.clearingOldData = false
        lowBatteryOverride = false
        pausedUntil = nil
        let saved = recordsSaved
        traceLine("PULL \(pullNumber) DONE: \(saved) records in \(batchesSaved) batches, \(recordsCleared) old records dropped, \(Int(Date.now.timeIntervalSince(syncStartedAt))) s. Phone battery \(Self.phoneBattery()), band \(info.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "?").\(saved > 0 ? " Recalculating." : "")")
        if let record = Self.pairedBand(in: context) {
            record.lastHistorySyncAt = .now
            record.lastSeenAt = .now
            try? context.save()
        }
        let afterwards = { [weak self] in
            guard let self else { return }
            self.showsSyncSpinner = false
            // A live screen is waiting: switch the stream on now that the pull is done.
            if self.wantsLive && self.hasSession { self.worker?.setLive(true) }
            // A step test is running (the connection came back): the new session turned the 100 Hz stream off.
            if self.isStreamingMotion && self.hasSession { self.worker?.setRawStream(true) }
        }
        guard saved > 0 else {
            stage = .upToDate
            afterwards()
            return
        }
        let container = context.container
        let profile = ProfileStore.current(in: context).metricsProfile
        let started = Date.now
        Task { [weak self] in
            do {
                let output = try await MetricsRecomputer.inBackground(container: container, profile: profile,
                                                                      calendar: .current, now: .now, detectWorkouts: true)
                let computed = Date.now
                try PulseStore.apply(output, to: context)
                self?.traceLine("RECOMPUTE: \(Int(computed.timeIntervalSince(started) * 1000)) ms in the background, \(Int(Date.now.timeIntervalSince(computed) * 1000)) ms writing results on the main thread")
                if self?.stage == .syncing { self?.stage = .upToDate }
                self?.onDataChanged?()
            } catch {
                self?.stage = .failed("The data was saved, but the metrics could not be recalculated: \(error.localizedDescription)")
            }
            afterwards()
        }
    }

    /// The pull stopped early, but some batches are safely saved: show them anyway.
    private func recomputeSaved() {
        guard let context else { return }
        traceLine("Recalculating with the \(recordsSaved) records saved before the pull stopped")
        let container = context.container
        let profile = ProfileStore.current(in: context).metricsProfile
        Task { [weak self] in
            guard let output = try? await MetricsRecomputer.inBackground(container: container, profile: profile,
                                                                         calendar: .current, now: .now, detectWorkouts: true) else { return }
            try? PulseStore.apply(output, to: context)
            self?.onDataChanged?()
        }
    }
}
