import Foundation
import SwiftData
import PulseCore

/// The download, off the main thread.
///
/// Lives on the Bluetooth queue (`BluetoothBandLink.queue`): every notification is reassembled,
/// checked, decoded and written to the sync log here, and batches are saved by `BandImporter` on its
/// own background context (one transaction per batch). The main thread only hears about things a
/// screen shows: a finished batch, the battery, the live heart rate, done or failed. Never about
/// single packets.
///
/// Thread rule: every stored property is only touched on `queue`. The public methods hop there.
final class SyncWorker: @unchecked Sendable {
    let queue: DispatchQueue
    private weak var link: BandLink?
    private let importer: BandImporter
    /// Hands the effects a screen cares about to the main thread, with the damaged-frame count.
    private let toMain: @Sendable ([BandSession.Effect], Int) -> Void

    private var session: BandSession?
    private var trace: SyncTrace
    private var lastActivity = Date()
    private var reportedBadFrames = 0

    init(queue: DispatchQueue, link: BandLink, container: ModelContainer,
         toMain: @escaping @Sendable ([BandSession.Effect], Int) -> Void) {
        self.queue = queue
        self.link = link
        self.importer = BandImporter(modelContainer: container)
        self.trace = SyncTrace()
        self.toMain = toMain
    }

    // MARK: - Called from the main thread

    func addTrace(_ line: String) {
        let now = Date().timeIntervalSince1970
        queue.async { [self] in trace.add(line, at: now) }
    }

    /// A copy of the sync log (for the debug screen and the export). Cheap: the arrays are shared.
    func traceSnapshot() -> SyncTrace {
        queue.sync { trace }
    }

    func start(discardBefore: UInt32?, verboseLog: Bool) {
        queue.async { [self] in
            var fresh = BandSession(discardBefore: discardBefore)
            fresh.verboseTrace = verboseLog
            let effects = fresh.start()
            session = fresh
            lastActivity = Date()
            run(effects)
        }
    }

    /// Still connected after a finished download: ask the band for what it recorded since.
    /// `done` (called on the Bluetooth queue) gets false if the session can't pull right now.
    func pullAgain(done: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard var current = session else { return done(false) }
            let effects = current.pullAgain()
            session = current
            guard !effects.isEmpty else { return done(false) }
            lastActivity = Date()
            trace.add("PULL: asking the band for new records (connection kept)", at: Date().timeIntervalSince1970)
            run(effects)
            done(true)
        }
    }

    /// The band did not answer GET_CLOCK in time.
    func clockTimedOut(after seconds: Int) {
        queue.async { [self] in
            guard var current = session, current.phase == .hello else { return }
            trace.add("No answer to GET_CLOCK after \(seconds) s: setting the clock anyway, then downloading", at: Date().timeIntervalSince1970)
            let effects = current.clockTimedOut(now: Date().timeIntervalSince1970)
            session = current
            run(effects)
        }
    }

    /// Watchdog: if the band sent nothing for `limit` seconds during the download, ask again.
    func checkStall(after limit: TimeInterval) {
        queue.async { [self] in
            guard var current = session, current.phase == .syncing,
                  Date().timeIntervalSince(lastActivity) > limit else { return }
            trace.add("WATCHDOG: no data for \(Int(limit)) s", at: Date().timeIntervalSince1970)
            lastActivity = Date()
            let effects = current.stalled()
            session = current
            run(effects)
        }
    }

    func setLive(_ on: Bool) {
        queue.async { [self] in
            guard var current = session else { return }
            let effects = current.setLive(on)
            session = current
            run(effects)
        }
    }

    /// The connection is over: forget the session (a late save confirmation is then ignored).
    func end() {
        queue.async { [self] in session = nil }
    }

    // MARK: - Called on the Bluetooth queue

    func receive(characteristic: String, bytes: [UInt8]) {
        lastActivity = Date()
        guard var current = session else {
            trace.add("RX (no session) \(characteristic) len=\(bytes.count) \(Whoop.hex(bytes))", at: Date().timeIntervalSince1970)
            return
        }
        let effects = current.receive(characteristic: characteristic, bytes: bytes, now: Date().timeIntervalSince1970)
        session = current
        run(effects)
    }

    // MARK: - Internals (on `queue`)

    private func run(_ effects: [BandSession.Effect]) {
        var forMain: [BandSession.Effect] = []
        for effect in effects {
            switch effect {
            case .write(let bytes, _):
                link?.write(bytes)
            case .trace(let line):
                trace.add(line, at: Date().timeIntervalSince1970)
            case .persist(let records, let token):
                save(records, token: token)
            default:
                forMain.append(effect)
            }
        }
        let bad = session?.badFrames ?? reportedBadFrames
        // Most notifications change nothing on screen: then the main thread isn't bothered at all.
        guard !forMain.isEmpty || bad != reportedBadFrames else { return }
        reportedBadFrames = bad
        toMain(forMain, bad)
    }

    /// Saves one batch in the background (one transaction). Only when that is done does the band get its ack.
    private func save(_ records: [Whoop.HistoryRecord], token: [UInt8]) {
        let importer = self.importer
        let started = Date()
        trace.add(MotionCheck.traceLine(records), at: started.timeIntervalSince1970)
        Task.detached { [self] in
            do {
                try await importer.save(records, source: .history)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                // Raw copy before the ack (the band frees the batch after it). Never blocks the sync.
                let raw: String
                switch RawHistoryArchive.append(records) {
                case .kept: raw = ""
                case .full: raw = " (raw copy: archive full, not kept)"
                case .failed(let why): raw = " (raw copy failed: \(why))"
                }
                queue.async { [self] in
                    guard var current = session else { return }
                    trace.add("SAVED \(records.count) records in \(ms) ms\(raw): sending ack", at: Date().timeIntervalSince1970)
                    lastActivity = Date()
                    let effects = current.didPersist(token: token, recordCount: records.count)
                    session = current
                    run(effects)
                }
            } catch {
                let message = error.localizedDescription
                queue.async { [self] in
                    trace.add("SAVE FAILED: \(message)", at: Date().timeIntervalSince1970)
                    session = nil
                    toMain([.failed("Could not save the band's data: \(message)")], reportedBadFrames)
                }
            }
        }
    }
}
