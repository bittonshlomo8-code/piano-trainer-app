import Foundation

/// Pure post-processing helpers shared by piano-focused pipelines.
///
/// These run after the spectral detector has produced raw notes and tighten
/// up well-known failure modes:
///   • short isolated "ghost" notes from harmonic leakage
///   • velocity outliers when a single sustained note fluctuates
///   • micro-gaps inside what should be one sustained note
///
/// All operations are deterministic and pitch-local — they never invent new
/// pitches and never shift onsets backwards.
public enum NoteRefinement {

    /// Apply the standard set of piano refinements in order:
    ///   1. drop short ghost notes (< 80 ms)
    ///   2. merge tiny gaps inside the same pitch (< 250 ms)
    ///   3. soften velocity jitter against neighbours of the same pitch
    public static func refineForPiano(_ notes: [MIDINote]) -> [MIDINote] {
        let pruned = pruneGhosts(notes, minDuration: 0.08)
        let merged = mergeShortGaps(pruned, maxGap: 0.25)
        return smoothVelocities(merged)
    }

    /// Drop notes shorter than `minDuration` — these are usually harmonic
    /// crosstalk that briefly clears the activation threshold without being
    /// real notes.
    public static func pruneGhosts(_ notes: [MIDINote], minDuration: Double) -> [MIDINote] {
        notes.filter { $0.duration >= minDuration }
    }

    /// Merge two same-pitch notes when the silence between them is shorter
    /// than `maxGap`. Models pedal-sustained notes that the detector dropped
    /// briefly. Velocity is taken from the louder of the two so a clean
    /// onset's dynamic isn't washed out by a fading tail.
    public static func mergeShortGaps(_ notes: [MIDINote], maxGap: Double) -> [MIDINote] {
        guard notes.count > 1 else { return notes }
        let sorted = notes.sorted { $0.onset < $1.onset }
        var out: [MIDINote] = []
        var cur = sorted[0]
        for nxt in sorted.dropFirst() {
            let gap = nxt.onset - (cur.onset + cur.duration)
            if nxt.pitch == cur.pitch, gap >= 0, gap <= maxGap {
                cur = MIDINote(
                    pitch: cur.pitch,
                    onset: cur.onset,
                    duration: nxt.onset + nxt.duration - cur.onset,
                    velocity: max(cur.velocity, nxt.velocity)
                )
            } else {
                out.append(cur)
                cur = nxt
            }
        }
        out.append(cur)
        return out
    }

    /// Pull each note's velocity halfway toward the median velocity of its
    /// same-pitch neighbours. Removes spike-y outliers caused by a noisy
    /// salience peak without flattening real dynamics across pitches.
    public static func smoothVelocities(_ notes: [MIDINote]) -> [MIDINote] {
        guard !notes.isEmpty else { return notes }
        let grouped = Dictionary(grouping: notes, by: \.pitch)
        var refined: [MIDINote] = []
        refined.reserveCapacity(notes.count)
        for (_, pitchNotes) in grouped {
            let velocities = pitchNotes.map(\.velocity).sorted()
            let median = velocities[velocities.count / 2]
            for n in pitchNotes {
                let blended = (n.velocity + median) / 2
                refined.append(MIDINote(
                    id: n.id,
                    pitch: n.pitch,
                    onset: n.onset,
                    duration: n.duration,
                    velocity: max(1, min(127, blended))
                ))
            }
        }
        return refined.sorted { $0.onset < $1.onset }
    }
}
