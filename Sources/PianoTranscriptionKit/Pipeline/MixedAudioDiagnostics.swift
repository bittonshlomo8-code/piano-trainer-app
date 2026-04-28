import Foundation

/// Detailed diagnostics for one run of the precision pipeline. Persisted
/// next to the run artifacts as JSON so the user (or a future analysis
/// tool) can audit why output looks the way it does.
public struct MixedAudioDiagnostics: Codable, Equatable {
    public let totalNotes: Int
    public let pitchMin: Int?
    public let pitchMax: Int?
    /// Notes per second over 1-second buckets, indexed by integer second
    /// from the start of the run.
    public let densityPerSecond: [Int]
    /// Histogram of pitches by octave (key = octave number, e.g. 4 for C4).
    public let octaveHistogram: [Int: Int]
    public let maxNoteDuration: Double
    public let medianNoteDuration: Double
    public let meanNoteDuration: Double
    /// Stem duration vs. source duration: `|src - stem|` in seconds.
    /// 0 when no separation was performed.
    public let timelineDriftSeconds: Double
    /// Counters from the post-processor (ghosts dropped, etc).
    public let postProcessorCounters: [String: Int]
    /// Free-form warning lines explaining likely failure modes — surfaced
    /// in diagnostics UI / logs.
    public let warnings: [String]

    public init(
        totalNotes: Int,
        pitchMin: Int?,
        pitchMax: Int?,
        densityPerSecond: [Int],
        octaveHistogram: [Int: Int],
        maxNoteDuration: Double,
        medianNoteDuration: Double,
        meanNoteDuration: Double,
        timelineDriftSeconds: Double,
        postProcessorCounters: [String: Int],
        warnings: [String]
    ) {
        self.totalNotes = totalNotes
        self.pitchMin = pitchMin
        self.pitchMax = pitchMax
        self.densityPerSecond = densityPerSecond
        self.octaveHistogram = octaveHistogram
        self.maxNoteDuration = maxNoteDuration
        self.medianNoteDuration = medianNoteDuration
        self.meanNoteDuration = meanNoteDuration
        self.timelineDriftSeconds = timelineDriftSeconds
        self.postProcessorCounters = postProcessorCounters
        self.warnings = warnings
    }

    public static let empty = MixedAudioDiagnostics(
        totalNotes: 0, pitchMin: nil, pitchMax: nil,
        densityPerSecond: [], octaveHistogram: [:],
        maxNoteDuration: 0, medianNoteDuration: 0, meanNoteDuration: 0,
        timelineDriftSeconds: 0, postProcessorCounters: [:], warnings: []
    )
}

/// Builder that derives a `MixedAudioDiagnostics` from raw + processed
/// notes plus run context.
public enum MixedAudioDiagnosticsBuilder {

    public struct Context {
        public let sourceDurationSeconds: Double
        public let stemDurationSeconds: Double?
        public let post: MixedAudioPostProcessor.Report
        public let burstWindowSeconds: Double

        public init(
            sourceDurationSeconds: Double,
            stemDurationSeconds: Double?,
            post: MixedAudioPostProcessor.Report,
            burstWindowSeconds: Double = 0.05
        ) {
            self.sourceDurationSeconds = sourceDurationSeconds
            self.stemDurationSeconds = stemDurationSeconds
            self.post = post
            self.burstWindowSeconds = burstWindowSeconds
        }
    }

    public static func build(
        notes: [MIDINote],
        context: Context
    ) -> MixedAudioDiagnostics {
        guard !notes.isEmpty else {
            var warnings: [String] = ["No notes survived post-processing — separation may have failed or audio is silent."]
            if let stem = context.stemDurationSeconds {
                let drift = abs(context.sourceDurationSeconds - stem)
                if drift > 0.5 {
                    warnings.append(String(format: "Stem duration (%.2fs) differs from source (%.2fs) by %.2fs.",
                                           stem, context.sourceDurationSeconds, drift))
                }
            }
            return MixedAudioDiagnostics(
                totalNotes: 0, pitchMin: nil, pitchMax: nil,
                densityPerSecond: [], octaveHistogram: [:],
                maxNoteDuration: 0, medianNoteDuration: 0, meanNoteDuration: 0,
                timelineDriftSeconds: context.stemDurationSeconds.map { abs($0 - context.sourceDurationSeconds) } ?? 0,
                postProcessorCounters: counters(from: context.post),
                warnings: warnings
            )
        }

        let durations = notes.map(\.duration).sorted()
        let median = durations[durations.count / 2]
        let mean = durations.reduce(0, +) / Double(durations.count)
        let maxDur = durations.last ?? 0
        let pitches = notes.map(\.pitch)
        let pitchMin = pitches.min()
        let pitchMax = pitches.max()

        let totalSeconds = max(1, Int(notes.map { $0.onset + $0.duration }.max() ?? 0) + 1)
        var density = [Int](repeating: 0, count: totalSeconds)
        for n in notes {
            let bucket = max(0, min(totalSeconds - 1, Int(n.onset)))
            density[bucket] += 1
        }

        var histogram: [Int: Int] = [:]
        for p in pitches {
            let octave = (p / 12) - 1
            histogram[octave, default: 0] += 1
        }

        // Burst detector: any window with > 12 onsets/sec is suspicious for
        // mixed audio. Tracks burstWindowSeconds-sized rolling windows.
        var burstCount = 0
        if !notes.isEmpty {
            let sortedOnsets = notes.map(\.onset).sorted()
            let window = context.burstWindowSeconds
            var start = 0
            for end in sortedOnsets.indices {
                while sortedOnsets[end] - sortedOnsets[start] > window { start += 1 }
                let count = end - start + 1
                if count > 12 { burstCount += 1 }
            }
        }

        var warnings: [String] = []
        if context.post.ghostsDropped > notes.count {
            warnings.append("Ghost notes outnumbered surviving notes \(context.post.ghostsDropped) → \(notes.count) — input is likely noisier than expected.")
        }
        if context.post.clampedLongNotes > 0 {
            warnings.append("Clamped \(context.post.clampedLongNotes) impossibly long note(s) — detector likely held a sustained drone.")
        }
        if context.post.longNoteWarnings > 0 {
            warnings.append("\(context.post.longNoteWarnings) note(s) longer than warning threshold — verify they are real sustained notes.")
        }
        if burstCount > 0 {
            warnings.append("Detected \(burstCount) onset burst(s) — likely percussion or sibilance leakage.")
        }
        if let lo = pitchMin, lo < 28 {
            warnings.append("Lowest detected pitch is \(lo) (below A0 + a few keys) — possible sub-octave alias.")
        }
        if let hi = pitchMax, hi > 100 {
            warnings.append("Highest detected pitch is \(hi) — possible super-octave alias from harmonics.")
        }
        if let stem = context.stemDurationSeconds {
            let drift = abs(context.sourceDurationSeconds - stem)
            if drift > 0.5 {
                warnings.append(String(format: "Stem duration (%.2fs) differs from source (%.2fs) by %.2fs — separation may have shifted the timeline.",
                                       stem, context.sourceDurationSeconds, drift))
            }
        }

        return MixedAudioDiagnostics(
            totalNotes: notes.count,
            pitchMin: pitchMin,
            pitchMax: pitchMax,
            densityPerSecond: density,
            octaveHistogram: histogram,
            maxNoteDuration: maxDur,
            medianNoteDuration: median,
            meanNoteDuration: mean,
            timelineDriftSeconds: context.stemDurationSeconds.map { abs($0 - context.sourceDurationSeconds) } ?? 0,
            postProcessorCounters: counters(from: context.post),
            warnings: warnings
        )
    }

    private static func counters(from report: MixedAudioPostProcessor.Report) -> [String: Int] {
        [
            "ghostsDropped": report.ghostsDropped,
            "shortDropped": report.shortDropped,
            "burstPruned": report.burstPruned,
            "overlapMerged": report.overlapMerged,
            "sustainMerged": report.sustainMerged,
            "clampedLongNotes": report.clampedLongNotes,
            "longNoteWarnings": report.longNoteWarnings,
            "octaveCorrections": report.octaveCorrections,
            "velocitySmoothed": report.velocitySmoothed,
        ]
    }
}
