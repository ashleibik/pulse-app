import Foundation
import PulseCore

/// A copy of the band's raw history records, for the first nights on this band.
///
/// Why: heart rate is decoded reliably, but where each record keeps the beat-to-beat (RR) intervals
/// and the motion data is still a guess (re-toolkit/docs/PROTOCOL.md). Those feed HRV and sleep, and
/// once a batch is acked the band frees it. With this file the first nights can be decoded again
/// after the guess is checked, instead of being lost.
///
/// Format: per record, a u16 little-endian length, then that many bytes (the frame's inner bytes).
/// Local only (excluded from iCloud backup, never uploaded). Stops at `limitBytes`, about 3 weeks.
enum RawHistoryArchive {
    static let limitBytes = 60_000_000
    private static let lock = NSLock()

    static var url: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("raw-history.bin")
    }

    static var sizeBytes: Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    enum Result { case kept, full, failed(String) }

    /// Appends one saved batch. The sync goes on whatever this returns.
    static func append(_ records: [Whoop.HistoryRecord]) -> Result {
        lock.lock()
        defer { lock.unlock() }
        var data = Data()
        for record in records where !record.raw.isEmpty {
            let n = UInt16(clamping: record.raw.count)
            data.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8)])
            data.append(contentsOf: record.raw.prefix(Int(n)))
        }
        guard !data.isEmpty else { return .kept }
        guard sizeBytes + data.count <= limitBytes else { return .full }
        do {
            var file = url
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? file.setResourceValues(values)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return .kept
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func delete() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
