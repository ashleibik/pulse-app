import Foundation
@testable import PulseCore

/// Simulated wrist motion for the step tests. Test support only: the app never shows simulated data.
///
/// It makes what the band stores, one record a second, and the tests read it through the same code a sync uses
/// (`MinuteBuilder`, `WristAngle`). The motion: the arm swings once every two steps, each step jolts the wrist, and
/// stride timing wanders by a few percent, so a once-a-second reading lands at a different point of the stride each
/// time. Sizes stay inside what the owner's band really reported (0.53 to 1.71 g on 2026-11-19), and readings
/// outside the decoder's 0.5 to 1.8 g are dropped as the decoder drops them.
enum WristSimulator {
    enum Activity: Equatable {
        /// Steps per second.
        case walk(Double)
        case run(Double)
        case stairs(Double)
        case typing
        case driving
        case sleeping
        /// Sitting and talking with the hands.
        case gesturing
        case standing
    }

    struct Segment {
        var activity: Activity
        var seconds: Int
        var heartRate: Int

        init(_ activity: Activity, minutes: Double, heartRate: Int) {
            self.activity = activity
            self.seconds = Int((minutes * 60).rounded())
            self.heartRate = heartRate
        }
    }

    private struct Motion {
        var cadence = 0.0, swing = 0.0, basePitch = 0.0, lever = 0.0, bounce = 0.0, shock = 0.0, noise = 0.003, wobble = 0.002
    }

    private static func motion(_ activity: Activity) -> Motion {
        switch activity {
        case .walk(let c): Motion(cadence: c, swing: 0.35, basePitch: 0, lever: 0.6, bounce: 0.2, shock: 0.15, noise: 0.02, wobble: 0.03)
        case .run(let c): Motion(cadence: c, swing: 0.6, basePitch: 1.2, lever: 0.35, bounce: 0.35, shock: 0.25, noise: 0.03, wobble: 0.05)
        case .stairs(let c): Motion(cadence: c, swing: 0.15, basePitch: 0.2, lever: 0.6, bounce: 0.3, shock: 0.2, noise: 0.02, wobble: 0.03)
        case .typing: Motion(basePitch: 1.5, noise: 0.012, wobble: 0.01)
        case .driving: Motion(basePitch: 0.9, noise: 0.05, wobble: 0.01)
        case .sleeping: Motion(basePitch: 1.4, noise: 0.003, wobble: 0.002)
        case .gesturing: Motion(basePitch: 1.3, noise: 0.02, wobble: 0.02)
        case .standing: Motion(basePitch: 0.1, noise: 0.01, wobble: 0.01)
        }
    }

    /// How many steps were really taken.
    static func trueSteps(_ segments: [Segment], seed: UInt64 = 1) -> Int {
        simulate(segments, start: Date(timeIntervalSince1970: 0), seed: seed).steps
    }

    /// The band's records, one per second from `start`.
    static func records(_ segments: [Segment], start: Date, seed: UInt64 = 1) -> [Whoop.HistoryRecord] {
        simulate(segments, start: start, seed: seed).records
    }

    /// The minutes a sync would save from those records.
    static func minutes(_ segments: [Segment], start: Date, seed: UInt64 = 1) -> [MinuteSample] {
        let records = records(segments, start: start, seed: seed)
        return WristAngle.adding(to: MinuteBuilder.minutes(from: records), from: records)
    }

    private static func simulate(_ segments: [Segment], start: Date, seed: UInt64) -> (records: [Whoop.HistoryRecord], steps: Int) {
        var random = SeededRandom(seed: seed)
        var records: [Whoop.HistoryRecord] = []
        var phase = random.uniform(0...(2 * .pi))
        var steps = 0.0
        var second = 0
        // Events: a slow turn of the wrist (pitch, roll) that comes and goes, or a new resting position.
        var eventLeft = 0, eventLength = 1, eventPitch = 0.0, eventRoll = 0.0
        var posture = 0.0
        var nextEvent = 0
        for segment in segments {
            let m = motion(segment.activity)
            nextEvent = second + eventGap(segment.activity, &random)
            for _ in 0..<segment.seconds {
                // Stride timing wanders: each second's cadence is a few percent off.
                let cadence = m.cadence * (1 + random.normal(sd: 0.03))
                phase += 2 * .pi * cadence
                steps += cadence

                if second >= nextEvent, eventLeft == 0 {
                    switch segment.activity {
                    case .typing:
                        eventLength = 2; eventPitch = random.uniform(0.15...0.35); eventRoll = random.uniform(-0.2...0.2)
                    case .gesturing:
                        eventLength = Int(random.uniform(2...4)); eventPitch = random.uniform(0.3...0.7); eventRoll = random.uniform(-0.5...0.5)
                    case .driving:
                        eventLength = 6; eventPitch = random.uniform(-0.1...0.1); eventRoll = random.uniform(0.3...1.0) * (random.chance(0.5) ? 1 : -1)
                    case .sleeping:
                        eventLength = 4; eventPitch = 0; eventRoll = 0
                        posture = random.uniform(-1.2...1.2)
                    default:
                        eventLength = 1; eventPitch = 0; eventRoll = 0
                    }
                    eventLeft = eventLength
                    nextEvent = second + eventGap(segment.activity, &random)
                }
                var pitch = m.basePitch + posture * (segment.activity == .sleeping ? 1 : 0) + m.swing * sin(phase / 2)
                    + random.normal(sd: m.wobble)
                var roll = random.normal(sd: m.wobble)
                var extraNoise = 0.0
                if eventLeft > 0 {
                    // Rises and falls over the event (a bump shape), so the wrist turns there and back.
                    let progress = Double(eventLength - eventLeft) / Double(max(1, eventLength - 1))
                    let shape = sin(.pi * min(1, max(0, progress)))
                    pitch += eventPitch * shape
                    roll += eventRoll * shape
                    if segment.activity == .gesturing { pitch += 0.4 * sin(Double(second) * 2.1) }
                    if segment.activity == .sleeping { extraNoise = 0.25 }
                    eventLeft -= 1
                }
                let up = [-cos(pitch), sin(pitch) * sin(roll), sin(pitch) * cos(roll)]
                let tangent = [sin(pitch), 0, cos(pitch)]
                let armRate = Double.pi * m.cadence
                // The band's stored reading is smoothed (it never passed 1.71 g on a real day), so a third of the swing's peak.
                let swingAccel = m.cadence > 0 ? -(m.lever * m.swing * armRate * armRate / 9.81) * sin(phase / 2) * 0.35 : 0
                let bounce = m.bounce * sin(phase)
                let jolt = m.cadence > 0 ? m.shock : 0
                var accel = (0..<3).map { axis in
                    up[axis] * (1 + bounce) + tangent[axis] * swingAccel
                        + random.normal(sd: m.noise) + random.normal(sd: jolt) + random.normal(sd: extraNoise)
                }
                let size2 = accel.reduce(0) { $0 + $1 * $1 }
                if !(0.25...3.24).contains(size2) { accel = [] }
                let heart = segment.heartRate + Int(random.normal(sd: 2).rounded())
                records.append(Whoop.HistoryRecord(version: 24, counter: UInt32(second), timestamp: UInt32(start.timeIntervalSince1970) + UInt32(second),
                                                   subsec: 0, heartRate: max(30, heart), accelG: accel.isEmpty ? nil : accel,
                                                   rrMsUnverified: [], length: 88))
                second += 1
            }
        }
        return (records, Int(steps.rounded(.down)))
    }

    private static func eventGap(_ activity: Activity, _ random: inout SeededRandom) -> Int {
        switch activity {
        case .typing: Int(random.uniform(15...45))
        case .gesturing: Int(random.uniform(5...20))
        case .driving: Int(random.uniform(10...30))
        case .sleeping: Int(random.uniform(1200...2400))
        default: Int.max / 2
        }
    }
}
