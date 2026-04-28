import Foundation

/// Pure analysis of a `TranscriptionRun` against its source audio. Produces
/// statistics, structured issues, distributions, and a coarse quality score.
/// All thresholds are knobs on `Config` so tests can dial them.
public struct TranscriptionAnalysis: Equatable, Codable {

    public enum Status: String, Codable, Equatable { case pass, warning, fail }

    public enum Severity: String, Codable, Equatable {
        case info, warning, fail
    }

    public struct Issue: Identifiable, Equatable, Codable {
        public let id: String          // stable code, e.g. "long_note"
        public let severity: Severity
        public let title: String
        public let detail: String
        public let count: Int          // how many notes/events triggered this issue

        public init(id: String, severity: Severity, title: String, detail: String, count: Int) {
            self.id = id; self.severity = severity; self.title = title
            self.detail = detail; self.count = count
        }
    }

    public struct Stats: Equatable, Codable {
        public let totalNotes: Int
        public let runDuration: Double          // latest note end, seconds
        public let audioDuration: Double?       // file duration, if known
        public let notesPerSecond: Double
        public let minPitch: Int?
        public let maxPitch: Int?
        /// Histogram keyed by octave number (0…10 maps to standard MIDI octaves; A0 = octave 0).
        public let octaveHistogram: [Int: Int]
        public let medianDuration: Double
        public let maxDuration: Double
        public let medianVelocity: Int
        public let avgVelocity: Double          // velocity proxy for "average confidence"
    }

    public struct DensityBucket: Equatable, Codable {
        public let startSeconds: Double
        public let endSeconds: Double
        public let noteCount: Int
    }

    public struct Cluster: Equatable, Codable {
        public let onsetSeconds: Double
        public let noteCount: Int
        public let pitches: [Int]
    }

    public struct LongNote: Equatable, Codable {
        public let pitch: Int
        public let onset: Double
        public let duration: Double
        public let velocity: Int
    }

    public let status: Status
    public let stats: Stats
    public let issues: [Issue]
    public let densityBuckets: [DensityBucket]
    public let suspiciousClusters: [Cluster]
    public let longestNotes: [LongNote]
    /// 0…1 — coarse quality score derived from issue severity. Lower means worse.
    public let qualityScore: Double
}

public struct TranscriptionDiagnosticsConfig: Equatable {
    public var longNoteSeconds: Double = 30.0
    public var sustainPedalDeclared: Bool = false
    public var simultaneousOnsetMin: Int = 4              // "many notes at exact same timestamp"
    public var nearSimultaneousMaxInWindow: Int = 8       // ">8 notes within 50ms"
    public var nearSimultaneousWindow: Double = 0.050
    public var densityBucketSeconds: Double = 1.0
    public var highDensityNotesPerSecond: Double = 25.0
    public var pianoRangeLow: Int = 36                    // C2
    public var pianoRangeHigh: Int = 96                   // C7
    public var pianoRangeMinFraction: Double = 0.6        // ≥60% of notes inside the typical range
    public var audioDurationToleranceSeconds: Double = 1.0
    public var samePitchOverlapMin: Int = 1               // any same-pitch overlap is suspicious
    public var clusterMaxToReport: Int = 10
    public var longNotesToReport: Int = 10

    // MARK: - Noisy-output / mixed-audio guardrails

    /// Soft cap on notes per minute. When the run's notes/minute exceeds
    /// this, we flag it as "likely noisy mixed-audio output". 250 notes/min
    /// (~4/sec) is already very dense for piano material.
    public var noisyMaxNotesPerMinute: Double = 250.0
    /// Pitch span (semitones, max-min). 70+ flags piano-implausible spread.
    public var noisyMaxPitchSpan: Int = 70
    /// Notes above this pitch are tallied; > `noisyMaxAbove`% of them flags
    /// "too many notes above C7" — typical of harmonic alias detection.
    public var noisyHighPitchCutoff: Int = 96
    public var noisyMaxAboveHighCutoffFraction: Double = 0.10
    /// Notes below this pitch likewise.
    public var noisyLowPitchCutoff: Int = 36
    public var noisyMaxBelowLowCutoffFraction: Double = 0.15
    /// Any 1-second window with this many notes triggers the flag.
    public var noisyMaxInOneSecondWindow: Int = 15
    /// Long notes (> seconds) without sustain evidence — count cap.
    public var noisyLongNoteSeconds: Double = 5.0
    public var noisyMaxLongNotes: Int = 30

    public init() {}
}

public enum TranscriptionDiagnostics {

    public static func analyze(
        notes: [MIDINote],
        audioDuration: Double? = nil,
        config: TranscriptionDiagnosticsConfig = .init()
    ) -> TranscriptionAnalysis {
        let stats = computeStats(notes: notes, audioDuration: audioDuration)
        var issues: [TranscriptionAnalysis.Issue] = []

        // 1. Long notes
        let longNotes = notes
            .filter { $0.duration > config.longNoteSeconds }
            .sorted { $0.duration > $1.duration }
        if !longNotes.isEmpty && !config.sustainPedalDeclared {
            issues.append(.init(
                id: "long_note",
                severity: .fail,
                title: "Notes longer than \(Int(config.longNoteSeconds))s",
                detail: "Without sustain-pedal handling these are almost always pipeline bugs (stuck note-on, missing note-off pairing, or inverted off/on event).",
                count: longNotes.count
            ))
        } else if !longNotes.isEmpty && config.sustainPedalDeclared {
            issues.append(.init(
                id: "long_note_sustained",
                severity: .info,
                title: "Long notes under sustain pedal",
                detail: "Sustain pedal handling is enabled — long notes are not flagged as failures.",
                count: longNotes.count
            ))
        }

        // 2. Many notes at the *exact* same onset (string-equal seconds → quantization smell)
        let exactGroups = Dictionary(grouping: notes, by: { $0.onset })
        let exactCollisions = exactGroups
            .filter { $0.value.count >= config.simultaneousOnsetMin }
        if !exactCollisions.isEmpty {
            let total = exactCollisions.values.reduce(0) { $0 + $1.count }
            issues.append(.init(
                id: "exact_onset_pileup",
                severity: .warning,
                title: "≥\(config.simultaneousOnsetMin) notes at the same onset",
                detail: "Repeated identical onset timestamps usually mean the detector quantized many onsets to a single frame.",
                count: total
            ))
        }

        // 3. >N notes within a sliding window
        let clusters = findOnsetClusters(
            notes: notes,
            window: config.nearSimultaneousWindow,
            min: config.nearSimultaneousMaxInWindow + 1
        )
        if !clusters.isEmpty {
            let total = clusters.reduce(0) { $0 + $1.noteCount }
            issues.append(.init(
                id: "onset_cluster",
                severity: .warning,
                title: ">\(config.nearSimultaneousMaxInWindow) notes within \(Int(config.nearSimultaneousWindow*1000))ms",
                detail: "Dense onset clusters often indicate spurious detection on noisy audio or harmonic aliasing across pitch tracks.",
                count: total
            ))
        }

        // 4. Note density abnormally high
        let buckets = densityBuckets(notes: notes,
                                     totalDuration: max(stats.runDuration, audioDuration ?? 0),
                                     bucketSize: config.densityBucketSeconds)
        let hotBuckets = buckets.filter { Double($0.noteCount) >= config.highDensityNotesPerSecond * config.densityBucketSeconds }
        if !hotBuckets.isEmpty {
            issues.append(.init(
                id: "density_spike",
                severity: .warning,
                title: "High note density",
                detail: "\(hotBuckets.count) one-second window(s) exceed \(Int(config.highDensityNotesPerSecond)) notes/s — almost always over-detection.",
                count: hotBuckets.reduce(0) { $0 + $1.noteCount }
            ))
        }

        // 5. Pitch distribution mostly outside typical piano melody range
        if !notes.isEmpty {
            let inRange = notes.filter { $0.pitch >= config.pianoRangeLow && $0.pitch <= config.pianoRangeHigh }.count
            let frac = Double(inRange) / Double(notes.count)
            if frac < config.pianoRangeMinFraction {
                issues.append(.init(
                    id: "pitch_out_of_range",
                    severity: .warning,
                    title: "Pitch distribution outside typical piano range",
                    detail: String(format: "Only %.0f%% of notes fall in MIDI %d–%d. Likely sub-harmonic alias detection.", frac*100, config.pianoRangeLow, config.pianoRangeHigh),
                    count: notes.count - inRange
                ))
            }
        }

        // 6. MIDI duration vs audio duration mismatch
        if let audio = audioDuration, audio > 0, !notes.isEmpty {
            let drift = abs(stats.runDuration - audio)
            if drift > config.audioDurationToleranceSeconds {
                issues.append(.init(
                    id: "duration_mismatch",
                    severity: .fail,
                    title: "Timeline drifts from audio",
                    detail: String(format: "MIDI ends at %.2fs, audio is %.2fs (Δ %.2fs). Pipeline timebase is wrong.", stats.runDuration, audio, drift),
                    count: 1
                ))
            }
        }

        // 7. Same-pitch self-overlap (no released note before next one starts on the same pitch)
        let overlaps = samePitchOverlaps(notes: notes)
        if overlaps >= config.samePitchOverlapMin {
            issues.append(.init(
                id: "same_pitch_overlap",
                severity: .warning,
                title: "Same pitch overlaps itself",
                detail: "\(overlaps) note(s) start before the previous note on the same pitch ended. Indicates missed note-off pairing.",
                count: overlaps
            ))
        }

        // 8. "Notes during silent audio" can't be computed without an RMS profile;
        //    that's exposed as a separate entry point so callers that have audio
        //    samples can pass them in. The analyzer itself surfaces a placeholder
        //    that's only added when callers hand us an RMS profile.

        // 9. Noisy-output composite. Specifically targeted at the
        //    mixed-audio failure mode (1,835 notes / 90 long / 286 high /
        //    442 low) so the UI can surface a single "this run is noisy"
        //    flag instead of forcing the user to correlate four metrics.
        if !notes.isEmpty {
            var triggers: [String] = []
            let runDur = stats.runDuration > 0 ? stats.runDuration : (audioDuration ?? 0)
            if runDur > 0 {
                let nm = Double(notes.count) / max(runDur / 60.0, 1e-3)
                if nm > config.noisyMaxNotesPerMinute {
                    triggers.append(String(format: "%.0f notes/min > %.0f", nm, config.noisyMaxNotesPerMinute))
                }
            }
            if let lo = stats.minPitch, let hi = stats.maxPitch {
                let span = hi - lo
                if span > config.noisyMaxPitchSpan {
                    triggers.append("pitch span \(span) > \(config.noisyMaxPitchSpan) semitones")
                }
            }
            let aboveCount = notes.filter { $0.pitch > config.noisyHighPitchCutoff }.count
            let aboveFrac = Double(aboveCount) / Double(notes.count)
            if aboveFrac > config.noisyMaxAboveHighCutoffFraction {
                triggers.append("\(aboveCount) notes above MIDI \(config.noisyHighPitchCutoff)")
            }
            let belowCount = notes.filter { $0.pitch < config.noisyLowPitchCutoff }.count
            let belowFrac = Double(belowCount) / Double(notes.count)
            if belowFrac > config.noisyMaxBelowLowCutoffFraction {
                triggers.append("\(belowCount) notes below MIDI \(config.noisyLowPitchCutoff)")
            }
            if let peakBucket = buckets.max(by: { $0.noteCount < $1.noteCount }) {
                if peakBucket.noteCount > config.noisyMaxInOneSecondWindow {
                    triggers.append("\(peakBucket.noteCount) notes in one second")
                }
            }
            let longRecognized = notes.filter { $0.duration > config.noisyLongNoteSeconds }.count
            if longRecognized > config.noisyMaxLongNotes && !config.sustainPedalDeclared {
                triggers.append("\(longRecognized) notes longer than \(Int(config.noisyLongNoteSeconds))s")
            }
            if triggers.count >= 2 {
                issues.append(.init(
                    id: "noisy_output",
                    severity: .fail,
                    title: "Output looks like mixed-audio noise",
                    detail: "Likely a model-vs-input mismatch (model expects clean piano audio). Triggers: " + triggers.joined(separator: "; ") + ". Try Mixed Audio / Piano Isolation.",
                    count: triggers.count
                ))
            }
        }

        let status = aggregateStatus(issues)
        let quality = qualityScore(notes: notes, issues: issues, audioDuration: audioDuration)

        let topClusters = Array(clusters.prefix(config.clusterMaxToReport))
        let topLong = Array(longNotes.prefix(config.longNotesToReport)).map {
            TranscriptionAnalysis.LongNote(pitch: $0.pitch, onset: $0.onset, duration: $0.duration, velocity: $0.velocity)
        }

        return TranscriptionAnalysis(
            status: status,
            stats: stats,
            issues: issues,
            densityBuckets: buckets,
            suspiciousClusters: topClusters,
            longestNotes: topLong,
            qualityScore: quality
        )
    }

    /// Adds an additional issue when the caller has an RMS profile of the source
    /// audio and notes appear during near-silent regions. Threshold is in
    /// linear amplitude (0…1).
    public static func annotateSilenceMismatches(
        analysis: TranscriptionAnalysis,
        notes: [MIDINote],
        rmsProfile: [Float],
        rmsHopSeconds: Double,
        silenceThreshold: Float = 0.005
    ) -> TranscriptionAnalysis {
        guard !rmsProfile.isEmpty, rmsHopSeconds > 0 else { return analysis }
        var triggered = 0
        for note in notes {
            let idx = Int(note.onset / rmsHopSeconds)
            guard idx >= 0 && idx < rmsProfile.count else { continue }
            if rmsProfile[idx] < silenceThreshold { triggered += 1 }
        }
        guard triggered > 0 else { return analysis }
        var issues = analysis.issues
        issues.append(.init(
            id: "notes_in_silence",
            severity: .fail,
            title: "Notes during near-silent audio",
            detail: "\(triggered) note onset(s) land in regions where the source RMS is below \(silenceThreshold). Detector is hallucinating.",
            count: triggered
        ))
        let status = aggregateStatus(issues)
        let quality = qualityScore(notes: notes, issues: issues, audioDuration: analysis.stats.audioDuration)
        return TranscriptionAnalysis(
            status: status,
            stats: analysis.stats,
            issues: issues,
            densityBuckets: analysis.densityBuckets,
            suspiciousClusters: analysis.suspiciousClusters,
            longestNotes: analysis.longestNotes,
            qualityScore: quality
        )
    }

    // MARK: - Helpers

    static func computeStats(notes: [MIDINote], audioDuration: Double?) -> TranscriptionAnalysis.Stats {
        let total = notes.count
        let runDur = notes.map { $0.onset + $0.duration }.max() ?? 0
        let denom = max(runDur, audioDuration ?? 0)
        let nps = denom > 0 ? Double(total) / denom : 0
        let pitches = notes.map(\.pitch)
        let durations = notes.map(\.duration).sorted()
        let velocities = notes.map(\.velocity).sorted()

        var hist: [Int: Int] = [:]
        for p in pitches {
            // MIDI 21=A0 is octave 0 in the MIDI sense (C-1 == 0 → octave -1).
            // We use the standard scientific octave: octave = (pitch / 12) - 1.
            let octave = (p / 12) - 1
            hist[octave, default: 0] += 1
        }

        return .init(
            totalNotes: total,
            runDuration: runDur,
            audioDuration: audioDuration,
            notesPerSecond: nps,
            minPitch: pitches.min(),
            maxPitch: pitches.max(),
            octaveHistogram: hist,
            medianDuration: median(durations),
            maxDuration: durations.last ?? 0,
            medianVelocity: Int(median(velocities.map(Double.init))),
            avgVelocity: velocities.isEmpty ? 0 : Double(velocities.reduce(0, +)) / Double(velocities.count)
        )
    }

    static func densityBuckets(notes: [MIDINote], totalDuration: Double, bucketSize: Double) -> [TranscriptionAnalysis.DensityBucket] {
        guard totalDuration > 0, bucketSize > 0 else { return [] }
        let bucketCount = Int(ceil(totalDuration / bucketSize))
        var counts = Array(repeating: 0, count: bucketCount)
        for note in notes {
            let idx = min(bucketCount - 1, max(0, Int(note.onset / bucketSize)))
            counts[idx] += 1
        }
        return counts.enumerated().map { i, c in
            .init(startSeconds: Double(i) * bucketSize,
                  endSeconds: Double(i + 1) * bucketSize,
                  noteCount: c)
        }
    }

    static func findOnsetClusters(notes: [MIDINote], window: Double, min: Int) -> [TranscriptionAnalysis.Cluster] {
        guard !notes.isEmpty, window > 0 else { return [] }
        let sorted = notes.sorted { $0.onset < $1.onset }
        var out: [TranscriptionAnalysis.Cluster] = []
        var i = 0
        while i < sorted.count {
            let start = sorted[i].onset
            var j = i
            while j < sorted.count && sorted[j].onset - start <= window { j += 1 }
            let group = Array(sorted[i..<j])
            if group.count >= min {
                out.append(.init(onsetSeconds: start,
                                 noteCount: group.count,
                                 pitches: group.map(\.pitch).sorted()))
                i = j
            } else {
                i += 1
            }
        }
        return out.sorted { $0.noteCount > $1.noteCount }
    }

    static func samePitchOverlaps(notes: [MIDINote]) -> Int {
        let byPitch = Dictionary(grouping: notes, by: { $0.pitch })
        var count = 0
        for (_, group) in byPitch {
            let sorted = group.sorted { $0.onset < $1.onset }
            for k in 1..<sorted.count {
                if sorted[k].onset < sorted[k-1].onset + sorted[k-1].duration - 1e-6 {
                    count += 1
                }
            }
        }
        return count
    }

    static func aggregateStatus(_ issues: [TranscriptionAnalysis.Issue]) -> TranscriptionAnalysis.Status {
        if issues.contains(where: { $0.severity == .fail }) { return .fail }
        if issues.contains(where: { $0.severity == .warning }) { return .warning }
        return .pass
    }

    static func qualityScore(notes: [MIDINote], issues: [TranscriptionAnalysis.Issue], audioDuration: Double?) -> Double {
        guard !notes.isEmpty else { return 0 }
        var score = 1.0
        for issue in issues {
            switch issue.severity {
            case .fail:    score -= 0.30
            case .warning: score -= 0.10
            case .info:    break
            }
        }
        return max(0, min(1, score))
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let n = xs.count
        if n.isMultiple(of: 2) { return (xs[n/2 - 1] + xs[n/2]) / 2 }
        return xs[n/2]
    }
}

// MARK: - Pipeline comparison

public struct RunComparison: Equatable {
    public struct Row: Equatable, Identifiable {
        public var id: UUID { runID }
        public let runID: UUID
        public let label: String
        public let pipelineName: String
        public let noteCount: Int
        public let avgVelocity: Double
        public let longNoteWarnings: Int
        public let ghostNoteWarnings: Int  // density + cluster + same-pitch overlap, summed
        public let octaveHistogram: [Int: Int]
        public let qualityScore: Double
        public let status: TranscriptionAnalysis.Status
    }

    public let rows: [Row]

    public static func compare(runs: [TranscriptionRun], audioDuration: Double?) -> RunComparison {
        let rows = runs.map { run -> Row in
            let analysis = TranscriptionDiagnostics.analyze(notes: run.notes, audioDuration: audioDuration)
            let long = analysis.issues.first { $0.id == "long_note" }?.count ?? 0
            let ghost = (analysis.issues.first { $0.id == "density_spike" }?.count ?? 0)
                      + (analysis.issues.first { $0.id == "onset_cluster" }?.count ?? 0)
                      + (analysis.issues.first { $0.id == "same_pitch_overlap" }?.count ?? 0)
            return Row(
                runID: run.id,
                label: run.label,
                pipelineName: run.pipelineName.isEmpty ? run.modelName : run.pipelineName,
                noteCount: run.notes.count,
                avgVelocity: analysis.stats.avgVelocity,
                longNoteWarnings: long,
                ghostNoteWarnings: ghost,
                octaveHistogram: analysis.stats.octaveHistogram,
                qualityScore: analysis.qualityScore,
                status: analysis.status
            )
        }
        return RunComparison(rows: rows)
    }
}
