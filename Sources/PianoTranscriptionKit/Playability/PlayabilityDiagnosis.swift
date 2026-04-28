import Foundation

/// One physically-impossible event detected by the playability diagnoser.
/// The repair engine consumes these to drive targeted fixes; the inspector
/// surfaces them in the Data Flow section so users can see *why* a repair
/// happened, not just that it happened.
public struct PlayabilityIssue: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case impossibleSpan        // hand asked to span > maxHandSpan
        case tooManySimultaneous   // > 5 fingers required at once
        case keyboardSpread        // chord straddles too wide a section of keyboard
        case impossibleJump        // same hand jumped too far in too little time
        case sustainConflict       // a sustained note prevents an impossible reach for another note in the same hand
    }

    public let kind: Kind
    public let hand: PianoHand
    /// Best-effort timestamp anchoring the issue. For chord/span issues it
    /// is the cluster onset; for jump/sustain issues it is the *later* note.
    public let timestamp: Double
    /// Pitches involved (newly-onset notes for clusters; the two endpoints
    /// for jumps; the held + new note for sustain conflicts).
    public let pitches: [Int]
    /// Numeric severity used by the repair engine to prioritize. 0…1, higher
    /// is worse.
    public let severity: Double
    /// Human-readable description for logging / Data Flow.
    public let detail: String

    public init(kind: Kind, hand: PianoHand, timestamp: Double, pitches: [Int], severity: Double, detail: String) {
        self.kind = kind
        self.hand = hand
        self.timestamp = timestamp
        self.pitches = pitches
        self.severity = severity
        self.detail = detail
    }
}

/// Per-hand statistics surfaced by the diagnoser.
public struct PlayabilityHandStats: Sendable, Equatable {
    public let hand: PianoHand
    public let noteCount: Int
    public let maxSimultaneous: Int
    public let maxSpanSemitones: Int
    public let maxJumpSemitonesPerSecond: Double
    public let impossibleSpanCount: Int
    public let impossibleJumpCount: Int
    public let tooManySimultaneousCount: Int
    public let sustainConflictCount: Int
}

/// Aggregate playability assessment.
public struct PlayabilityDiagnosis: Sendable, Equatable {
    public let leftHand: PlayabilityHandStats
    public let rightHand: PlayabilityHandStats
    public let issues: [PlayabilityIssue]
    public let splitPitch: Int
    /// 0.0 … 1.0 — higher means more playable. 1.0 = no issues; each issue
    /// pulls the score down by `severity / k`. Tuned so a single moderate
    /// issue costs ~0.05–0.10.
    public let score: Double

    public var isPlayable: Bool { score >= 0.85 && issues.isEmpty }
    public var totalIssues: Int { issues.count }
}

public enum PlayabilityDiagnoser {

    public struct Config: Sendable, Equatable {
        /// Maximum span (semitones) one hand can play simultaneously. Most
        /// adult hands top out around 12 semitones (octave + a tone) with
        /// stretch — anything above is physically impossible.
        public var maxHandSpan: Int
        /// Maximum number of notes one hand can play simultaneously
        /// (5 fingers, occasionally 6 with thumb-on-two-keys).
        public var maxSimultaneousPerHand: Int
        /// Max pitch span across BOTH hands when they share an onset
        /// cluster — anything wider is "spread too widely across the
        /// keyboard" per the spec, even if each hand is fine in isolation.
        public var maxKeyboardSpreadAtOnset: Int
        /// Maximum reachable jump (semitones) per `jumpReferenceSeconds`.
        /// At 250 ms a hand can comfortably move ~24 semitones (two
        /// octaves) — anything beyond is teleporting.
        public var jumpSemitonesPer250ms: Int
        /// Time window (s) the jump rule references.
        public var jumpReferenceSeconds: Double
        /// Onset window for "simultaneous" — short enough that strummed
        /// chords still register as one event, long enough to ignore
        /// jitter between transcribed onsets.
        public var simultaneousWindow: Double
        public init(
            maxHandSpan: Int = 12,
            maxSimultaneousPerHand: Int = 5,
            maxKeyboardSpreadAtOnset: Int = 36,
            jumpSemitonesPer250ms: Int = 24,
            jumpReferenceSeconds: Double = 0.25,
            simultaneousWindow: Double = 0.05
        ) {
            self.maxHandSpan = maxHandSpan
            self.maxSimultaneousPerHand = maxSimultaneousPerHand
            self.maxKeyboardSpreadAtOnset = maxKeyboardSpreadAtOnset
            self.jumpSemitonesPer250ms = jumpSemitonesPer250ms
            self.jumpReferenceSeconds = jumpReferenceSeconds
            self.simultaneousWindow = simultaneousWindow
        }
    }

    public static func diagnose(
        _ assignment: HandAssignment,
        config: Config = .init()
    ) -> PlayabilityDiagnosis {
        var issues: [PlayabilityIssue] = []

        // Per-hand pass: span, simultaneous, jumps, sustain conflicts.
        let left = assignment.notes.filter { $0.hand == .left }.map(\.note)
        let right = assignment.notes.filter { $0.hand == .right }.map(\.note)
        let leftStats = analyzeHand(left, hand: .left, config: config, into: &issues)
        let rightStats = analyzeHand(right, hand: .right, config: config, into: &issues)

        // Cross-hand pass: total keyboard spread at any single onset.
        let allByOnset = assignment.notes.sorted { $0.note.onset < $1.note.onset }
        var i = 0
        while i < allByOnset.count {
            let head = allByOnset[i]
            var j = i + 1
            while j < allByOnset.count,
                  allByOnset[j].note.onset - head.note.onset <= config.simultaneousWindow {
                j += 1
            }
            let cluster = Array(allByOnset[i ..< j])
            if let lo = cluster.map({ $0.note.pitch }).min(),
               let hi = cluster.map({ $0.note.pitch }).max() {
                let spread = hi - lo
                if spread > config.maxKeyboardSpreadAtOnset {
                    let sev = severityFor(value: Double(spread), threshold: Double(config.maxKeyboardSpreadAtOnset))
                    // The "hand" stamp here is informational — keyboard spread
                    // affects the bridging hand. Stamp it on whichever hand has
                    // more notes in the cluster, defaulting to right.
                    let lc = cluster.filter { $0.hand == .left }.count
                    let rc = cluster.count - lc
                    let stampHand: PianoHand = lc > rc ? .left : .right
                    issues.append(.init(
                        kind: .keyboardSpread, hand: stampHand,
                        timestamp: head.note.onset,
                        pitches: cluster.map { $0.note.pitch }.sorted(),
                        severity: sev,
                        detail: "Onset cluster spans \(spread) semitones across both hands."
                    ))
                }
            }
            i = j
        }

        let score = score(from: issues)
        return PlayabilityDiagnosis(
            leftHand: leftStats,
            rightHand: rightStats,
            issues: issues,
            splitPitch: assignment.splitPitch,
            score: score
        )
    }

    // MARK: - Per-hand analysis

    private static func analyzeHand(
        _ notes: [MIDINote],
        hand: PianoHand,
        config: Config,
        into issues: inout [PlayabilityIssue]
    ) -> PlayabilityHandStats {
        let sorted = notes.sorted { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }
        var maxSimul = 0
        var maxSpan = 0
        var maxJumpRate: Double = 0
        var spanIssues = 0
        var simulIssues = 0
        var jumpIssues = 0
        var sustainIssues = 0

        // 1. Onset cluster scan: simultaneous count + span.
        var i = 0
        while i < sorted.count {
            let head = sorted[i]
            var j = i + 1
            while j < sorted.count, sorted[j].onset - head.onset <= config.simultaneousWindow {
                j += 1
            }
            let cluster = Array(sorted[i ..< j])
            let count = cluster.count
            maxSimul = max(maxSimul, count)
            let lo = cluster.map(\.pitch).min() ?? head.pitch
            let hi = cluster.map(\.pitch).max() ?? head.pitch
            let span = hi - lo
            maxSpan = max(maxSpan, span)
            if count > config.maxSimultaneousPerHand {
                simulIssues += 1
                let sev = severityFor(value: Double(count), threshold: Double(config.maxSimultaneousPerHand))
                issues.append(.init(
                    kind: .tooManySimultaneous, hand: hand,
                    timestamp: head.onset,
                    pitches: cluster.map(\.pitch).sorted(),
                    severity: sev,
                    detail: "\(hand.rawValue) hand has \(count) notes at onset (max \(config.maxSimultaneousPerHand))."
                ))
            }
            if span > config.maxHandSpan {
                spanIssues += 1
                let sev = severityFor(value: Double(span), threshold: Double(config.maxHandSpan))
                issues.append(.init(
                    kind: .impossibleSpan, hand: hand,
                    timestamp: head.onset,
                    pitches: cluster.map(\.pitch).sorted(),
                    severity: sev,
                    detail: "\(hand.rawValue) hand asked to span \(span) semitones at \(String(format: "%.2f", head.onset))s."
                ))
            }
            i = j
        }

        // 2. Jump scan: per-hand pitch displacement vs. dt between
        //    consecutive cluster centroids.
        var clusters: [(time: Double, lo: Int, hi: Int, centroid: Double)] = []
        var k = 0
        while k < sorted.count {
            let head = sorted[k]
            var j = k + 1
            while j < sorted.count, sorted[j].onset - head.onset <= config.simultaneousWindow {
                j += 1
            }
            let group = Array(sorted[k ..< j])
            let lo = group.map(\.pitch).min() ?? head.pitch
            let hi = group.map(\.pitch).max() ?? head.pitch
            let centroid = Double(group.reduce(0) { $0 + $1.pitch }) / Double(group.count)
            clusters.append((time: head.onset, lo: lo, hi: hi, centroid: centroid))
            k = j
        }
        for idx in 1 ..< max(1, clusters.count) {
            let prev = clusters[idx - 1]
            let curr = clusters[idx]
            let dt = max(0.001, curr.time - prev.time)
            // Compute reach: the smaller of |curr.lo - prev.hi|, |curr.hi - prev.lo|.
            // That is, the closest pitch we still have to *reach* from the
            // previous cluster's outline. If the previous cluster was a
            // chord, pivoting from its nearest edge counts as the move.
            let reach = min(abs(curr.lo - prev.hi), abs(curr.hi - prev.lo))
            let perRef = Double(reach) * (config.jumpReferenceSeconds / dt)
            if perRef > maxJumpRate { maxJumpRate = perRef }
            if perRef > Double(config.jumpSemitonesPer250ms) {
                jumpIssues += 1
                let sev = severityFor(value: perRef, threshold: Double(config.jumpSemitonesPer250ms))
                issues.append(.init(
                    kind: .impossibleJump, hand: hand,
                    timestamp: curr.time,
                    pitches: [prev.lo, prev.hi, curr.lo, curr.hi],
                    severity: sev,
                    detail: "\(hand.rawValue) jump of \(reach) semitones in \(String(format: "%.0f", dt * 1000)) ms."
                ))
            }
        }

        // 3. Sustain conflict: any note still held when a note in the same
        //    hand starts at an impossible reach from it.
        for n in sorted {
            let nEnd = n.onset + n.duration
            for m in sorted where m.onset > n.onset && m.onset < nEnd {
                let reach = abs(m.pitch - n.pitch)
                if reach > config.maxHandSpan {
                    sustainIssues += 1
                    let sev = severityFor(value: Double(reach), threshold: Double(config.maxHandSpan))
                    issues.append(.init(
                        kind: .sustainConflict, hand: hand,
                        timestamp: m.onset,
                        pitches: [n.pitch, m.pitch],
                        severity: sev,
                        detail: "\(hand.rawValue) holds \(n.pitch) while reaching to \(m.pitch)."
                    ))
                    break // one issue per held note is enough
                }
            }
        }

        return PlayabilityHandStats(
            hand: hand,
            noteCount: notes.count,
            maxSimultaneous: maxSimul,
            maxSpanSemitones: maxSpan,
            maxJumpSemitonesPerSecond: maxJumpRate,
            impossibleSpanCount: spanIssues,
            impossibleJumpCount: jumpIssues,
            tooManySimultaneousCount: simulIssues,
            sustainConflictCount: sustainIssues
        )
    }

    private static func severityFor(value: Double, threshold: Double) -> Double {
        guard threshold > 0 else { return 1.0 }
        let over = max(0, value - threshold)
        // Ramp: every threshold-worth of overshoot adds 0.5 severity, capped at 1.
        return min(1.0, 0.5 * (over / threshold) + 0.25)
    }

    private static func score(from issues: [PlayabilityIssue]) -> Double {
        // Each issue subtracts severity * 0.10. Several small issues stack
        // gently; one severe issue costs ~0.10. Floor at 0.
        let penalty = issues.reduce(0.0) { $0 + $1.severity * 0.10 }
        return max(0.0, min(1.0, 1.0 - penalty))
    }
}
