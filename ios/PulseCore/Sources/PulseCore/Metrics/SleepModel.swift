import Foundation

/// The chance of being asleep, minute by minute. Spec: docs/METRICS.md §4.
///
/// Each signal gives evidence for asleep or awake, the evidence is added up (a naive Bayes model),
/// and a two-state hidden Markov model smooths the result over time. The model then learns from the
/// person's own nights and sleep edits, and runs again.
public enum SleepModel {
    /// One bell curve. Only differences between two curves are used, so the constant term is left out.
    struct Curve: Sendable, Equatable {
        var mean: Double
        var sd: Double

        func logDensity(_ x: Double) -> Double {
            let z = (x - mean) / sd
            return -log(sd) - 0.5 * z * z
        }
    }

    /// How one signal behaves asleep and awake.
    struct Signal: Sendable, Equatable {
        var asleep: Curve
        var awake: Curve

        /// Signals overlap (a still wrist and a low heart rate go together), so each counts for less
        /// than it would alone, and no single minute of one signal can decide the answer.
        func evidence(_ x: Double) -> Double {
            min(maxEvidence, max(-maxEvidence, signalWeight * (asleep.logDensity(x) - awake.logDensity(x))))
        }
    }

    static let signalWeight = 0.6
    static let maxEvidence = 3.0
    /// Being still and steady doesn't prove sleep: people sit still while awake. Without a heart rate
    /// that also points to sleep, each of the two adds at most this much.
    static let maxStillnessEvidence = 0.4
    /// A sleep starts with this many minutes in a row asleep. Shorter quiet spells before a wake-up don't count.
    static let persistentSleepMinutes = 30
    /// A break this long after a short quiet spell means the person hadn't really fallen asleep yet.
    static let onsetWakeMinutes = 10
    /// A minute with no band data says nothing either way.
    static let noDataEvidence = 0.0
    /// A stretch with no band data longer than this is not assumed to be part of the sleep around it.
    static let longestUnknownBridge = 180

    /// Chance per minute of falling asleep, and of waking up (the hidden Markov model's transitions).
    static let fallingAsleep = 1.0 / 720
    static let wakingUp = 1.0 / 240

    /// How many labelled minutes the starting values count for when they are blended with the person's own.
    static let priorMinutes = 300.0
    /// Minutes of each kind needed before a signal with no starting values can be used.
    static let minimumLearnedMinutes = 120.0
    /// One minute the user labelled by editing a sleep counts as this many minutes the model labelled itself.
    static let editWeight = 5.0
    /// Rounds of learning from the previous result.
    static let learningRounds = 2
    /// Nights of data before the model adapts to the person. Until then it uses the starting values.
    static let nightsBeforeLearning = 3.0

    /// Starting values, before the model has seen the person's own nights.
    static let startingHeartRateDrop = Signal(asleep: Curve(mean: 15, sd: 6), awake: Curve(mean: -5, sd: 9))
    static let startingMovement = Signal(asleep: Curve(mean: 0.15, sd: 0.35), awake: Curve(mean: 1.4, sd: 0.8))
    static let startingUnsteadiness = Signal(asleep: Curve(mean: 2.5, sd: 1.3), awake: Curve(mean: 7, sd: 3.5))

    // MARK: - Measurements

    /// What the band measured, per minute. nil = no value for that minute.
    struct Measurements {
        var heartRate: [Double?]
        /// ln(1 + movement).
        var movement: [Double?]
        /// Standard deviation of the minute heart rates in the 15 minutes around this one.
        var unsteadiness: [Double?]
        /// Clean beats per minute over the 5 minutes around this one. All nil if the band reports no beats.
        var cleanBeats: [Double?]
        /// ln(RMSSD) over the 5 minutes around this one.
        var hrv: [Double?]
        /// Minute of the local day, 0..<1440.
        var clock: [Int]
    }

    /// Beat results per minute. Each minute is cleaned alone, and pairs never cross from one minute to the next.
    struct MinuteBeats: Sendable, Equatable {
        var beats: [UInt16]
        var pairs: [UInt16]
        var squares: [Double]
    }

    /// Cleans the beats of every minute, taking unchanged minutes of the latest week from the cache.
    static func minuteBeats(_ tl: MetricsEngine.Timeline, fingerprints: [UInt64]? = nil,
                            reusing recent: SleepModelCache.Recent? = nil) -> MinuteBeats {
        let n = tl.count
        var out = MinuteBeats(beats: [UInt16](repeating: 0, count: n), pairs: [UInt16](repeating: 0, count: n),
                              squares: [Double](repeating: 0, count: n))
        let known = recent?.start == tl.start ? recent : nil
        for i in 0..<n where !tl.rr[i].isEmpty {
            if let known, let fingerprints, i < known.fingerprints.count, known.fingerprints[i] == fingerprints[i] {
                out.beats[i] = known.beats.beats[i]
                out.pairs[i] = known.beats.pairs[i]
                out.squares[i] = known.beats.squares[i]
                continue
            }
            let clean = HRV.cleanBeats(tl.rr[i])
            var previous: Double?
            for beat in clean {
                if let beat {
                    out.beats[i] += 1
                    if let previous {
                        out.pairs[i] += 1
                        out.squares[i] += (beat - previous) * (beat - previous)
                    }
                }
                previous = beat
            }
        }
        return out
    }

    static func measurements(_ tl: MetricsEngine.Timeline, calendar: Calendar, beats known: MinuteBeats? = nil) -> Measurements {
        let n = tl.count
        let movement = tl.movement.map { $0.map { log(1 + $0) } }

        var unsteadiness = [Double?](repeating: nil, count: n)
        for i in 0..<n where tl.hr[i] != nil {
            let window = max(0, i - 7)..<min(n, i + 8)
            var count = 0.0, sum = 0.0
            for j in window { if let rate = tl.hr[j] { count += 1; sum += rate } }
            guard count >= 5 else { continue }
            let mean = sum / count
            var spread = 0.0
            for j in window { if let rate = tl.hr[j] { spread += (rate - mean) * (rate - mean) } }
            unsteadiness[i] = (spread / (count - 1)).squareRoot()
        }

        let perMinute = known ?? minuteBeats(tl)
        let worn = tl.hr.filter { $0 != nil }.count
        let bandReportsBeats = worn > 0 && Double(perMinute.beats.filter { $0 > 0 }.count) >= 0.1 * Double(worn)
        var cleanBeats = [Double?](repeating: nil, count: n)
        var hrv = [Double?](repeating: nil, count: n)
        if bandReportsBeats {
            for i in 0..<n where tl.hr[i] != nil {
                let window = max(0, i - 2)..<min(n, i + 3)
                var beats = 0, count = 0, total = 0.0
                for j in window {
                    beats += Int(perMinute.beats[j])
                    count += Int(perMinute.pairs[j])
                    total += perMinute.squares[j]
                }
                cleanBeats[i] = Double(beats) / Double(window.count)
                if count >= 20, total > 0 { hrv[i] = log((total / Double(count)).squareRoot()) }
            }
        }

        var clock = [Int](repeating: 0, count: n)
        var current = 0
        for i in 0..<n {
            if i % 60 == 0 {
                let parts = calendar.dateComponents([.hour, .minute], from: tl.date(i))
                current = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
            clock[i] = current
            current = (current + 1) % 1440
        }
        return Measurements(heartRate: tl.hr, movement: movement, unsteadiness: unsteadiness,
                            cleanBeats: cleanBeats, hrv: hrv, clock: clock)
    }

    // MARK: - The person's awake heart rate

    /// The person's awake heart rate around each minute, from the 24 hours before it (the 24 hours after it
    /// when there are too few before). Before anything is labelled, the 65th percentile stands in for it,
    /// because a day is mostly awake and sleep holds the lowest heart rates.
    static func awakeHeartRate(_ hr: [Double?], awake: [Bool]?, fallback earlier: Double? = nil) -> [Double?] {
        let n = hr.count, step = 180
        var byStep: [Double?] = []
        for block in stride(from: 0, to: max(n, 1), by: step) {
            let end = min(n, block + step)
            func values(_ range: Range<Int>) -> [Double] {
                range.filter { awake?[$0] ?? true }.compactMap { hr[$0] }
            }
            // The first day has no 24 hours behind it yet, so it looks at the whole of that day.
            var rates = values(max(0, end - 1440)..<max(end, min(n, 1440)))
            if rates.count < 60 { rates = values(block..<min(n, block + 1440)) }
            if rates.count < 60 { byStep.append(nil); continue }
            byStep.append(awake == nil ? Stats.lowerPercentile(rates, 0.65) : Stats.median(rates))
        }
        let known = byStep.compactMap { $0 }
        let fallback = known.isEmpty ? earlier : Stats.median(known)
        return (0..<n).map { byStep[$0 / step] ?? fallback }
    }

    // MARK: - Time of day

    /// Typical chance of being asleep at each minute of the day, before the person's own nights are known.
    static func usualSleepChance(minuteOfDay: Int) -> Double {
        let hours = Double(minuteOfDay) / 60
        let fromMiddle = abs(hours - 3.5)
        let distance = min(fromMiddle, 24 - fromMiddle)
        return 0.03 + 0.87 / (1 + exp((distance - 4.5) / 0.75))
    }

    /// Evidence from the clock: typical sleep hours, moved toward the hours this person really sleeps.
    static func clockEvidence(nights: [Range<Int>], clock: [Int]) -> [Double] {
        clockEvidence(asleepCounts: adding(nights, clock: clock, to: [Double](repeating: 0, count: 1440)), nights: Double(nights.count))
    }

    private static func adding(_ nights: [Range<Int>], clock: [Int], to counts: [Double]) -> [Double] {
        var out = counts
        for night in nights { for i in night { out[clock[i]] += 1 } }
        return out
    }

    static func clockEvidence(asleepCounts: [Double], nights count: Double) -> [Double] {
        let priorNights = 3.0
        let chance = (0..<1440).map { (priorNights * usualSleepChance(minuteOfDay: $0) + asleepCounts[$0]) / (priorNights + count) }
        return (0..<1440).map { minute in
            let nearby = (-15...15).map { chance[(minute + $0 + 1440) % 1440] }
            let p = min(0.98, max(0.02, Stats.mean(nearby)))
            return min(0.8, max(-0.8, 0.25 * log(p / (1 - p))))
        }
    }

    // MARK: - Smoothing

    /// Forward-backward over two states. Returns P(asleep) per minute given every minute's evidence.
    static func smoothed(_ evidence: [Double]) -> [Double] {
        let n = evidence.count
        guard n > 0 else { return [] }
        let ratio = evidence.map { exp($0) }
        var forward = [Double](repeating: 0, count: n)
        var p = fallingAsleep / (fallingAsleep + wakingUp)
        for i in 0..<n {
            let predicted = i == 0 ? p : p * (1 - wakingUp) + (1 - p) * fallingAsleep
            p = predicted * ratio[i] / (predicted * ratio[i] + 1 - predicted)
            forward[i] = p
        }
        var backward = 1.0
        var out = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            let f = min(1 - 1e-12, max(1e-12, forward[i]))
            let odds = f / (1 - f) * backward
            out[i] = odds / (1 + odds)
            let next = ratio[i] * backward
            backward = min(1e12, max(1e-12, ((1 - wakingUp) * next + wakingUp) / (fallingAsleep * next + 1 - fallingAsleep)))
        }
        return out
    }

    // MARK: - Learning

    /// A label for one minute, with how much it counts.
    struct Label { var asleep: Bool; var weight: Double }

    /// Labels from the last result, with the user's edits on top.
    static func labels(probability: [Double], corrections: [SleepCorrection], timeline tl: MetricsEngine.Timeline) -> [Label?] {
        var out: [Label?] = probability.indices.map { i in
            guard tl.hr[i] != nil else { return nil }       // nothing was measured, so there is nothing to learn
            if probability[i] >= 0.8 { return Label(asleep: true, weight: 1) }
            return probability[i] <= 0.2 ? Label(asleep: false, weight: 1) : nil
        }
        func mark(_ from: Date, _ to: Date, asleep: Bool) {
            let lo = max(0, tl.index(from)), hi = min(tl.count, tl.index(to))
            guard lo < hi else { return }
            for i in lo..<hi { out[i] = Label(asleep: asleep, weight: editWeight) }
        }
        for correction in corrections.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let start = correction.start, let end = correction.end else {
                mark(correction.detectedStart, correction.detectedEnd, asleep: false)
                continue
            }
            // Only a time the user moved says they were awake on the other side of it.
            if start != correction.detectedStart { mark(start.addingTimeInterval(-3600), start, asleep: false) }
            if end != correction.detectedEnd { mark(end, end.addingTimeInterval(3600), asleep: false) }
            mark(start, end, asleep: true)
        }
        return out
    }

    private static func weighted(_ values: [Double?], labels: [Label?], asleep: Bool) -> (x: [Double], w: [Double]) {
        var x: [Double] = [], w: [Double] = []
        for (value, label) in zip(values, labels) {
            if let value, let label, label.asleep == asleep {
                x.append(value)
                w.append(label.weight)
            }
        }
        return (x, w)
    }

    private static func blended(_ start: Curve, _ data: (x: [Double], w: [Double]), strength: Double, minimumSD: Double) -> Curve {
        let total = data.w.reduce(0, +)
        let sum = zip(data.x, data.w).reduce(0.0) { $0 + $1.0 * $1.1 }
        let mean = (strength * start.mean + sum) / (strength + total)
        let spread = zip(data.x, data.w).reduce(0.0) { $0 + $1.1 * ($1.0 - mean) * ($1.0 - mean) }
        let variance = (strength * start.sd * start.sd + spread) / (strength + total)
        return Curve(mean: mean, sd: max(minimumSD, variance.squareRoot()))
    }

    /// A signal with starting values, moved toward what the person's labelled minutes show.
    static func learned(_ start: Signal, values: [Double?], labels: [Label?], minimumSD: Double) -> Signal {
        Signal(asleep: blended(start.asleep, weighted(values, labels: labels, asleep: true), strength: priorMinutes, minimumSD: minimumSD),
               awake: blended(start.awake, weighted(values, labels: labels, asleep: false), strength: priorMinutes, minimumSD: minimumSD))
    }

    /// A signal with no starting values. Both curves start out equal, so it only counts as far as the
    /// person's own minutes tell asleep from awake. If they don't, it adds nothing.
    static func learnedFromScratch(values: [Double?], labels: [Label?], minimumSD: Double) -> Signal? {
        let asleep = weighted(values, labels: labels, asleep: true), awake = weighted(values, labels: labels, asleep: false)
        guard asleep.w.reduce(0, +) >= minimumLearnedMinutes, awake.w.reduce(0, +) >= minimumLearnedMinutes else { return nil }
        let both = (x: asleep.x + awake.x, w: asleep.w + awake.w)
        let pooled = blended(Curve(mean: 0, sd: 1), both, strength: 0, minimumSD: minimumSD)
        return Signal(asleep: blended(pooled, asleep, strength: priorMinutes, minimumSD: minimumSD),
                      awake: blended(pooled, awake, strength: priorMinutes, minimumSD: minimumSD))
    }

    // MARK: - Running it

    /// What the model knows at the end of a week, and carries into the next one.
    struct Learned: Sendable, Equatable {
        var heartRate = startingHeartRateDrop
        var movement = startingMovement
        var unsteadiness = startingUnsteadiness
        var cleanBeats: Signal?
        var hrv: Signal?
        /// Nights asleep at each minute of the day, and how many nights that is.
        var asleepCounts = [Double](repeating: 0, count: 1440)
        var nights = 0.0
        var awakeRate: Double?
    }

    private static func nights(in labels: [Label?]) -> [Range<Int>] {
        SleepDetector.sessions(labels.map { $0?.asleep == true }, minSeed: 15, maxGap: 30, minSession: 180,
                               restlessGap: 30).map { $0.start..<$0.end }
    }

    /// One week: P(asleep) per minute, and what the model knows afterwards.
    static func calculate(_ tl: MetricsEngine.Timeline, calendar: Calendar, corrections: [SleepCorrection],
                          from start: Learned, beats: MinuteBeats? = nil) -> (probability: [Double], learned: Learned) {
        let measured = measurements(tl, calendar: calendar, beats: beats)
        var now = start
        var baseline = awakeHeartRate(tl.hr, awake: nil, fallback: start.awakeRate)
        var clock = clockEvidence(asleepCounts: start.asleepCounts, nights: start.nights)
        var result: [Double] = []

        for round in 0...learningRounds {
            let drop: [Double?] = tl.hr.indices.map { i in
                guard let rate = tl.hr[i], let awake = baseline[i], awake > 0 else { return nil }
                return 100 * (awake - rate) / awake
            }
            if round > 0 {
                let known = labels(probability: result, corrections: corrections, timeline: tl)
                baseline = awakeHeartRate(tl.hr, awake: known.map { $0?.asleep == false }, fallback: start.awakeRate)
                let found = nights(in: known)
                if start.nights + Double(found.count) >= nightsBeforeLearning {
                    now.heartRate = learned(start.heartRate, values: drop, labels: known, minimumSD: 3)
                    now.movement = learned(start.movement, values: measured.movement, labels: known, minimumSD: 0.15)
                    now.unsteadiness = learned(start.unsteadiness, values: measured.unsteadiness, labels: known, minimumSD: 0.8)
                    now.cleanBeats = start.cleanBeats.map { learned($0, values: measured.cleanBeats, labels: known, minimumSD: 3) }
                        ?? learnedFromScratch(values: measured.cleanBeats, labels: known, minimumSD: 3)
                    now.hrv = start.hrv.map { learned($0, values: measured.hrv, labels: known, minimumSD: 0.1) }
                        ?? learnedFromScratch(values: measured.hrv, labels: known, minimumSD: 0.1)
                    clock = clockEvidence(asleepCounts: adding(found, clock: measured.clock, to: start.asleepCounts),
                                          nights: start.nights + Double(found.count))
                }
            }
            let evidence: [Double] = tl.hr.indices.map { i in
                guard tl.hr[i] != nil else { return noDataEvidence }
                var total = clock[measured.clock[i]]
                let heartRateEvidence = drop[i].map { now.heartRate.evidence($0) } ?? 0
                total += heartRateEvidence
                let stillnessLimit = heartRateEvidence > 0 ? maxEvidence : maxStillnessEvidence
                if let x = measured.movement[i] { total += min(stillnessLimit, now.movement.evidence(x)) }
                if let x = measured.unsteadiness[i] { total += min(stillnessLimit, now.unsteadiness.evidence(x)) }
                if let x = measured.cleanBeats[i], let signal = now.cleanBeats { total += signal.evidence(x) }
                if let x = measured.hrv[i], let signal = now.hrv { total += signal.evidence(x) }
                return total
            }
            result = smoothed(evidence)
        }

        let found = nights(in: labels(probability: result, corrections: corrections, timeline: tl))
        now.asleepCounts = adding(found, clock: measured.clock, to: start.asleepCounts)
        now.nights = start.nights + Double(found.count)
        let rates = baseline.compactMap { $0 }
        now.awakeRate = rates.isEmpty ? start.awakeRate : Stats.median(rates)
        return (result, now)
    }

    /// Weeks run from 17:00 to 17:00, when almost nobody is asleep, counted from a fixed day so that
    /// adding older data never moves them.
    static func weeks(of tl: MetricsEngine.Timeline, calendar: Calendar) -> [Range<Int>] {
        guard tl.count > 0, let reference = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 17)) else { return [] }
        let days = calendar.dateComponents([.day], from: reference, to: tl.start).day ?? 0
        var weeksSince = Int((Double(days) / 7).rounded(.down)) - 1
        var ranges: [Range<Int>] = []
        var lower = 0
        while lower < tl.count {
            weeksSince += 1
            guard let boundary = calendar.date(byAdding: .day, value: (weeksSince + 1) * 7, to: reference) else { break }
            let upper = min(tl.count, tl.index(boundary))
            if upper > lower {
                ranges.append(lower..<upper)
                lower = upper
            }
        }
        return ranges
    }

    // MARK: - Fingerprints

    private static func mix(_ hash: UInt64, _ word: UInt64) -> UInt64 {
        let h = (hash ^ word) &* 0x9E37_79B9_7F4A_7C15
        return (h << 31) | (h >> 33)
    }

    private static func mix(_ hash: UInt64, _ value: Double?) -> UInt64 {
        mix(hash, value?.bitPattern ?? 0xFFF8_DEAD_BEEF_0001)
    }

    private static func fingerprint(_ tl: MetricsEngine.Timeline, minute i: Int) -> UInt64 {
        var h = mix(mix(mix(0xCBF2_9CE4_8422_2325, tl.hr[i]), tl.activity[i]), tl.movement[i])
        for beat in tl.rr[i] { h = mix(h, beat.bitPattern) }
        return h
    }

    private static func fingerprint(_ signal: Signal?, into hash: UInt64) -> UInt64 {
        guard let signal else { return mix(hash, 0) }
        return [signal.asleep.mean, signal.asleep.sd, signal.awake.mean, signal.awake.sd].reduce(mix(hash, 1)) { mix($0, $1.bitPattern) }
    }

    private static func fingerprint(_ learned: Learned) -> UInt64 {
        var h: UInt64 = 0x1234_5678_9ABC_DEF1
        for signal in [learned.heartRate, learned.movement, learned.unsteadiness] { h = fingerprint(signal, into: h) }
        h = fingerprint(learned.cleanBeats, into: h)
        h = fingerprint(learned.hrv, into: h)
        for count in learned.asleepCounts { h = mix(h, count.bitPattern) }
        return mix(mix(h, learned.nights), learned.awakeRate)
    }

    /// The edits that can change a week, in the order they are applied.
    private static func edits(_ corrections: [SleepCorrection], from: Date, to: Date) -> [SleepCorrection] {
        corrections.filter { c in
            let first = min(c.detectedStart, c.start ?? c.detectedStart).addingTimeInterval(-3600)
            let last = max(c.detectedEnd, c.end ?? c.detectedEnd).addingTimeInterval(3600)
            return first < to && from < last
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private static func slice(_ tl: MetricsEngine.Timeline, _ range: Range<Int>) -> MetricsEngine.Timeline {
        MetricsEngine.Timeline(start: tl.date(range.lowerBound), hr: Array(tl.hr[range]), activity: Array(tl.activity[range]),
                               movement: Array(tl.movement[range]), rr: Array(tl.rr[range]), source: tl.source)
    }

    /// P(asleep) per minute, calculating only the weeks that changed, and what the model knows at the end.
    /// A week taken from the cache keeps the side of 0.5 each minute was on, and whether it was sure.
    static func run(timeline tl: MetricsEngine.Timeline, calendar: Calendar, corrections: [SleepCorrection],
                    cache: inout SleepModelCache) -> (probability: [Double], learned: Learned) {
        let ranges = weeks(of: tl, calendar: calendar)
        var next = SleepModelCache()
        next.recent = cache.recent
        var learned = Learned()
        var probability = [Double](repeating: 0, count: tl.count)
        let zone = calendar.timeZone.identifier.utf8.reduce(UInt64(MetricsEngine.algorithmVersion)) { mix($0, UInt64($1)) }

        for (index, range) in ranges.enumerated() {
            let minutes = range.map { fingerprint(tl, minute: $0) }
            let from = tl.date(range.lowerBound), to = tl.date(range.upperBound)
            let touching = edits(corrections, from: from, to: to)
            var key = mix(mix(zone, fingerprint(learned)), UInt64(bitPattern: Int64(from.timeIntervalSince1970)))
            for minute in minutes { key = mix(key, minute) }
            for c in touching {
                for date in [c.detectedStart, c.detectedEnd, c.createdAt] { key = mix(key, date.timeIntervalSince1970.bitPattern) }
                key = mix(mix(key, c.start?.timeIntervalSince1970), c.end?.timeIntervalSince1970)
            }

            let id = Int64(from.timeIntervalSince1970)
            if let week = cache.weeks[id], week.key == key, week.asleep.count == range.count {
                for (offset, asleep) in week.asleep.enumerated() {
                    let sure = week.sure[offset]
                    probability[range.lowerBound + offset] = asleep ? (sure ? 1 : 0.6) : (sure ? 0 : 0.4)
                }
                learned = week.learned
                next.weeks[id] = week
                next.reusedWeeks += 1
                continue
            }

            let part = slice(tl, range)
            let beats = minuteBeats(part, fingerprints: minutes, reusing: cache.recent)
            let result = calculate(part, calendar: calendar, corrections: touching, from: learned, beats: beats)
            for (offset, p) in result.probability.enumerated() { probability[range.lowerBound + offset] = p }
            learned = result.learned
            next.weeks[id] = SleepModelCache.Week(key: key, asleep: result.probability.map { $0 >= 0.5 },
                                                  sure: result.probability.map { $0 >= 0.8 || $0 <= 0.2 }, learned: learned)
            next.calculatedWeeks += 1
            if index == ranges.count - 1 {
                next.recent = SleepModelCache.Recent(start: part.start, fingerprints: minutes, beats: beats)
            }
        }
        cache = next
        return (probability, learned)
    }

    /// P(asleep) per minute of the timeline, calculated from scratch.
    static func probabilities(timeline tl: MetricsEngine.Timeline, calendar: Calendar,
                              corrections: [SleepCorrection]) -> [Double] {
        var cache = SleepModelCache()
        return run(timeline: tl, calendar: calendar, corrections: corrections, cache: &cache).probability
    }

    // MARK: - When to ask

    /// A sleep is worth asking about when this share of it has no data, or of its measured minutes is unclear.
    static let reviewShare = 0.15

    /// Why Pulse is unsure about a sleep. nil = it is sure enough not to ask.
    static func reviewReason(_ session: SleepDetector.Session, probability: [Double], observed: [Bool],
                             firstMinuteOfDay: Int, learned: Learned) -> SleepReviewReason? {
        let span = session.end - session.start
        let measured = (session.start..<session.end).filter { observed[$0] }
        guard span > 0, !measured.isEmpty else { return nil }
        if Double(span - measured.count) >= reviewShare * Double(span) { return .missingData }
        let unclear = measured.filter { probability[$0] > 0.2 && probability[$0] < 0.8 }.count
        if Double(unclear) >= reviewShare * Double(measured.count) { return .unclear }
        let personal = learned.nights >= nightsBeforeLearning
        let usual = measured.filter { minute in
            let clock = (firstMinuteOfDay + minute - session.start) % 1440
            let typical = usualSleepChance(minuteOfDay: clock)
            guard personal else { return typical >= 0.5 }
            return (3 * typical + learned.asleepCounts[clock]) / (3 + learned.nights) >= 0.5
        }.count
        return usual * 2 < measured.count ? .unusualTime : nil
    }

    /// The sleeps in a run of probabilities: at least 45 minutes long, and wake-ups of up to 30 minutes stay
    /// inside. Falling asleep takes 15 settled minutes, so a quiet moment at a desk doesn't start the night
    /// early. Near the end, 5 minutes are enough to count as dozing off again before getting up.
    /// A sleep starts and ends on minutes the band really measured, and needs 45 of them asleep.
    static func sessions(probability: [Double], observed: [Bool]) -> (sessions: [SleepDetector.Session], asleep: [Bool]) {
        var inSleep = probability.map { $0 >= 0.5 }
        var gap = 0
        while gap < observed.count {
            guard !observed[gap] else { gap += 1; continue }
            var gapEnd = gap
            while gapEnd < observed.count, !observed[gapEnd] { gapEnd += 1 }
            if gapEnd - gap > longestUnknownBridge { for i in gap..<gapEnd { inSleep[i] = false } }
            gap = gapEnd
        }
        let asleep = inSleep.indices.map { inSleep[$0] && observed[$0] }
        let found = SleepDetector.sessions(inSleep, minSeed: 15, maxGap: 30, minSession: 45)
        let extended = found.enumerated().compactMap { index, session -> SleepDetector.Session? in
            let limit = index + 1 < found.count ? found[index + 1].start : asleep.count
            var end = session.end
            var i = end
            while i < limit, i - end <= 30 {
                guard asleep[i] else { i += 1; continue }
                var runEnd = i
                while runEnd < limit, asleep[runEnd] { runEnd += 1 }
                if runEnd - i >= 5 { end = runEnd }
                i = runEnd
            }
            var onset = session.start
            while onset < end {
                var runEnd = onset
                while runEnd < end, inSleep[runEnd] { runEnd += 1 }
                var next = runEnd
                while next < end, !inSleep[next] { next += 1 }
                guard runEnd - onset < persistentSleepMinutes, next - runEnd >= onsetWakeMinutes, next < end else { break }
                onset = next
            }
            let measured = (onset..<end).filter { asleep[$0] }
            guard measured.count >= 45, let first = measured.first, let last = measured.last else { return nil }
            return SleepDetector.session(start: first, end: last + 1, asleep: asleep, observed: observed)
        }
        return (extended, asleep)
    }
}
