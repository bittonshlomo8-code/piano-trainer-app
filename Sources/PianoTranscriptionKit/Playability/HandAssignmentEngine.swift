import Foundation

/// Which hand a note is assigned to in the playability model.
public enum PianoHand: String, Sendable, Equatable, Codable {
    case left
    case right
}

/// One note plus the hand the assignment engine routed it to. Notes are
/// kept by-value so downstream stages can reorder / drop without disturbing
/// the original `MIDINote` identity (the ID is preserved across the round
/// trip).
public struct HandAssignedNote: Sendable, Equatable {
    public let note: MIDINote
    public let hand: PianoHand
    public init(note: MIDINote, hand: PianoHand) {
        self.note = note
        self.hand = hand
    }
}

/// Output of the hand-assignment pass.
public struct HandAssignment: Sendable, Equatable {
    /// Per-note hand assignment, in original onset/pitch order.
    public let notes: [HandAssignedNote]
    /// Effective split MIDI pitch used for the final assignment. May differ
    /// from the default 60 when the music sits in a different tessitura.
    public let splitPitch: Int
    /// Pitches at or below `splitPitch` go to the left hand; pitches
    /// strictly above `splitPitch` go to the right hand. Notes whose
    /// onset cluster crosses the split are assigned by the cluster's
    /// pitch centroid (notes below the centroid → left, notes at or
    /// above → right).
    public init(notes: [HandAssignedNote], splitPitch: Int) {
        self.notes = notes
        self.splitPitch = splitPitch
    }
}

/// Assigns each note to the left or right hand. The default split is
/// MIDI 60 (Middle C); the engine nudges the split point ±6 semitones
/// based on where the note mass is concentrated, then resolves chord
/// clusters that straddle the split by routing notes by cluster shape.
///
/// This is intentionally a heuristic — perfect hand split requires the
/// full musical context (voice leading, fingering, bar boundaries). The
/// engine's job here is to give the diagnosis + repair stages a stable,
/// reproducible per-note hand label so they can detect impossible-hand
/// events without false positives.
public final class HandAssignmentEngine: @unchecked Sendable {

    public struct Config: Sendable, Equatable {
        /// Starting split point; nudged dynamically by note density.
        public var defaultSplitPitch: Int
        /// Maximum semitones the split point may drift from the default.
        public var maxSplitDrift: Int
        /// Notes with onsets within this window are considered part of
        /// the same chord cluster for cross-split routing.
        public var clusterWindow: Double
        public init(defaultSplitPitch: Int = 60, maxSplitDrift: Int = 6, clusterWindow: Double = 0.05) {
            self.defaultSplitPitch = defaultSplitPitch
            self.maxSplitDrift = maxSplitDrift
            self.clusterWindow = clusterWindow
        }
    }

    public let config: Config
    public init(config: Config = .init()) { self.config = config }

    public func assign(_ notes: [MIDINote]) -> HandAssignment {
        guard !notes.isEmpty else {
            return HandAssignment(notes: [], splitPitch: config.defaultSplitPitch)
        }
        let sorted = notes.sorted { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }
        let split = effectiveSplit(for: sorted)

        // Group by onset cluster so chords routed across the split land
        // on the hand that actually contains the bulk of the chord.
        var assigned: [HandAssignedNote] = []
        assigned.reserveCapacity(sorted.count)
        var i = 0
        while i < sorted.count {
            let head = sorted[i]
            var j = i + 1
            while j < sorted.count, sorted[j].onset - head.onset <= config.clusterWindow {
                j += 1
            }
            let cluster = Array(sorted[i ..< j])
            for hn in routeCluster(cluster, splitPitch: split) {
                assigned.append(hn)
            }
            i = j
        }
        return HandAssignment(notes: assigned, splitPitch: split)
    }

    /// Compute a dynamic split: the median of all pitches, clamped to
    /// `[defaultSplitPitch - maxSplitDrift, defaultSplitPitch + maxSplitDrift]`.
    /// Median tracks the centre of mass without being skewed by occasional
    /// extreme bass / treble notes.
    private func effectiveSplit(for notes: [MIDINote]) -> Int {
        let pitches = notes.map(\.pitch).sorted()
        let median: Int
        if pitches.count % 2 == 0 {
            let a = pitches[pitches.count / 2 - 1]
            let b = pitches[pitches.count / 2]
            median = (a + b) / 2
        } else {
            median = pitches[pitches.count / 2]
        }
        let lo = config.defaultSplitPitch - config.maxSplitDrift
        let hi = config.defaultSplitPitch + config.maxSplitDrift
        return max(lo, min(hi, median))
    }

    /// Assign every note in a chord cluster to a hand. Notes far from the
    /// split go to the obvious side (low → left, high → right). Notes
    /// straddling the split are routed by the cluster's pitch centroid:
    /// pitches below centroid → left, pitches at or above → right.
    /// This avoids splitting tight 3-note voicings unnaturally.
    private func routeCluster(_ cluster: [MIDINote], splitPitch: Int) -> [HandAssignedNote] {
        guard !cluster.isEmpty else { return [] }
        if cluster.count == 1 {
            let n = cluster[0]
            return [HandAssignedNote(note: n, hand: n.pitch <= splitPitch ? .left : .right)]
        }
        // Two-zone test: are any notes ambiguously near the split?
        let near: (Int) -> Bool = { abs($0 - splitPitch) <= 4 }
        if cluster.contains(where: { near($0.pitch) }) {
            // Use cluster centroid to anchor ambiguous middle notes to one hand.
            let centroid = Double(cluster.reduce(0) { $0 + $1.pitch }) / Double(cluster.count)
            return cluster.map { n in
                let hand: PianoHand = Double(n.pitch) < centroid ? .left : .right
                return HandAssignedNote(note: n, hand: hand)
            }
        }
        // Cluster is well-separated from the split; assign by simple rule.
        return cluster.map { n in
            HandAssignedNote(note: n, hand: n.pitch <= splitPitch ? .left : .right)
        }
    }
}
