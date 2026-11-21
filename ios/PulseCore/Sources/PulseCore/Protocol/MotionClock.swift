import Foundation

/// Gives each second of the band's 100 Hz motion stream its time on the phone's clock (docs/METRICS.md §15).
///
/// The packet's own time field (`RawMotion.timestamp`, inner bytes 11 to 15 in NOOP's layout for firmware 41.17.6.0) is not
/// the time on the owner's band (firmware 41.11.7.0): the backup of 2026-11-21 had its step minutes dated June 2023 and May
/// 2038, one second each, and the counter dropped nearly every other second as a repeat, so no step was ever counted. The
/// readings themselves were right (about 1 g at rest). Each motion packet is one second of readings and they arrive in order,
/// so they are numbered on from the phone's clock: the next packet is the next second, and after a pause the phone's clock
/// starts the count again.
public struct MotionClock: Sendable, Equatable {
    /// A packet more than this many seconds later than the next second starts again at the phone's time (a pause).
    public static let restartAfter: UInt32 = 3

    private var last: UInt32?
    private var lastMotion: Whoop.RawMotion?

    public init() {}

    /// The packet's second in unix time, or nil for the same packet again (every field equal: sent twice).
    public mutating func second(for motion: Whoop.RawMotion, receivedAt now: Double) -> UInt32? {
        if let lastMotion, lastMotion == motion { return nil }
        lastMotion = motion
        let phone = UInt32(clamping: Int64(now.rounded(.down)))
        let next: UInt32
        if let last, phone <= last &+ Self.restartAfter {
            next = last &+ 1            // on time, or a burst that waited in Bluetooth: seconds stay one after another
        } else {
            next = phone                // the first packet, or after a pause
        }
        last = next
        return next
    }
}
