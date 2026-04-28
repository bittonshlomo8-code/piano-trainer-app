import Foundation

/// Pure post-processor applied to raw model output before it becomes a
/// `TranscriptionRun`. Targets the catastrophic failure modes diagnostics
/// surfaces: timeline drift, stuck long notes, onset cluster explosions,
/// density spikes, and same-pitch overlap.
///
/// All thresholds are knobs on `Config`. The cleanup never silently mutates
/// the input — `apply` returns both the cleaned notes and a `Report` that
/// counts what was removed/clamped at each stage so the UI can prove the
/// post-processing helped.
public enum TranscriptionCleanup {

    public struct Config: Equatable, Sendable {
        /// Hard cap on note duration when sustain pedal handling is not declared.
        public var maxNoteDurationSeconds: Double = 10.0
        /// Notes longer than this and shorter than `maxNoteDurationSeconds`
        /// keep their full duration (legitimate sustain). Notes between
        /// `softLongNoteSeconds` and `maxNoteDurationSeconds` survive but are
        /// counted as "clamped" if confidence is low.
        public var softLongNoteSeconds: Double = 4.0
        /// Velocity at or below this is treated as low-confidence.
        public var lowConfidenceVelocity: Int = 24
        /// Onset window for cluster pruning (seconds).
        public var clusterWindowSeconds: Double = 0.050
        /// Max notes allowed inside a cluster window.
        public var maxNotesPerClusterWindow: Int = 8
        /// Density bucket size (seconds).
        public var densityBucketSeconds: Double = 1.0
        /// Max notes allowed per density bucket.
        public var maxNotesPerDensityBucket: Int = 25
        /// Max distinct notes (across pitches) at the *exact* same onset
        /// timestamp. Detector quantization frequently lands many spurious
        /// onsets on a single frame; we keep the strongest by velocity.
        public var maxNotesPerExactOnset: Int = 6
        /// Whether to merge same-pitch overlap into a single sustained note
        /// (`true`) or trim the earlier note's tail back to the next onset
        /// (`false`). Trim is the safer default.
        public var mergeSamePitchOverlap: Bool = false
        /// Minimum gap between same-pitch note-off and next note-on (seconds).
        /// If overlap is shorter than this we prefer to merge; otherwise trim.
        public var samePitchMergeGap: Double = 0.04
        /// Source audio duration in seconds; cleanup will not allow any note
        /// to extend beyond this. Pass `nil` if unknown — note ends are still
        /// clamped against `maxNoteDurationSeconds` but not against the file.
        public var audioDurationSeconds: Double? = nil
        /// Tolerance allowed when `forceTimelineMatch` is true: any note
        /// ending past `audioDurationSeconds + this` is dropped or clamped.
        public var timelineMatchToleranceSeconds: Double = 0.100
        /// When true and `audioDurationSeconds` is known, the final stage
        /// guarantees no surviving note ends past audio + tolerance. Default
        /// on so timeline drift can't survive cleanup.
        public var forceTimelineMatch: Bool = true
        /// Set to true if the runner emits explicit sustain-pedal metadata.
        /// Currently no runner does — this is the gate that prevents anyone
        /// from quietly enabling 200-second notes by accident.
        public var sustainPedalDeclared: Bool = false

        public init() {}

        /// Pitch gate (inclusive). Notes outside the range are dropped. Set
        /// to `nil` to disable. Mixed-audio runs default to a piano-musical
        /// range so sub-harmonic / high-noise hallucinations get cut.
        public var minPitch: Int? = nil
        public var maxPitch: Int? = nil

        /// Maximum number of notes allowed to be simultaneously sounding at
        /// any given time (across all pitches). Counts events, not pitches —
        /// a 10-note polyphonic chord is fine; a 50-event burst is not.
        public var maxSimultaneousNotes: Int = 32

        /// Notes with velocity strictly below this are dropped. The default
        /// `1` keeps all notes; mixed-audio raises it to gate ghost notes.
        public var minVelocity: Int = 1

        /// "Isolated tiny note" filter. A note is dropped if its duration is
        /// below `isolatedTinyMaxDuration` AND there is no other note within
        /// `isolatedTinyNeighborWindow` seconds on either side.
        public var isolatedTinyMaxDuration: Double = 0.0     // 0 disables
        public var isolatedTinyNeighborWindow: Double = 0.25

        // MARK: - Sustain-aware ghost-note repair
        //
        // Targets the failure mode where the model emits brief, low-velocity
        // notes that only "exist" inside another note's sustain tail. These
        // are nearly always pitch leakage / partial-resonance artifacts, not
        // real piano events. The repair stage:
        //   1. Merges repeated same-pitch fragments that overlap or sit in
        //      a sustain tail of the same pitch (model emitted what was one
        //      held note as several short ones).
        //   2. Drops short+weak notes contained inside a *different*-pitch
        //      sustain tail, unless they form part of a real chord onset
        //      (≥1 other distinct pitch starting within `chordOnsetWindow`).
        public var sustainRepairEnabled: Bool = true
        /// Maximum gap (seconds) between same-pitch fragments still treated
        /// as one held note. 50 ms = under one human-perceptible chunk; larger
        /// gaps are real re-articulations.
        public var sustainSamePitchMergeGap: Double = 0.05
        /// A note must be both shorter than this AND weaker than
        /// `ghostNoteMaxVelocity` to be considered ghost-eligible. Both knobs
        /// must trip — that protects strong staccato melody notes.
        public var ghostNoteMaxDuration: Double = 0.12
        /// Velocity ceiling used together with `ghostNoteMaxDuration`.
        public var ghostNoteMaxVelocity: Int = 28
        /// Window around an onset within which other pitches starting count as
        /// a "chord onset" — a sustained-tail-encased note inside this band is
        /// preserved. 50 ms is the standard piano-perception window for
        /// simultaneous strikes.
        public var chordOnsetWindowSeconds: Double = 0.050

        /// Mandatory safety configuration applied at run-construction time
        /// so no pipeline path can produce a run that bypasses cleanup.
        /// All knobs are at or below the user-spec ceilings.
        public static let mandatory = Config()

        /// Convenience for derived configs — `with { $0.minVelocity = 18 }`
        /// returns a copy with the closure applied. Reads better at the
        /// call site than a multi-line var-and-mutate block.
        public func with(_ mutate: (inout Config) -> Void) -> Config {
            var copy = self
            mutate(&copy)
            return copy
        }

        // MARK: - Named cleanup profiles
        //
        // The QualityFirstTranscriptionRunner swaps these in for refinement
        // candidates. Each profile expresses a different musical hypothesis
        // about the input; the runner scores the resulting MIDI and keeps
        // the best one.

        /// Melody-only piano (e.g. simple tutorial like Baby Shark right
        /// hand). Forces monophony, narrows the pitch range, and aggressively
        /// drops short / low-velocity ghosts. Use ONLY when the arrangement
        /// is clearly single-voice melody.
        public static var melodyOnly: Config {
            var c = Config()
            c.minPitch = 55                  // G3
            c.maxPitch = 84                  // C6
            c.maxSimultaneousNotes = 1
            c.maxNotesPerExactOnset = 1
            c.maxNotesPerClusterWindow = 2
            c.maxNotesPerDensityBucket = 14
            c.minVelocity = 22
            c.isolatedTinyMaxDuration = 0.12
            c.isolatedTinyNeighborWindow = 0.30
            c.maxNoteDurationSeconds = 6.0
            c.softLongNoteSeconds = 2.0
            return c
        }

        /// Solo piano with chords + sustain pedal — preserve realistic
        /// polyphony, light ghost-note removal. The "default good" profile
        /// for clean studio recordings.
        public static var soloPiano: Config {
            var c = Config()
            c.minPitch = 21                  // A0 — full piano range
            c.maxPitch = 108                 // C8
            c.maxSimultaneousNotes = 18
            c.maxNotesPerExactOnset = 8
            c.maxNotesPerClusterWindow = 12
            c.maxNotesPerDensityBucket = 30
            c.minVelocity = 12
            c.isolatedTinyMaxDuration = 0.05
            c.maxNoteDurationSeconds = 12.0  // sustain pedal-friendly
            c.softLongNoteSeconds = 6.0
            return c
        }

        /// Piano with rain / phone-mic / noisy room. Tighter ghost gates
        /// and isolated-tiny removal, but otherwise preserves musical
        /// material so we don't strip real sustained notes.
        public static var noisyPiano: Config {
            var c = Config()
            c.minPitch = 28                  // E1
            c.maxPitch = 100                 // E7
            c.maxSimultaneousNotes = 14
            c.maxNotesPerExactOnset = 6
            c.maxNotesPerClusterWindow = 8
            c.maxNotesPerDensityBucket = 22
            c.minVelocity = 22
            c.isolatedTinyMaxDuration = 0.10
            c.isolatedTinyNeighborWindow = 0.30
            c.maxNoteDurationSeconds = 8.0
            c.softLongNoteSeconds = 3.5
            return c
        }

        /// Strict mixed-audio cleanup applied AFTER source separation. Keeps
        /// pitch range tight, caps simultaneity hard, drops anything that
        /// looks like spillover from drums / vocals / strings.
        public static var mixedAudioStrict: Config {
            var c = Config.mixedAudio
            c.minPitch = 36                  // C2
            c.maxPitch = 96                  // C7
            c.maxSimultaneousNotes = 12
            c.maxNotesPerExactOnset = 4
            c.maxNotesPerClusterWindow = 5
            c.maxNotesPerDensityBucket = 16
            c.minVelocity = 22
            c.isolatedTinyMaxDuration = 0.10
            c.maxNoteDurationSeconds = 5.0
            c.softLongNoteSeconds = 2.0
            return c
        }

        /// Stricter cleanup preset for *mixed-audio* runs (Mixed Audio
        /// pipeline, or a direct external model run on mixed input). Caps
        /// pitch range to the typical piano melody/accompaniment band, gates
        /// low-velocity ghosts, and drops isolated micro-notes that don't
        /// belong to any neighboring phrase.
        public static var mixedAudio: Config {
            var c = Config()
            c.minPitch = 36         // C2
            c.maxPitch = 96         // C7
            c.maxNotesPerDensityBucket = 18
            c.maxNotesPerClusterWindow = 6
            c.maxNotesPerExactOnset = 4
            c.maxSimultaneousNotes = 16
            c.minVelocity = 18
            c.isolatedTinyMaxDuration = 0.08
            c.isolatedTinyNeighborWindow = 0.30
            c.maxNoteDurationSeconds = 6.0
            c.softLongNoteSeconds = 2.5
            return c
        }

        /// Snapshot of the config that can be persisted alongside a run for
        /// reproducibility / debugging. Only the knobs that can change are
        /// included; the audio-duration field is set per-run by the factory.
        public var asParameters: [String: String] {
            var p: [String: String] = [
                "maxNoteDurationSeconds": String(maxNoteDurationSeconds),
                "softLongNoteSeconds": String(softLongNoteSeconds),
                "lowConfidenceVelocity": String(lowConfidenceVelocity),
                "clusterWindowSeconds": String(clusterWindowSeconds),
                "maxNotesPerClusterWindow": String(maxNotesPerClusterWindow),
                "densityBucketSeconds": String(densityBucketSeconds),
                "maxNotesPerDensityBucket": String(maxNotesPerDensityBucket),
                "maxNotesPerExactOnset": String(maxNotesPerExactOnset),
                "maxSimultaneousNotes": String(maxSimultaneousNotes),
                "minVelocity": String(minVelocity),
                "isolatedTinyMaxDuration": String(isolatedTinyMaxDuration),
                "isolatedTinyNeighborWindow": String(isolatedTinyNeighborWindow),
                "mergeSamePitchOverlap": String(mergeSamePitchOverlap),
                "samePitchMergeGap": String(samePitchMergeGap),
                "timelineMatchToleranceSeconds": String(timelineMatchToleranceSeconds),
                "forceTimelineMatch": String(forceTimelineMatch),
                "sustainPedalDeclared": String(sustainPedalDeclared),
                "sustainRepairEnabled": String(sustainRepairEnabled),
                "sustainSamePitchMergeGap": String(sustainSamePitchMergeGap),
                "ghostNoteMaxDuration": String(ghostNoteMaxDuration),
                "ghostNoteMaxVelocity": String(ghostNoteMaxVelocity),
                "chordOnsetWindowSeconds": String(chordOnsetWindowSeconds),
            ]
            if let lo = minPitch { p["minPitch"] = String(lo) }
            if let hi = maxPitch { p["maxPitch"] = String(hi) }
            return p
        }
    }

    public struct Report: Equatable, Codable, Sendable {
        public var inputCount: Int
        public var outputCount: Int
        public var clampedToAudioDuration: Int      // notes whose end was trimmed to source length
        public var droppedLongNotes: Int            // > maxNoteDurationSeconds and not justified
        public var clampedLongNotes: Int            // softLong < dur ≤ maxNote with low confidence
        public var prunedFromClusters: Int          // ghost notes removed inside 50ms windows
        public var prunedFromDensity: Int           // notes removed because bucket exceeded max
        public var prunedExactPileup: Int           // exact-onset same-pitch duplicates removed
        public var prunedExactOnsetCap: Int         // exact-onset across-pitch cap (>maxNotesPerExactOnset)
        public var trimmedSamePitchOverlap: Int     // earlier note tail trimmed to next onset
        public var mergedSamePitchOverlap: Int      // earlier + later same-pitch merged into one
        public var droppedNegativeDuration: Int     // safety: end <= start
        public var droppedZeroDuration: Int
        public var droppedTimelineOverflow: Int     // post-stages: end > audio + tolerance
        public var droppedOutOfPitchRange: Int      // outside [minPitch, maxPitch]
        public var droppedLowVelocity: Int          // velocity < minVelocity
        public var droppedIsolatedTiny: Int         // tiny + no neighbors within window
        public var prunedSimultaneousCap: Int       // exceeded maxSimultaneousNotes at any instant
        public var droppedSustainGhost: Int         // sustain-aware ghost (inside another note's tail)
        public var mergedSustainFragments: Int      // same-pitch fragments merged across sustain gap

        public init() {
            inputCount = 0; outputCount = 0; clampedToAudioDuration = 0
            droppedLongNotes = 0; clampedLongNotes = 0; prunedFromClusters = 0
            prunedFromDensity = 0; prunedExactPileup = 0; prunedExactOnsetCap = 0
            trimmedSamePitchOverlap = 0; mergedSamePitchOverlap = 0
            droppedNegativeDuration = 0; droppedZeroDuration = 0
            droppedTimelineOverflow = 0
            droppedOutOfPitchRange = 0; droppedLowVelocity = 0
            droppedIsolatedTiny = 0; prunedSimultaneousCap = 0
            droppedSustainGhost = 0; mergedSustainFragments = 0
        }

        public var totalRemoved: Int {
            droppedLongNotes + prunedFromClusters + prunedFromDensity
            + prunedExactPileup + prunedExactOnsetCap + droppedNegativeDuration
            + droppedZeroDuration + droppedTimelineOverflow
            + droppedOutOfPitchRange + droppedLowVelocity + droppedIsolatedTiny
            + prunedSimultaneousCap + droppedSustainGhost
        }

        // Backwards-compatible decoding so reports persisted before the
        // sustain-repair stage still load — the new counters default to zero.
        private enum CodingKeys: String, CodingKey {
            case inputCount, outputCount, clampedToAudioDuration
            case droppedLongNotes, clampedLongNotes, prunedFromClusters
            case prunedFromDensity, prunedExactPileup, prunedExactOnsetCap
            case trimmedSamePitchOverlap, mergedSamePitchOverlap
            case droppedNegativeDuration, droppedZeroDuration
            case droppedTimelineOverflow, droppedOutOfPitchRange
            case droppedLowVelocity, droppedIsolatedTiny, prunedSimultaneousCap
            case droppedSustainGhost, mergedSustainFragments
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            inputCount = try c.decodeIfPresent(Int.self, forKey: .inputCount) ?? 0
            outputCount = try c.decodeIfPresent(Int.self, forKey: .outputCount) ?? 0
            clampedToAudioDuration = try c.decodeIfPresent(Int.self, forKey: .clampedToAudioDuration) ?? 0
            droppedLongNotes = try c.decodeIfPresent(Int.self, forKey: .droppedLongNotes) ?? 0
            clampedLongNotes = try c.decodeIfPresent(Int.self, forKey: .clampedLongNotes) ?? 0
            prunedFromClusters = try c.decodeIfPresent(Int.self, forKey: .prunedFromClusters) ?? 0
            prunedFromDensity = try c.decodeIfPresent(Int.self, forKey: .prunedFromDensity) ?? 0
            prunedExactPileup = try c.decodeIfPresent(Int.self, forKey: .prunedExactPileup) ?? 0
            prunedExactOnsetCap = try c.decodeIfPresent(Int.self, forKey: .prunedExactOnsetCap) ?? 0
            trimmedSamePitchOverlap = try c.decodeIfPresent(Int.self, forKey: .trimmedSamePitchOverlap) ?? 0
            mergedSamePitchOverlap = try c.decodeIfPresent(Int.self, forKey: .mergedSamePitchOverlap) ?? 0
            droppedNegativeDuration = try c.decodeIfPresent(Int.self, forKey: .droppedNegativeDuration) ?? 0
            droppedZeroDuration = try c.decodeIfPresent(Int.self, forKey: .droppedZeroDuration) ?? 0
            droppedTimelineOverflow = try c.decodeIfPresent(Int.self, forKey: .droppedTimelineOverflow) ?? 0
            droppedOutOfPitchRange = try c.decodeIfPresent(Int.self, forKey: .droppedOutOfPitchRange) ?? 0
            droppedLowVelocity = try c.decodeIfPresent(Int.self, forKey: .droppedLowVelocity) ?? 0
            droppedIsolatedTiny = try c.decodeIfPresent(Int.self, forKey: .droppedIsolatedTiny) ?? 0
            prunedSimultaneousCap = try c.decodeIfPresent(Int.self, forKey: .prunedSimultaneousCap) ?? 0
            droppedSustainGhost = try c.decodeIfPresent(Int.self, forKey: .droppedSustainGhost) ?? 0
            mergedSustainFragments = try c.decodeIfPresent(Int.self, forKey: .mergedSustainFragments) ?? 0
        }
    }

    public struct Outcome: Equatable {
        public let raw: [MIDINote]
        public let cleaned: [MIDINote]
        public let report: Report
    }

    /// Apply every cleanup stage in order. The order matters: clamp first
    /// (so duration-based stages see realistic values), then drop long notes,
    /// then prune clusters/density (ghost reduction), then resolve same-pitch
    /// overlap on what survived.
    public static func apply(_ raw: [MIDINote], config: Config = .init()) -> Outcome {
        var report = Report()
        report.inputCount = raw.count

        // Stage 0: drop notes with non-positive duration or end-before-start.
        var stage = raw.compactMap { note -> MIDINote? in
            if note.duration <= 0 {
                report.droppedZeroDuration += 1
                return nil
            }
            if note.duration < 0 {
                report.droppedNegativeDuration += 1
                return nil
            }
            return note
        }

        // Stage 0a: pitch range gate. Mixed-audio runs use this to drop
        // sub-harmonic / high-frequency hallucinations outside the typical
        // piano melody+accompaniment band (default MIDI 36–96).
        if let lo = config.minPitch {
            stage = stage.compactMap { note in
                if note.pitch < lo { report.droppedOutOfPitchRange += 1; return nil }
                return note
            }
        }
        if let hi = config.maxPitch {
            stage = stage.compactMap { note in
                if note.pitch > hi { report.droppedOutOfPitchRange += 1; return nil }
                return note
            }
        }

        // Stage 0b: low-velocity ghost-note gate.
        if config.minVelocity > 1 {
            let floor = config.minVelocity
            stage = stage.compactMap { note in
                if note.velocity < floor { report.droppedLowVelocity += 1; return nil }
                return note
            }
        }

        // Stage 1: clamp note end to source audio duration if known.
        if let audio = config.audioDurationSeconds, audio > 0 {
            stage = stage.compactMap { note in
                let end = note.onset + note.duration
                if note.onset >= audio {
                    // Note starts after audio ends — pure pipeline bug.
                    report.droppedNegativeDuration += 1
                    return nil
                }
                if end > audio + 0.001 {
                    report.clampedToAudioDuration += 1
                    let trimmed = audio - note.onset
                    return MIDINote(id: note.id, pitch: note.pitch,
                                    onset: note.onset,
                                    duration: max(0.001, trimmed),
                                    velocity: note.velocity)
                }
                return note
            }
        }

        // Stage 2: long-note handling.
        stage = stage.compactMap { note -> MIDINote? in
            if note.duration > config.maxNoteDurationSeconds && !config.sustainPedalDeclared {
                report.droppedLongNotes += 1
                return nil
            }
            if note.duration > config.softLongNoteSeconds
                && note.duration <= config.maxNoteDurationSeconds
                && note.velocity <= config.lowConfidenceVelocity
                && !config.sustainPedalDeclared {
                report.clampedLongNotes += 1
                return MIDINote(id: note.id, pitch: note.pitch,
                                onset: note.onset,
                                duration: config.softLongNoteSeconds,
                                velocity: note.velocity)
            }
            return note
        }

        // Stage 3: exact-onset pileup pruning. Same onset, same pitch is
        // always a duplicate. Same onset across many pitches is suspicious
        // when it exceeds the cluster cap; let stage 4 handle that.
        stage = pruneExactPileups(stage, report: &report)

        // Stage 3b: cap notes per exact-onset timestamp across pitches.
        // Keeps the strongest `maxNotesPerExactOnset` so a single quantized
        // frame can't deliver dozens of simultaneous chord-tones.
        stage = capPerExactOnset(stage,
                                 maxPerOnset: config.maxNotesPerExactOnset,
                                 report: &report)

        // Stage 4: onset cluster pruning (>N notes within 50ms).
        stage = pruneOnsetClusters(stage,
                                   window: config.clusterWindowSeconds,
                                   maxPerWindow: config.maxNotesPerClusterWindow,
                                   report: &report)

        // Stage 5: density pruning (>N notes per 1s bucket).
        stage = pruneDensityBuckets(stage,
                                    bucketSize: config.densityBucketSeconds,
                                    maxPerBucket: config.maxNotesPerDensityBucket,
                                    report: &report)

        // Stage 5b: sustain-aware ghost-note repair. Run before the same-pitch
        // overlap stage so model fragments collapsed here don't get re-trimmed
        // immediately after, and so `resolveSamePitchOverlap` sees clean
        // single-note hold blocks.
        if config.sustainRepairEnabled {
            stage = repairSustainGhostNotes(stage, config: config, report: &report)
        }

        // Stage 6: same-pitch overlap.
        stage = resolveSamePitchOverlap(stage,
                                        merge: config.mergeSamePitchOverlap,
                                        mergeGap: config.samePitchMergeGap,
                                        report: &report)

        // Stage 6a: isolated-tiny prune. Drops very short notes with no
        // neighbor (any pitch) within ±neighborWindow seconds. Catches
        // single-frame ghost notes that survived earlier stages because
        // their cluster wasn't dense enough to trip the cluster cap.
        if config.isolatedTinyMaxDuration > 0 {
            let onsets = stage.map(\.onset).sorted()
            let win = config.isolatedTinyNeighborWindow
            let tinyMax = config.isolatedTinyMaxDuration
            stage = stage.filter { note in
                guard note.duration <= tinyMax else { return true }
                // Binary search for any neighbor onset within ±win.
                var lo = 0, hi = onsets.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if onsets[mid] < note.onset - win { lo = mid + 1 } else { hi = mid }
                }
                let lower = note.onset - win
                let upper = note.onset + win
                var hasNeighbor = false
                var i = lo
                while i < onsets.count, onsets[i] <= upper {
                    if onsets[i] >= lower && abs(onsets[i] - note.onset) > 1e-9 {
                        hasNeighbor = true; break
                    }
                    i += 1
                }
                if !hasNeighbor {
                    report.droppedIsolatedTiny += 1
                    return false
                }
                return true
            }
        }

        // Stage 6b: simultaneous-notes cap. Sweep an event list (on/off pairs)
        // and drop any note-on that would push the active count above the
        // configured cap, keeping the strongest by velocity. Catches massive
        // chord pile-ups that survived per-window caps.
        stage = capSimultaneousNotes(stage, max: config.maxSimultaneousNotes, report: &report)

        // Stage 7 (final): force timeline match. Drops anything ending past
        // audio + tolerance. This stage exists because earlier stages can
        // accidentally extend a note end (overlap merge, etc.) and we want
        // the surviving MIDI to fit inside the source audio length.
        if config.forceTimelineMatch, let audio = config.audioDurationSeconds, audio > 0 {
            let limit = audio + config.timelineMatchToleranceSeconds
            stage = stage.compactMap { note in
                let end = note.onset + note.duration
                if note.onset >= limit {
                    report.droppedTimelineOverflow += 1
                    return nil
                }
                if end > limit {
                    let trimmed = max(0.001, audio - note.onset)
                    report.droppedTimelineOverflow += 1
                    return MIDINote(id: note.id, pitch: note.pitch,
                                    onset: note.onset,
                                    duration: trimmed,
                                    velocity: note.velocity)
                }
                return note
            }
        }

        // Final sort by onset for stable downstream behavior.
        stage.sort { $0.onset < $1.onset }
        report.outputCount = stage.count
        return Outcome(raw: raw, cleaned: stage, report: report)
    }

    // MARK: - Stages

    private static func pruneExactPileups(_ notes: [MIDINote], report: inout Report) -> [MIDINote] {
        // Group strictly by exact onset (Double identity).
        let grouped = Dictionary(grouping: notes, by: { $0.onset })
        var out: [MIDINote] = []
        out.reserveCapacity(notes.count)
        for (_, group) in grouped {
            if group.count == 1 {
                out.append(group[0])
                continue
            }
            // Within an exact-onset group, deduplicate per pitch keeping the
            // strongest velocity; the rest are recorded as pileup removals.
            let byPitch = Dictionary(grouping: group, by: \.pitch)
            for (_, pgroup) in byPitch {
                let strongest = pgroup.max(by: { $0.velocity < $1.velocity })!
                out.append(strongest)
                report.prunedExactPileup += pgroup.count - 1
            }
        }
        return out
    }

    /// Cap the number of distinct notes (across pitches) at the same exact
    /// onset timestamp. This is the cross-pitch counterpart to
    /// `pruneExactPileups` (which only kills same-pitch duplicates).
    private static func capPerExactOnset(_ notes: [MIDINote], maxPerOnset: Int, report: inout Report) -> [MIDINote] {
        guard maxPerOnset > 0 else { return notes }
        let grouped = Dictionary(grouping: notes, by: { $0.onset })
        var out: [MIDINote] = []
        out.reserveCapacity(notes.count)
        for (_, group) in grouped {
            if group.count <= maxPerOnset {
                out.append(contentsOf: group)
                continue
            }
            let sorted = group.sorted { a, b in
                if a.velocity != b.velocity { return a.velocity > b.velocity }
                return a.pitch < b.pitch
            }
            out.append(contentsOf: sorted.prefix(maxPerOnset))
            report.prunedExactOnsetCap += group.count - maxPerOnset
        }
        return out
    }

    private static func pruneOnsetClusters(_ notes: [MIDINote], window: Double, maxPerWindow: Int, report: inout Report) -> [MIDINote] {
        guard !notes.isEmpty, window > 0, maxPerWindow > 0 else { return notes }
        let sorted = notes.sorted { $0.onset < $1.onset }
        var keep = Array(repeating: true, count: sorted.count)
        var i = 0
        while i < sorted.count {
            // Find the largest j such that sorted[j].onset - sorted[i].onset <= window.
            var j = i
            while j < sorted.count && sorted[j].onset - sorted[i].onset <= window {
                j += 1
            }
            let groupRange = i..<j
            let groupCount = groupRange.count
            if groupCount > maxPerWindow {
                // Keep the strongest `maxPerWindow` by velocity (then by pitch
                // for stable ordering); drop the rest.
                let indices = Array(groupRange)
                let sortedByConfidence = indices.sorted { a, b in
                    if sorted[a].velocity != sorted[b].velocity {
                        return sorted[a].velocity > sorted[b].velocity
                    }
                    return sorted[a].pitch < sorted[b].pitch
                }
                let dropped = sortedByConfidence.dropFirst(maxPerWindow)
                for idx in dropped { keep[idx] = false }
                report.prunedFromClusters += dropped.count
                // Advance past this cluster window to avoid re-evaluating.
                i = j
            } else {
                i += 1
            }
        }
        return zip(sorted, keep).compactMap { $1 ? $0 : nil }
    }

    private static func pruneDensityBuckets(_ notes: [MIDINote], bucketSize: Double, maxPerBucket: Int, report: inout Report) -> [MIDINote] {
        guard !notes.isEmpty, bucketSize > 0, maxPerBucket > 0 else { return notes }
        let buckets = Dictionary(grouping: notes.indices) { Int(notes[$0].onset / bucketSize) }
        var keep = Array(repeating: true, count: notes.count)
        for (_, indices) in buckets where indices.count > maxPerBucket {
            let sortedByConfidence = indices.sorted { a, b in
                if notes[a].velocity != notes[b].velocity {
                    return notes[a].velocity > notes[b].velocity
                }
                return notes[a].onset < notes[b].onset
            }
            for idx in sortedByConfidence.dropFirst(maxPerBucket) {
                keep[idx] = false
                report.prunedFromDensity += 1
            }
        }
        return zip(notes, keep).compactMap { $1 ? $0 : nil }
    }

    private static func resolveSamePitchOverlap(_ notes: [MIDINote], merge: Bool, mergeGap: Double, report: inout Report) -> [MIDINote] {
        // Group by pitch, sort by onset, walk pairs.
        let byPitch = Dictionary(grouping: notes, by: \.pitch)
        var out: [MIDINote] = []
        out.reserveCapacity(notes.count)
        for (_, group) in byPitch {
            let sorted = group.sorted { $0.onset < $1.onset }
            var current = sorted[0]
            for next in sorted.dropFirst() {
                let curEnd = current.onset + current.duration
                if next.onset >= curEnd - 1e-6 {
                    out.append(current)
                    current = next
                    continue
                }
                // Overlap. Decide between merge vs trim.
                let overlap = curEnd - next.onset
                if merge && overlap <= mergeGap {
                    // Merge into one sustained note keeping the stronger velocity.
                    let mergedEnd = max(curEnd, next.onset + next.duration)
                    current = MIDINote(
                        id: current.id, pitch: current.pitch,
                        onset: current.onset,
                        duration: mergedEnd - current.onset,
                        velocity: max(current.velocity, next.velocity)
                    )
                    report.mergedSamePitchOverlap += 1
                } else {
                    // Trim previous note tail to the next onset.
                    let trimmedDur = max(0.001, next.onset - current.onset)
                    let trimmed = MIDINote(
                        id: current.id, pitch: current.pitch,
                        onset: current.onset,
                        duration: trimmedDur,
                        velocity: current.velocity
                    )
                    out.append(trimmed)
                    current = next
                    report.trimmedSamePitchOverlap += 1
                }
            }
            out.append(current)
        }
        return out
    }

    /// Stream-of-events cap on simultaneous active notes. Generates
    /// (onset, +1) and (onset+duration, -1) events from the input, walks them
    /// in time order, and drops any note-on that would push the active count
    /// above `max`. When choosing which note to drop within a tie we prefer
    /// the lowest-velocity one (keeps the musically dominant chord).
    private static func capSimultaneousNotes(_ notes: [MIDINote], max: Int, report: inout Report) -> [MIDINote] {
        guard max > 0, notes.count > max else { return notes }

        struct EvtKey { let time: Double; let kind: Int; let idx: Int } // kind: -1 off, +1 on
        // Sort by time; ties: offs first so a note ending and a note starting
        // at the same instant don't double-count.
        var events: [EvtKey] = []
        events.reserveCapacity(notes.count * 2)
        for (i, n) in notes.enumerated() {
            events.append(EvtKey(time: n.onset, kind: 1, idx: i))
            events.append(EvtKey(time: n.onset + n.duration, kind: -1, idx: i))
        }
        events.sort { a, b in
            if a.time != b.time { return a.time < b.time }
            return a.kind < b.kind
        }

        var active: Set<Int> = []
        var dropped: Set<Int> = []
        for evt in events {
            if dropped.contains(evt.idx) { continue }
            if evt.kind == 1 {
                if active.count >= max {
                    // Drop either the new note or the weakest active one.
                    let newVel = notes[evt.idx].velocity
                    if let weakest = active.min(by: { notes[$0].velocity < notes[$1].velocity }),
                       notes[weakest].velocity < newVel {
                        active.remove(weakest)
                        dropped.insert(weakest)
                        active.insert(evt.idx)
                    } else {
                        dropped.insert(evt.idx)
                    }
                } else {
                    active.insert(evt.idx)
                }
            } else {
                active.remove(evt.idx)
            }
        }
        report.prunedSimultaneousCap += dropped.count
        return notes.enumerated().compactMap { dropped.contains($0.offset) ? nil : $0.element }
    }

    /// Sustain-aware ghost-note repair.
    ///
    /// Two sub-passes operate on a single ordered-by-onset working array:
    ///   • Pass A — same-pitch fragment merge: walks each pitch's notes in
    ///     order; when a follow-up note starts inside or just after the
    ///     prior note's tail (within `sustainSamePitchMergeGap`) it gets
    ///     folded into the held note rather than treated as a re-strike.
    ///     Real re-strikes have a perceptible silent gap and are preserved.
    ///   • Pass B — ghost-note removal: scans notes that are short AND weak,
    ///     and drops any whose onset sits inside another (different-pitch)
    ///     note's sustain tail UNLESS it forms part of a chord onset
    ///     (≥1 other distinct pitch starting within `chordOnsetWindow` on
    ///     either side). The chord-onset gate is what protects real
    ///     simultaneously-struck chords played on top of a held bass.
    private static func repairSustainGhostNotes(
        _ notes: [MIDINote],
        config: Config,
        report: inout Report
    ) -> [MIDINote] {
        guard !notes.isEmpty else { return notes }
        var sorted = notes.sorted { $0.onset < $1.onset }
        var keep = Array(repeating: true, count: sorted.count)

        // Pass A — same-pitch fragment merge.
        var byPitch: [Int: [Int]] = [:]
        for (i, n) in sorted.enumerated() {
            byPitch[n.pitch, default: []].append(i)
        }
        let mergeGap = config.sustainSamePitchMergeGap
        // Sustain-fragment merging only applies when the two pieces are
        // separated by at most `mergeGap` of silence OR a tiny overlap (one
        // analysis frame, ~30ms). Heavier overlap means a real re-strike and
        // is left to the existing same-pitch overlap stage to handle.
        let maxFragmentOverlap = 0.030
        for (_, indices) in byPitch where indices.count > 1 {
            var i = 0
            while i < indices.count {
                let idxI = indices[i]
                if !keep[idxI] { i += 1; continue }
                var j = i + 1
                while j < indices.count {
                    let idxJ = indices[j]
                    if !keep[idxJ] { j += 1; continue }
                    let a = sorted[idxI]
                    let b = sorted[idxJ]
                    let aEnd = a.onset + a.duration
                    let gap = b.onset - aEnd          // >0 silent gap, <0 overlap
                    if gap >= -maxFragmentOverlap && gap <= mergeGap {
                        let newEnd = max(aEnd, b.onset + b.duration)
                        sorted[idxI] = MIDINote(
                            id: a.id, pitch: a.pitch,
                            onset: a.onset,
                            duration: max(0.001, newEnd - a.onset),
                            velocity: max(a.velocity, b.velocity)
                        )
                        keep[idxJ] = false
                        report.mergedSustainFragments += 1
                        j += 1
                    } else {
                        break
                    }
                }
                i += 1
            }
        }

        // Pass B — ghost-note removal inside a different-pitch sustain tail.
        let chordWindow = config.chordOnsetWindowSeconds
        let ghostMaxDur = config.ghostNoteMaxDuration
        let ghostMaxVel = config.ghostNoteMaxVelocity
        // Lookback bound: no need to scan earlier than maxNoteDurationSeconds
        // before the candidate's onset — anything earlier has ended.
        let lookbackBound = config.maxNoteDurationSeconds
        for i in sorted.indices where keep[i] {
            let n = sorted[i]
            // Ghost candidates must be both short AND weak.
            guard n.duration < ghostMaxDur, n.velocity < ghostMaxVel else { continue }

            // Chord-onset companion check on either side.
            var hasChordCompanion = false
            var k = i - 1
            while k >= 0, n.onset - sorted[k].onset <= chordWindow {
                if keep[k], sorted[k].pitch != n.pitch {
                    hasChordCompanion = true; break
                }
                k -= 1
            }
            if !hasChordCompanion {
                k = i + 1
                while k < sorted.count, sorted[k].onset - n.onset <= chordWindow {
                    if keep[k], sorted[k].pitch != n.pitch {
                        hasChordCompanion = true; break
                    }
                    k += 1
                }
            }
            if hasChordCompanion { continue }

            // Containment check: is n's onset inside a longer different-pitch tail?
            var enclosed = false
            var j = i - 1
            while j >= 0 {
                let cand = sorted[j]
                if n.onset - cand.onset > lookbackBound { break }
                if keep[j], cand.pitch != n.pitch {
                    let candEnd = cand.onset + cand.duration
                    if cand.onset < n.onset && candEnd > n.onset + 0.005 {
                        enclosed = true; break
                    }
                }
                j -= 1
            }

            if enclosed {
                keep[i] = false
                report.droppedSustainGhost += 1
            }
        }

        return zip(sorted, keep).compactMap { $1 ? $0 : nil }
    }
}
