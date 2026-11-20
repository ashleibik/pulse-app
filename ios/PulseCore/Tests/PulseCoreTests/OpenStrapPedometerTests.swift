import Foundation
import Testing
@testable import PulseCore

// OpenStrap's own Tier A tests (test/onehz/steps_test.dart at commit e59d63c), with the same synthetic walk and the same
// expected counts, so the port is checked against the original.

/// OpenStrap's `_walk`: a 100 Hz walk with the step bob on z, a little arm swing on x and deterministic noise.
private func walk(_ durationS: Double, _ stepHz: Double, fs: Double = 100, ampG: Double = 0.25, noiseG: Double = 0.01)
    -> ([Double], [Double], [Double]) {
    let n = Int((durationS * fs).rounded())
    var x: [Double] = [], y: [Double] = [], z: [Double] = []
    var seed = 12345
    func rnd() -> Double {
        seed = (seed &* 1_103_515_245 &+ 12345) & 0x7fff_ffff
        return (Double(seed) / Double(0x7fff_ffff) - 0.5) * 2.0
    }
    for i in 0..<n {
        let t = Double(i) / fs
        let s = ampG * sin(2 * .pi * stepHz * t) + 0.25 * ampG * sin(2 * .pi * 2 * stepHz * t)
        x.append(0.3 * ampG * sin(2 * .pi * stepHz * t) + noiseG * rnd())
        y.append(noiseG * rnd())
        z.append(1.0 + s + noiseG * rnd())
    }
    return (x, y, z)
}

@Test func openStrap120SpmForTenSeconds() {
    let (x, y, z) = walk(10, 2)
    let r = OpenStrapPedometer.livePedometer(x, y, z, sampleRateHz: 100)
    #expect((18...22).contains(r.steps), "\(r.steps)")
    #expect(abs(r.cadenceSpm - 120) <= 15)
    #expect(r.confidence > 0.5)
}

@Test func openStrapSlowerCadenceReadsFewerSteps() {
    let slow = walk(20, 1.6), fast = walk(20, 2.2)
    #expect(OpenStrapPedometer.livePedometer(fast.0, fast.1, fast.2).steps > OpenStrapPedometer.livePedometer(slow.0, slow.1, slow.2).steps)
}

@Test func openStrapStillWristAndTinyBuffers() {
    let r = OpenStrapPedometer.livePedometer([Double](repeating: 0, count: 1000), [Double](repeating: 0, count: 1000),
                                             [Double](repeating: 1, count: 1000))
    #expect(r.steps <= 1)
    #expect(OpenStrapPedometer.livePedometer([], [], []).steps == 0)
    #expect(OpenStrapPedometer.livePedometer([1, 2], [0, 0], [1, 1]).steps == 0)
}

@Test func openStrapFidgetingAndGesturesNeverReachTheMinimumRun() {
    var z = [Double](repeating: 1, count: 1000)
    for c in [120, 470, 800] { for k in -10...10 { z[c + k] += 0.3 * cos(.pi * Double(k) / 20) } }
    let zeros = [Double](repeating: 0, count: 1000)
    #expect(OpenStrapPedometer.livePedometer(zeros, zeros, z, sampleRateHz: 100).steps <= 1)

    var z2 = [Double](repeating: 1, count: 1500)
    var c = 100, big = true
    while c < 1500 - 20 {
        let amp = big ? 0.35 : 0.12
        for k in -10...10 { z2[c + k] += amp * cos(.pi * Double(k) / 20) }
        c += big ? 90 : 220
        big.toggle()
    }
    let zeros2 = [Double](repeating: 0, count: 1500)
    #expect(OpenStrapPedometer.livePedometer(zeros2, zeros2, z2, sampleRateHz: 100).steps <= 2)
}

@Test func openStrapRawCountIsExactAcrossCadences() {
    // OpenStrap's measured figures on 300 s of `walk` at 0.25 g, 100 Hz.
    for (spm, want) in [(60.0, 299), (80, 399), (100, 498), (120, 598), (140, 698), (180, 898)] {
        let (x, y, z) = walk(300, spm / 60)
        let got = OpenStrapPedometer.livePedometer(x, y, z).steps
        #expect(got == want, "\(spm) spm: \(got)")
    }
    #expect(OpenStrapPedometer.gain == 1.00)
}

@Test func openStrapChunkBoundaryLossIsFlat() {
    func chunked(_ n: Int) -> Int {
        let (wx, wy, wz) = walk(Double(n) / (110 / 60.0), 110 / 60.0)
        var sig = [Double](repeating: 1, count: 300)
        for i in 0..<wx.count {
            let sum: Double = wx[i] * wx[i] + wy[i] * wy[i] + wz[i] * wz[i]
            sig.append(sum.squareRoot())
        }
        sig += [Double](repeating: 1, count: 300)
        let minutes = stride(from: 0, to: sig.count, by: 6000).map { Array(sig[$0..<min($0 + 6000, sig.count)]) }
        return OpenStrapPedometer.calcSteps(minutes)
    }
    #expect(chunked(100) == 100)
    #expect(chunked(1000) == 991)
    #expect(chunked(10000) == 9910)
}

@Test func openStrapStepIntervalBounds() {
    func stepsAt(_ spm: Double, _ durationS: Double, amp: Double = 0.30, fs: Double = 100, tellRate: Double? = nil) -> Int {
        let (x, y, z) = walk(durationS, spm / 60, fs: fs, ampG: amp)
        return OpenStrapPedometer.livePedometer(x, y, z, sampleRateHz: tellRate ?? fs).steps
    }
    #expect(OpenStrapPedometer.minStepIntervalS == 0.2 && OpenStrapPedometer.maxStepIntervalS == 2.0)
    #expect(stepsAt(305, 120) == 0 && stepsAt(320, 120) == 0 && stepsAt(350, 120) == 0)
    #expect(stepsAt(250, 120) == 498 && stepsAt(300, 120) == 598)
    #expect(stepsAt(40, 600, fs: 50) == 399)
    #expect(stepsAt(25, 600, fs: 50) == 0 && stepsAt(28, 600, fs: 50) == 0)
    #expect(stepsAt(25, 600, fs: 50, tellRate: 100) == 250)
    #expect(stepsAt(110, 600, amp: 0.25, fs: 50) == 1098)
    #expect(stepsAt(120, 300, amp: 0.25) == 598)
}

@Test func openStrapOxWalkConfigurationIsUnchanged() {
    #expect(OpenStrapPedometer.gain == 1.00 && OpenStrapPedometer.sens == 0.10 && OpenStrapPedometer.confirm == 8)
    #expect(OpenStrapPedometer.filter == 8 && OpenStrapPedometer.window == 33 && OpenStrapPedometer.thrOrder == 4)
    #expect(OpenStrapPedometer.maxMinTimeout == 120)
}
