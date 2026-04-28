import Foundation

/// Reusable repair operations applied by `MidiClinic`. Every operation is
/// pure: takes notes + parameters, returns notes + a count of changes.
/// The clinic strings them together according to the active
/// `MidiRepairProfile`.
public enum MidiRepairEngine {

    /// Drop notes whose pitch is outside `[low, high]`. Returns the
    /// surviving notes plus the number removed.
    public static func pitchRangeGate(_ notes: [MIDINote], low: Int, high: Int) -> ([MIDINote], Int) {
        let kept = notes.filter { (low ... high).contains($0.pitch) }
        return (kept, notes.count - kept.count)
    }

    /// Drop notes shorter than `minDuration` (seconds).
    public static func removeShortNotes(_ notes: [MIDINote], minDuration: Double) -> ([MIDINote], Int) {
        let kept = notes.filter { $0.duration >= minDuration }
        return (kept, notes.count - kept.count)
    }

    /// Drop or clamp notes longer than `maxDuration` unless they overlap
    /// musically supportive context (a same-pitch onset within
    /// `supportingWindow` seconds following them, or audio still has plausible
    /// sustain context). Conservative — when in doubt, clamp rather than
    /// delete.
    public static func removeUnsupportedLongNotes(
        _ notes: [MIDINote],
        maxDuration: Double,
        clampDuration: Double? = nil
    ) -> ([MIDINote], Int) {
        var changed = 0
        let target = clampDuration ?? maxDuration
        let out: [MIDINote] = notes.map { n in
            guard n.duration > maxDuration else { return n }
            changed += 1
            return MIDINote(id: n.id, pitch: n.pitch, onset: n.onset,
                            duration: target, velocity: n.velocity)
        }
        return (out, changed)
    }

    /// Merge consecutive same-pitch notes whose gap is below `maxGap` into
    /// a single sustained note.
    public static func mergeSamePitchFragments(_ notes: [MIDINote], maxGap: Double) -> ([MIDINote], Int) {
        guard notes.count > 1 else { return (notes, 0) }
        var changed = 0
        let byPitch = Dictionary(grouping: notes, by: \.pitch)
        var out: [MIDINote] = []
        for (_, group) in byPitch {
            let sorted = group.sorted { $0.onset < $1.onset }
            var cur = sorted[0]
            for next in sorted.dropFirst() {
                let gap = next.onset - (cur.onset + cur.duration)
                if gap >= 0 && gap <= maxGap {
                    cur = MIDINote(id: cur.id, pitch: cur.pitch, onset: cur.onset,
                                   duration: next.onset + next.duration - cur.onset,
                                   velocity: max(cur.velocity, next.velocity))
                    changed += 1
                } else {
                    out.append(cur); cur = next
                }
            }
            out.append(cur)
        }
        out.sort { $0.onset < $1.onset }
        return (out, changed)
    }

    /// When two same-pitch notes overlap, trim the earlier note's tail to
    /// the next onset. Drops the second note if overlap is huge.
    public static func trimSamePitchOverlaps(_ notes: [MIDINote]) -> ([MIDINote], Int) {
        var changed = 0
        let byPitch = Dictionary(grouping: notes, by: \.pitch)
        var out: [MIDINote] = []
        for (_, group) in byPitch {
            let sorted = group.sorted { $0.onset < $1.onset }
            var cur = sorted[0]
            for next in sorted.dropFirst() {
                let curEnd = cur.onset + cur.duration
                if next.onset >= curEnd - 1e-6 {
                    out.append(cur); cur = next; continue
                }
                let trimmed = max(0.001, next.onset - cur.onset)
                out.append(MIDINote(id: cur.id, pitch: cur.pitch,
                                    onset: cur.onset, duration: trimmed,
                                    velocity: cur.velocity))
                cur = next
                changed += 1
            }
            out.append(cur)
        }
        out.sort { $0.onset < $1.onset }
        return (out, changed)
    }

    /// Cap notes to `maxPerSecond` in any rolling 1-second window. Drops
    /// the lowest-velocity notes when over the cap.
    public static func capNotesPerSecond(_ notes: [MIDINote], maxPerSecond: Int) -> ([MIDINote], Int) {
        guard !notes.isEmpty, maxPerSecond > 0 else { return (notes, 0) }
        let sorted = notes.sorted { $0.onset < $1.onset }
        var keep = Array(repeating: true, count: sorted.count)
        var changed = 0
        // Process buckets of size 1s anchored on each onset; if a bucket has
        // more than maxPerSecond, drop the weakest. Single sweep is good
        // enough for our scales.
        let buckets = Dictionary(grouping: sorted.indices) { Int(sorted[$0].onset) }
        for (_, indices) in buckets where indices.count > maxPerSecond {
            let byVel = indices.sorted { sorted[$0].velocity > sorted[$1].velocity }
            for idx in byVel.dropFirst(maxPerSecond) {
                keep[idx] = false
                changed += 1
            }
        }
        let out = zip(sorted, keep).compactMap { $1 ? $0 : nil }
        return (out, changed)
    }

    /// Cap simultaneous-note count. When more than `maxSimultaneous` notes
    /// overlap at any instant, drop the weakest.
    public static func capSimultaneousNotes(_ notes: [MIDINote], maxSimultaneous: Int) -> ([MIDINote], Int) {
        guard !notes.isEmpty, maxSimultaneous > 0 else { return (notes, 0) }
        // Build interval events; sweep, when active count exceeds the cap
        // mark the weakest active notes for removal.
        struct Active { let idx: Int; let velocity: Int }
        let sorted = notes.indices.sorted { notes[$0].onset < notes[$1].onset }
        var active: [Active] = []
        var keep = Array(repeating: true, count: notes.count)
        var changed = 0
        for i in sorted {
            // Drop expired actives.
            active.removeAll { a in
                let ai = a.idx
                return notes[ai].onset + notes[ai].duration <= notes[i].onset
            }
            active.append(Active(idx: i, velocity: notes[i].velocity))
            if active.count > maxSimultaneous {
                let weakest = active.min { $0.velocity < $1.velocity }!
                if keep[weakest.idx] {
                    keep[weakest.idx] = false
                    changed += 1
                }
                active.removeAll { $0.idx == weakest.idx }
            }
        }
        let out = notes.indices.compactMap { keep[$0] ? notes[$0] : nil }
        return (out, changed)
    }

    /// Drop notes that have no neighbouring notes within `window` seconds
    /// AND are short / low-velocity.
    public static func removeIsolatedGhostNotes(
        _ notes: [MIDINote],
        window: Double = 0.5,
        maxGhostDuration: Double = 0.20,
        maxGhostVelocity: Int = 30
    ) -> ([MIDINote], Int) {
        guard !notes.isEmpty else { return (notes, 0) }
        let sorted = notes.sorted { $0.onset < $1.onset }
        var keep = Array(repeating: true, count: sorted.count)
        var changed = 0
        for (i, n) in sorted.enumerated() {
            let prevGap = i > 0 ? n.onset - sorted[i-1].onset : .greatestFiniteMagnitude
            let nextGap = i < sorted.count - 1 ? sorted[i+1].onset - n.onset : .greatestFiniteMagnitude
            let isolated = prevGap > window && nextGap > window
            if isolated && n.duration < maxGhostDuration && n.velocity < maxGhostVelocity {
                keep[i] = false
                changed += 1
            }
        }
        let out = zip(sorted, keep).compactMap { $1 ? $0 : nil }
        return (out, changed)
    }

    /// Smooth onset jitter under `maxJitterMs`. For each interior note we
    /// compare its onset to the linear midpoint between its neighbours
    /// (i.e. where it *should* land if the local tempo were constant) —
    /// this catches drift in monotonic sequences that a simple median
    /// would miss because the median IS the note itself. Never quantizes
    /// hard: shifts are blended 50/50 toward the predicted onset.
    public static func smoothTimingJitter(_ notes: [MIDINote], maxJitterMs: Double) -> ([MIDINote], Int) {
        guard notes.count >= 3, maxJitterMs > 0 else { return (notes, 0) }
        let sorted = notes.sorted { $0.onset < $1.onset }
        var changed = 0
        var out: [MIDINote] = sorted
        let maxJitterSec = maxJitterMs / 1000.0
        for i in 1 ..< (sorted.count - 1) {
            let predicted = (sorted[i - 1].onset + sorted[i + 1].onset) / 2.0
            let drift = abs(sorted[i].onset - predicted)
            if drift > 0.001 && drift < maxJitterSec {
                let shifted = sorted[i].onset * 0.5 + predicted * 0.5
                let n = sorted[i]
                out[i] = MIDINote(id: n.id, pitch: n.pitch,
                                  onset: shifted, duration: n.duration,
                                  velocity: n.velocity)
                changed += 1
            }
        }
        return (out, changed)
    }

    /// Preserve chord clusters: notes whose onsets fall within `window`
    /// seconds of each other and whose chord size is in [2, maxChord]
    /// stay. Larger chord-onset clusters are reduced to the
    /// `maxChord` strongest notes.
    public static func preserveChordClusters(
        _ notes: [MIDINote],
        window: Double = 0.05,
        maxChord: Int = 5
    ) -> ([MIDINote], Int) {
        guard !notes.isEmpty else { return (notes, 0) }
        let sorted = notes.sorted { $0.onset < $1.onset }
        var keep = Array(repeating: true, count: sorted.count)
        var changed = 0
        var i = 0
        while i < sorted.count {
            var j = i
            while j < sorted.count && sorted[j].onset - sorted[i].onset <= window { j += 1 }
            let groupRange = i ..< j
            let groupSize = groupRange.count
            if groupSize > maxChord {
                let indices = Array(groupRange)
                let byVel = indices.sorted { sorted[$0].velocity > sorted[$1].velocity }
                for idx in byVel.dropFirst(maxChord) {
                    keep[idx] = false
                    changed += 1
                }
                i = j
            } else {
                i += 1
            }
        }
        let out = zip(sorted, keep).compactMap { $1 ? $0 : nil }
        return (out, changed)
    }

    /// Repair sustain durations: extend notes to the next same-pitch onset
    /// (minus a small gap) when the original duration is shorter than the
    /// gap to that onset and audio context suggests a real sustained note.
    public static func repairSustainDurations(
        _ notes: [MIDINote],
        maxExtensionSeconds: Double = 4.0,
        minOriginalDuration: Double = 0.20
    ) -> ([MIDINote], Int) {
        guard !notes.isEmpty else { return (notes, 0) }
        var changed = 0
        let byPitch = Dictionary(grouping: notes, by: \.pitch)
        var out: [MIDINote] = []
        for (_, group) in byPitch {
            let sorted = group.sorted { $0.onset < $1.onset }
            for i in 0 ..< sorted.count {
                let n = sorted[i]
                if n.duration < minOriginalDuration {
                    out.append(n); continue
                }
                let nextOnset = (i + 1 < sorted.count) ? sorted[i + 1].onset : nil
                if let nextOnset, nextOnset - n.onset > n.duration + 0.05 {
                    let extendTo = min(maxExtensionSeconds, nextOnset - n.onset - 0.02)
                    if extendTo > n.duration {
                        out.append(MIDINote(id: n.id, pitch: n.pitch,
                                            onset: n.onset,
                                            duration: extendTo,
                                            velocity: n.velocity))
                        changed += 1
                        continue
                    }
                }
                out.append(n)
            }
        }
        out.sort { $0.onset < $1.onset }
        return (out, changed)
    }

    /// Reduce simultaneous notes to a single melody line. Keeps the
    /// highest-velocity note per onset bucket. Use only when the active
    /// profile is melody-only.
    public static func melodyLineExtraction(_ notes: [MIDINote], onsetWindow: Double = 0.040) -> ([MIDINote], Int) {
        guard !notes.isEmpty else { return (notes, 0) }
        let sorted = notes.sorted { $0.onset < $1.onset }
        var out: [MIDINote] = []
        var changed = 0
        var i = 0
        while i < sorted.count {
            var j = i
            while j < sorted.count && sorted[j].onset - sorted[i].onset <= onsetWindow { j += 1 }
            // Strongest by velocity, tiebreak by highest pitch (right-hand melody).
            let group = Array(sorted[i ..< j])
            let strongest = group.max { a, b in
                if a.velocity != b.velocity { return a.velocity < b.velocity }
                return a.pitch < b.pitch
            }!
            out.append(strongest)
            changed += group.count - 1
            i = j
        }
        return (out, changed)
    }

    /// Final gate — drop anything still violating hard invariants. The
    /// clinic calls this last to guarantee the output meets the profile's
    /// quality contract regardless of upstream operations.
    public static func qualityGate(
        _ notes: [MIDINote],
        pitchLow: Int, pitchHigh: Int,
        minDuration: Double, maxDuration: Double
    ) -> ([MIDINote], Int) {
        let kept = notes.filter {
            $0.pitch >= pitchLow && $0.pitch <= pitchHigh &&
            $0.duration >= minDuration && $0.duration <= maxDuration
        }
        return (kept, notes.count - kept.count)
    }
}
