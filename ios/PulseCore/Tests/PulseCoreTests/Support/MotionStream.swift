import Foundation
@testable import PulseCore

/// The band's 100 Hz motion stream for tests: a walk at `stepHz` steps a second as the band would send it, one packet a second
/// in raw counts (4096 per g). `ampG` 0 is a still wrist.
func walkPackets(seconds: Int, stepHz: Double, ampG: Double = 0.25, from first: UInt32) -> [Whoop.RawMotion] {
    (0..<seconds).map { second in
        var axes: [[Int16]] = [[], [], []]
        for i in 0..<100 {
            let t = Double(second) + Double(i) / 100
            let bob = ampG * sin(2 * .pi * stepHz * t) + 0.25 * ampG * sin(2 * .pi * 2 * stepHz * t)
            axes[0].append(Int16((0.3 * ampG * sin(2 * .pi * stepHz * t) * 4096).rounded()))
            axes[1].append(0)
            axes[2].append(Int16(((1 + bob) * 4096).rounded()))
        }
        return Whoop.RawMotion(timestamp: first + UInt32(second), subsec: 0, heartRate: 95, accel: axes)
    }
}
