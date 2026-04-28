import Foundation

/// Per-action tally tracked across all repair stages.
public struct PlayabilityRepairLog: Sendable, Equatable {
    public var ghostsRemoved: Int = 0          // weak/short notes deleted to fix a stretch
    public var lowConfidenceDropped: Int = 0   // lowest-velocity note removed from impossible chord
    public var octaveDuplicatesCollapsed: Int = 0
    public var notesReassigned: Int = 0        // moved between hands
    public var jumpsRelieved: Int = 0          // notes deleted to break impossible jumps
    public var sustainConflictsResolved: Int = 0

    public var totalChanges: Int {
        ghostsRemoved + lowConfidenceDropped + octaveDuplicatesCollapsed
            + notesReassigned + jumpsRelieved + sustainConflictsResolved
    }
}

/// Output of a repair pass. The engine returns the new hand assignment
/// (with mutated notes + reassignments) so the diagnoser can re-score
/// without rerunning HandAssignmentEngine from scratch.
public struct PlayabilityRepairResult: Sendable, Equatable {
    public let assignment: HandAssignment
    public let log: PlayabilityRepairLog
}

/// Repair engine for impossible-hand events. Operates only on the assigned
/// notes; never invents new notes; preserves the topmost note in each
/// onset cluster (treated as the melody anchor) and the bottommost note in
/// the left-hand stream (treated as the bass anchor) unless absolutely
/// necessary.
public enum PlayabilityRepairEngine {

    public struct Config: Sendable, Equatable {
        public var diagnoserConfig: PlayabilityDiagnoser.Config
        public var handAssignment: HandAssignmentEngine.Config
        /// Velocity threshold below which a note is considered "weak / ghost"
        /// and is the first to be removed when relieving an impossible
        /// stretch.
        public var ghostVelocity: Int
        /// Notes shorter than this are also treated as ghost-eligible.
        public var ghostMaxDuration: Double
        /// Onset window used by repair clustering (matches the diagnoser).
        public var clusterWindow: Double
        public init(
            diagnoserConfig: PlayabilityDiagnoser.Config = .init(),
            handAssignment: HandAssignmentEngine.Config = .init(),
            ghostVelocity: Int = 35,
            ghostMaxDuration: Double = 0.06,
            clusterWindow: Double = 0.05
        ) {
            self.diagnoserConfig = diagnoserConfig
            self.handAssignment = handAssignment
            self.ghostVelocity = ghostVelocity
            self.ghostMaxDuration = ghostMaxDuration
            self.clusterWindow = clusterWindow
        }
    }

    /// Apply a single repair pass. The caller may run multiple passes,
    /// re-diagnosing between each, until either the score stops improving
    /// or it crosses the acceptance threshold.
    public static func repair(
        _ assignment: HandAssignment,
        diagnosis: PlayabilityDiagnosis,
        config: Config = .init()
    ) -> PlayabilityRepairResult {
        var working = assignment.notes
        var log = PlayabilityRepairLog()

        // Process highest-severity issues first so a single pass clears
        // the loudest problems first. Issues are pre-sorted descending.
        let prioritized = diagnosis.issues.sorted { $0.severity > $1.severity }
        for issue in prioritized {
            switch issue.kind {
            case .tooManySimultaneous:
                applyTooManySimultaneous(issue, in: &working, log: &log, config: config)
            case .impossibleSpan:
                applyImpossibleSpan(issue, in: &working, log: &log, config: config)
            case .keyboardSpread:
                applyKeyboardSpread(issue, in: &working, log: &log, config: config)
            case .impossibleJump:
                applyImpossibleJump(issue, in: &working, log: &log, config: config)
            case .sustainConflict:
                applySustainConflict(issue, in: &working, log: &log, config: config)
            }
        }

        return PlayabilityRepairResult(
            assignment: HandAssignment(notes: working, splitPitch: assignment.splitPitch),
            log: log
        )
    }

    // MARK: - Repair stages

    /// Too many notes in one hand at one onset → drop the *weakest* notes
    /// (low velocity / short duration) until the chord fits. Always keep
    /// the topmost (melody) and bottommost (bass) notes of the cluster.
    private static func applyTooManySimultaneous(
        _ issue: PlayabilityIssue,
        in notes: inout [HandAssignedNote],
        log: inout PlayabilityRepairLog,
        config: Config
    ) {
        let cluster = clusterIndices(for: issue, in: notes, config: config)
        guard !cluster.isEmpty else { return }
        let max = config.diagnoserConfig.maxSimultaneousPerHand
        let count = cluster.count
        guard count > max else { return }
        let toRemove = count - max
        let topPitch = cluster.map { notes[$0].note.pitch }.max()
        let botPitch = cluster.map { notes[$0].note.pitch }.min()
        // Sort cluster indices by repair-priority (lowest velocity / shortest
        // duration first), excluding the melody (top) and bass (bottom).
        let removable = cluster
            .filter { notes[$0].note.pitch != topPitch && notes[$0].note.pitch != botPitch }
            .sorted { repairPriority(notes[$0].note) < repairPriority(notes[$1].note) }
        var removeSet = Set<Int>(removable.prefix(toRemove))
        // If we couldn't find enough non-melody/non-bass notes (e.g. cluster is
        // a 7-note voicing with a duplicated bass), allow trimming inner
        // notes too.
        if removeSet.count < toRemove {
            let extras = cluster.filter { !removeSet.contains($0) }
                .sorted { repairPriority(notes[$0].note) < repairPriority(notes[$1].note) }
            for idx in extras.prefix(toRemove - removeSet.count) {
                removeSet.insert(idx)
            }
        }
        for idx in removeSet.sorted(by: >) {
            notes.remove(at: idx)
        }
        log.lowConfidenceDropped += removeSet.count
    }

    /// Hand asked to span more than `maxHandSpan` semitones. Drop the
    /// note responsible for the stretch — preferably a weak/short note
    /// that's neither the top nor bottom of the cluster, otherwise the
    /// outermost-not-bass-or-melody note.
    private static func applyImpossibleSpan(
        _ issue: PlayabilityIssue,
        in notes: inout [HandAssignedNote],
        log: inout PlayabilityRepairLog,
        config: Config
    ) {
        let cluster = clusterIndices(for: issue, in: notes, config: config)
        guard cluster.count >= 2 else { return }
        let pitches = cluster.map { notes[$0].note.pitch }
        guard let topPitch = pitches.max(), let botPitch = pitches.min() else { return }
        let span = topPitch - botPitch
        guard span > config.diagnoserConfig.maxHandSpan else { return }

        // Try ghost-removal first: if ANY note in the cluster is weak/short
        // (low velocity or very short duration), dropping it is the cheapest
        // fix. We scan the whole cluster — including endpoints — because
        // the impossible stretch is sometimes caused by a ghost note that
        // *is* the top or bottom of the cluster (e.g. a 40-semitone span
        // where the highest pitch is itself a transcription artefact).
        let weakAll = cluster
            .filter { isWeak(notes[$0].note, config: config) }
            .sorted { repairPriority(notes[$0].note) < repairPriority(notes[$1].note) }
        if let idx = weakAll.first {
            notes.remove(at: idx)
            log.ghostsRemoved += 1
            return
        }

        // Reassignment: try moving the outermost note to the other hand.
        // We move whichever endpoint is farther from the cluster centroid,
        // preferring NOT to disturb the melody (top) or bass anchor.
        let centroid = Double(pitches.reduce(0, +)) / Double(pitches.count)
        let topIdx = cluster.first { notes[$0].note.pitch == topPitch }!
        let botIdx = cluster.first { notes[$0].note.pitch == botPitch }!
        let topFarther = (Double(topPitch) - centroid) > (centroid - Double(botPitch))
        let pickedIdx: Int = topFarther ? botIdx : topIdx
        let other: PianoHand = notes[pickedIdx].hand == .left ? .right : .left

        // Reassignment is only valid if it doesn't make the OTHER hand
        // impossible. Snapshot the other-hand notes at this onset and
        // verify the post-move span fits.
        let onset = notes[pickedIdx].note.onset
        let otherPitches = notes.indices
            .filter { notes[$0].hand == other }
            .filter { abs(notes[$0].note.onset - onset) <= config.clusterWindow }
            .map { notes[$0].note.pitch }
        let postLo = (otherPitches + [notes[pickedIdx].note.pitch]).min() ?? 0
        let postHi = (otherPitches + [notes[pickedIdx].note.pitch]).max() ?? 0
        if (postHi - postLo) <= config.diagnoserConfig.maxHandSpan {
            notes[pickedIdx] = HandAssignedNote(note: notes[pickedIdx].note, hand: other)
            log.notesReassigned += 1
            return
        }

        // Last resort: drop the lowest-confidence inner note even if not
        // weak, then if no inner notes exist drop one endpoint. We never
        // delete a melody (top) note unless that's the only remaining
        // option.
        let dropPriority = cluster
            .filter { notes[$0].note.pitch != topPitch }
            .sorted { repairPriority(notes[$0].note) < repairPriority(notes[$1].note) }
        if let idx = dropPriority.first {
            notes.remove(at: idx)
            log.lowConfidenceDropped += 1
        }
    }

    /// Onset cluster spans the whole keyboard. Drop the weakest note in
    /// the cluster first (a ghost is the most likely culprit); if no note
    /// is weak, drop the most-peripheral inner note. Endpoints (lowest +
    /// highest) are preserved when possible because they are usually the
    /// melody anchor (top) and the bass anchor (bottom) of the chord.
    private static func applyKeyboardSpread(
        _ issue: PlayabilityIssue,
        in notes: inout [HandAssignedNote],
        log: inout PlayabilityRepairLog,
        config: Config
    ) {
        let cluster = clusterIndices(forCrossHand: issue, in: notes, config: config)
        guard cluster.count >= 2 else { return }

        // 1. If any cluster note is weak/short, drop the weakest one
        //    regardless of whether it's an endpoint — a ghost note can
        //    *be* the highest or lowest pitch, and dropping it is safer
        //    than removing the melody or bass.
        let weak = cluster
            .filter { isWeak(notes[$0].note, config: config) }
            .sorted { repairPriority(notes[$0].note) < repairPriority(notes[$1].note) }
        if let idx = weak.first {
            notes.remove(at: idx)
            log.octaveDuplicatesCollapsed += 1
            return
        }

        // 2. Otherwise drop the most-peripheral inner note (preferring
        //    weaker notes on ties).
        let pitches = cluster.map { notes[$0].note.pitch }
        let lo = pitches.min()!, hi = pitches.max()!
        let centroid = Double(pitches.reduce(0, +)) / Double(pitches.count)
        let inner = cluster.filter { notes[$0].note.pitch != lo && notes[$0].note.pitch != hi }
        let candidates = inner.isEmpty ? cluster : inner
        let chosen = candidates.max { a, b in
            let da = abs(Double(notes[a].note.pitch) - centroid)
            let db = abs(Double(notes[b].note.pitch) - centroid)
            if da != db { return da < db }
            // Tiebreak: prefer dropping the lower-priority (weaker) note.
            return repairPriority(notes[a].note) > repairPriority(notes[b].note)
        }
        if let idx = chosen {
            notes.remove(at: idx)
            log.octaveDuplicatesCollapsed += 1
        }
    }

    /// Same hand asked to teleport. Drop the *destination* note if it's
    /// weak (likely a transcription artefact) — otherwise leave it; jumps
    /// in real piano music are valid.
    private static func applyImpossibleJump(
        _ issue: PlayabilityIssue,
        in notes: inout [HandAssignedNote],
        log: inout PlayabilityRepairLog,
        config: Config
    ) {
        let onset = issue.timestamp
        let candidates = notes.indices.filter {
            notes[$0].hand == issue.hand
                && abs(notes[$0].note.onset - onset) <= config.clusterWindow
                && isWeak(notes[$0].note, config: config)
        }
        if let idx = candidates.first {
            notes.remove(at: idx)
            log.jumpsRelieved += 1
        }
    }

    /// A note is held while another note in the same hand demands an
    /// impossible reach. The cheapest fix is to shorten the held note so
    /// the hand can move; the second-cheapest is to drop the new note if
    /// it's weak.
    private static func applySustainConflict(
        _ issue: PlayabilityIssue,
        in notes: inout [HandAssignedNote],
        log: inout PlayabilityRepairLog,
        config: Config
    ) {
        guard issue.pitches.count == 2 else { return }
        let heldPitch = issue.pitches[0]
        let newOnset = issue.timestamp
        // Find the held note: starts before newOnset, still active at newOnset,
        // same hand, matching pitch.
        guard let heldIdx = notes.indices.first(where: { i in
            let n = notes[i].note
            return notes[i].hand == issue.hand
                && n.pitch == heldPitch
                && n.onset < newOnset
                && (n.onset + n.duration) > newOnset
        }) else { return }
        // Truncate the held note to end just before the new onset.
        let held = notes[heldIdx].note
        let newDur = max(0.04, newOnset - held.onset - 0.001)
        notes[heldIdx] = HandAssignedNote(
            note: MIDINote(id: held.id, pitch: held.pitch, onset: held.onset,
                           duration: newDur, velocity: held.velocity),
            hand: notes[heldIdx].hand
        )
        log.sustainConflictsResolved += 1
    }

    // MARK: - Helpers

    /// Higher = more important to preserve. Very short / low-velocity
    /// notes are easiest to remove; sustained loud notes are hardest.
    private static func repairPriority(_ note: MIDINote) -> Double {
        Double(note.velocity) + 200.0 * note.duration
    }

    private static func isWeak(_ note: MIDINote, config: Config) -> Bool {
        note.velocity < config.ghostVelocity || note.duration < config.ghostMaxDuration
    }

    /// Indices of the cluster around an issue, restricted to the issue's hand.
    private static func clusterIndices(
        for issue: PlayabilityIssue,
        in notes: [HandAssignedNote],
        config: Config
    ) -> [Int] {
        notes.indices.filter { i in
            notes[i].hand == issue.hand
                && abs(notes[i].note.onset - issue.timestamp) <= config.clusterWindow
        }
    }

    /// Indices of an onset cluster across BOTH hands (used for keyboardSpread).
    private static func clusterIndices(
        forCrossHand issue: PlayabilityIssue,
        in notes: [HandAssignedNote],
        config: Config
    ) -> [Int] {
        notes.indices.filter { i in
            abs(notes[i].note.onset - issue.timestamp) <= config.clusterWindow
        }
    }
}
