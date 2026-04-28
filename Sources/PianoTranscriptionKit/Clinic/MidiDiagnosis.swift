import Foundation

/// Structured diagnosis of a candidate MIDI transcription. Pure function of
/// the note list + audio context. The clinic feeds this into the
/// `MidiRepairEngine` to decide which operations to apply.
public struct MidiDiagnosis: Equatable, Sendable, Codable {

    public enum Issue: String, Equatable, Sendable, Codable {
        case excessiveDensity
        case keyboardWidePitchRange
        case tooManyShortNotes
        case tooManyLongNotes
        case machineGunFragments
        case impossiblePolyphony
        case samePitchOverlaps
        case isolatedGhostNotes
        case timingJitter
        case brokenSustain
        case unsupportedLongSustain
        case likelyWrongPipeline
        case denseClusterRegions
        case noNotes
    }

    public struct Stats: Equatable, Sendable, Codable {
        public let totalNotes: Int
        public let durationSeconds: Double
        public let notesPerSecond: Double
        public let maxNotesIn1sWindow: Int
        public let pitchMin: Int?
        public let pitchMax: Int?
        public let pitchRangeWidth: Int
        public let notesBelowExpected: Int
        public let notesAboveExpected: Int
        public let maxSimultaneous: Int
        public let samePitchOverlapCount: Int
        public let machineGunRepeats: Int
        public let shorterThan80ms: Int
        public let shorterThan120ms: Int
        public let shorterThan150ms: Int
        public let longerThan8s: Int
        public let longerThan15s: Int
        public let isolatedNoteCount: Int
        public let denseClusterCount: Int
        public let ghostNoteFraction: Double
        public let sustainPlausibility: Double  // 0..1
        public let timingJitterMs: Double       // median IOI deviation
        public let chordPlausibility: Double    // 0..1
    }

    public let stats: Stats
    public let issues: [Issue]
    public let qualityScore: Double
    public let qualityGrade: MidiQualityScore.Grade
    public let problems: [String]
}

/// Builds a `MidiDiagnosis` from a candidate note list + audio context.
public enum MidiDiagnoser {

    public struct Context: Equatable, Sendable {
        /// Source-audio duration in seconds (the run-end is used when nil).
        public let audioDurationSeconds: Double?
        /// Expected pitch low/high for the active pipeline (drives
        /// "below/above expected range" counters).
        public let expectedPitchLow: Int
        public let expectedPitchHigh: Int
        /// Notes/sec considered "dense" for this kind of input.
        public let densityNotesPerSecondCap: Double
        /// Plausible polyphony cap.
        public let maxSimultaneousExpected: Int
        /// Scoring profile fed to `MidiQualityScorer` when computing the
        /// `qualityScore` field of the diagnosis.
        public let scoringProfile: MidiQualityScorer.Profile

        public static let cleanSoloPiano = Context(
            audioDurationSeconds: nil,
            expectedPitchLow: 21, expectedPitchHigh: 108,
            densityNotesPerSecondCap: 18,
            maxSimultaneousExpected: 8,
            scoringProfile: .cleanSoloPiano
        )
        public static let noisySoloPiano = Context(
            audioDurationSeconds: nil,
            expectedPitchLow: 36, expectedPitchHigh: 96,
            densityNotesPerSecondCap: 14,
            maxSimultaneousExpected: 6,
            scoringProfile: .noisySoloPiano
        )
        public static let mixedAudio = Context(
            audioDurationSeconds: nil,
            expectedPitchLow: 40, expectedPitchHigh: 88,
            densityNotesPerSecondCap: 8,
            maxSimultaneousExpected: 5,
            scoringProfile: .mixedInstruments
        )
        public static let melodyOnly = Context(
            audioDurationSeconds: nil,
            expectedPitchLow: 55, expectedPitchHigh: 84,
            densityNotesPerSecondCap: 8,
            maxSimultaneousExpected: 1,
            scoringProfile: .noisySoloPiano
        )

        public func with(audioDuration: Double?) -> Context {
            Context(
                audioDurationSeconds: audioDuration,
                expectedPitchLow: expectedPitchLow,
                expectedPitchHigh: expectedPitchHigh,
                densityNotesPerSecondCap: densityNotesPerSecondCap,
                maxSimultaneousExpected: maxSimultaneousExpected,
                scoringProfile: scoringProfile
            )
        }

        public init(
            audioDurationSeconds: Double?,
            expectedPitchLow: Int, expectedPitchHigh: Int,
            densityNotesPerSecondCap: Double,
            maxSimultaneousExpected: Int,
            scoringProfile: MidiQualityScorer.Profile
        ) {
            self.audioDurationSeconds = audioDurationSeconds
            self.expectedPitchLow = expectedPitchLow
            self.expectedPitchHigh = expectedPitchHigh
            self.densityNotesPerSecondCap = densityNotesPerSecondCap
            self.maxSimultaneousExpected = maxSimultaneousExpected
            self.scoringProfile = scoringProfile
        }
    }

    public static func diagnose(notes: [MIDINote], context: Context) -> MidiDiagnosis {
        let runEnd = notes.map { $0.onset + $0.duration }.max() ?? 0
        let durationDenom = max(context.audioDurationSeconds ?? runEnd, 0.001)

        guard !notes.isEmpty else {
            let stats = MidiDiagnosis.Stats(
                totalNotes: 0, durationSeconds: durationDenom,
                notesPerSecond: 0, maxNotesIn1sWindow: 0,
                pitchMin: nil, pitchMax: nil, pitchRangeWidth: 0,
                notesBelowExpected: 0, notesAboveExpected: 0,
                maxSimultaneous: 0, samePitchOverlapCount: 0,
                machineGunRepeats: 0,
                shorterThan80ms: 0, shorterThan120ms: 0, shorterThan150ms: 0,
                longerThan8s: 0, longerThan15s: 0,
                isolatedNoteCount: 0, denseClusterCount: 0,
                ghostNoteFraction: 0,
                sustainPlausibility: 0, timingJitterMs: 0, chordPlausibility: 0
            )
            return MidiDiagnosis(
                stats: stats,
                issues: [.noNotes],
                qualityScore: 0,
                qualityGrade: .bad,
                problems: ["No notes to diagnose."]
            )
        }

        let nps = Double(notes.count) / durationDenom
        let pitches = notes.map(\.pitch)
        let pitchMin = pitches.min()!
        let pitchMax = pitches.max()!
        let pitchSpan = pitchMax - pitchMin
        let below = notes.filter { $0.pitch < context.expectedPitchLow }.count
        let above = notes.filter { $0.pitch > context.expectedPitchHigh }.count
        let maxSimul = MidiQualityScorer.maxSimultaneousNoteCount(notes)
        let samePitchOverlaps = countSamePitchOverlaps(notes)
        let machineGun = MidiQualityScorer.machineGunCount(notes, minInterval: 0.05)
        let lt80  = notes.filter { $0.duration < 0.080 }.count
        let lt120 = notes.filter { $0.duration < 0.120 }.count
        let lt150 = notes.filter { $0.duration < 0.150 }.count
        let gt8   = notes.filter { $0.duration > 8.0  }.count
        let gt15  = notes.filter { $0.duration > 15.0 }.count
        let isolatedCount = countIsolatedNotes(notes)
        let denseClusterCount = countDenseClusters(notes)
        let maxIn1s = maxNotesIn1sWindow(notes)
        let ghostFrac = computeGhostFraction(notes: notes)
        let sustainPlausibility = computeSustainPlausibility(notes)
        let jitter = computeTimingJitterMs(notes)
        let chord = computeChordPlausibility(notes)

        var ctx = context
        ctx = ctx.with(audioDuration: context.audioDurationSeconds)
        let quality = MidiQualityScorer.score(
            notes: notes,
            audioDurationSeconds: context.audioDurationSeconds,
            profile: context.scoringProfile
        )

        var issues: [MidiDiagnosis.Issue] = []
        if nps > context.densityNotesPerSecondCap { issues.append(.excessiveDensity) }
        if pitchSpan > 64 { issues.append(.keyboardWidePitchRange) }
        if Double(lt120) / Double(notes.count) > 0.20 { issues.append(.tooManyShortNotes) }
        if gt8 > 0 { issues.append(.tooManyLongNotes) }
        if machineGun > 4 { issues.append(.machineGunFragments) }
        if maxSimul > context.maxSimultaneousExpected { issues.append(.impossiblePolyphony) }
        if samePitchOverlaps > 0 { issues.append(.samePitchOverlaps) }
        if isolatedCount > 3 { issues.append(.isolatedGhostNotes) }
        if jitter > 35 { issues.append(.timingJitter) }
        if denseClusterCount > 0 { issues.append(.denseClusterRegions) }
        if gt15 > 0 { issues.append(.unsupportedLongSustain) }
        // Broken-sustain heuristic: many adjacent same-pitch fragments.
        if countNeighborSamePitch(notes, gap: 0.30) > 4 && sustainPlausibility < 0.5 {
            issues.append(.brokenSustain)
        }
        // "likelyWrongPipeline" trigger: catastrophic mismatch between the
        // expected polyphony / pitch range AND density. Tells the user the
        // MODE choice was wrong (e.g. ran Clean Solo on full mixed track).
        if (pitchSpan > 64 && nps > context.densityNotesPerSecondCap * 1.5)
            || (maxSimul > context.maxSimultaneousExpected * 3) {
            issues.append(.likelyWrongPipeline)
        }

        let stats = MidiDiagnosis.Stats(
            totalNotes: notes.count,
            durationSeconds: durationDenom,
            notesPerSecond: nps,
            maxNotesIn1sWindow: maxIn1s,
            pitchMin: pitchMin, pitchMax: pitchMax,
            pitchRangeWidth: pitchSpan,
            notesBelowExpected: below,
            notesAboveExpected: above,
            maxSimultaneous: maxSimul,
            samePitchOverlapCount: samePitchOverlaps,
            machineGunRepeats: machineGun,
            shorterThan80ms: lt80, shorterThan120ms: lt120, shorterThan150ms: lt150,
            longerThan8s: gt8, longerThan15s: gt15,
            isolatedNoteCount: isolatedCount,
            denseClusterCount: denseClusterCount,
            ghostNoteFraction: ghostFrac,
            sustainPlausibility: sustainPlausibility,
            timingJitterMs: jitter,
            chordPlausibility: chord
        )

        return MidiDiagnosis(
            stats: stats,
            issues: issues,
            qualityScore: quality.score,
            qualityGrade: quality.grade,
            problems: quality.problems
        )
    }

    // MARK: - Helpers

    static func countSamePitchOverlaps(_ notes: [MIDINote]) -> Int {
        let byPitch = Dictionary(grouping: notes, by: \.pitch)
        var c = 0
        for (_, group) in byPitch {
            let sorted = group.sorted { $0.onset < $1.onset }
            for i in 1 ..< sorted.count {
                if sorted[i].onset < sorted[i-1].onset + sorted[i-1].duration - 1e-6 { c += 1 }
            }
        }
        return c
    }

    static func countIsolatedNotes(_ notes: [MIDINote], window: Double = 0.5) -> Int {
        let sorted = notes.sorted { $0.onset < $1.onset }
        var c = 0
        for (i, n) in sorted.enumerated() {
            let prevGap = i > 0 ? n.onset - sorted[i-1].onset : .greatestFiniteMagnitude
            let nextGap = i < sorted.count - 1 ? sorted[i+1].onset - n.onset : .greatestFiniteMagnitude
            if prevGap > window && nextGap > window && n.duration < 0.20 { c += 1 }
        }
        return c
    }

    static func countDenseClusters(_ notes: [MIDINote], window: Double = 0.05, minSize: Int = 8) -> Int {
        let sorted = notes.sorted { $0.onset < $1.onset }
        var i = 0
        var count = 0
        while i < sorted.count {
            var j = i
            while j < sorted.count && sorted[j].onset - sorted[i].onset <= window { j += 1 }
            if j - i >= minSize { count += 1; i = j } else { i += 1 }
        }
        return count
    }

    static func maxNotesIn1sWindow(_ notes: [MIDINote]) -> Int {
        let sorted = notes.sorted { $0.onset < $1.onset }
        var maxC = 0
        var l = 0
        for r in sorted.indices {
            while l < r && sorted[r].onset - sorted[l].onset > 1.0 { l += 1 }
            maxC = max(maxC, r - l + 1)
        }
        return maxC
    }

    static func computeGhostFraction(notes: [MIDINote]) -> Double {
        guard !notes.isEmpty else { return 0 }
        let ghostThreshold = 24
        let lowVel = notes.filter { $0.velocity < ghostThreshold }.count
        let veryShort = notes.filter { $0.duration < 0.080 }.count
        return min(1.0, Double(max(lowVel, veryShort)) / Double(notes.count))
    }

    static func computeSustainPlausibility(_ notes: [MIDINote]) -> Double {
        guard !notes.isEmpty else { return 0 }
        let sustained = notes.filter { $0.duration > 0.5 && $0.duration <= 8.0 }.count
        let absurd = notes.filter { $0.duration > 15.0 }.count
        if absurd > 0 { return 0 }
        return min(1.0, Double(sustained) / Double(notes.count) * 3.0)
    }

    static func computeTimingJitterMs(_ notes: [MIDINote]) -> Double {
        let sorted = notes.sorted { $0.onset < $1.onset }
        guard sorted.count >= 4 else { return 0 }
        var iois: [Double] = []
        for i in 1 ..< sorted.count {
            let d = sorted[i].onset - sorted[i-1].onset
            if d > 0 && d < 1.5 { iois.append(d) }
        }
        guard !iois.isEmpty else { return 0 }
        let median = iois.sorted()[iois.count / 2]
        let deviations = iois.map { abs($0 - median) }
        let medianDev = deviations.sorted()[deviations.count / 2]
        return medianDev * 1000.0
    }

    static func computeChordPlausibility(_ notes: [MIDINote]) -> Double {
        // Group notes by 30ms onset bucket; chord size 2..6 = plausible.
        let bucket = 0.030
        let byBucket = Dictionary(grouping: notes) { Int(($0.onset / bucket).rounded()) }
        let polyphonic = byBucket.values.filter { $0.count >= 2 }
        guard !polyphonic.isEmpty else { return 1.0 }
        let plausible = polyphonic.filter { (2...6).contains($0.count) }.count
        return Double(plausible) / Double(polyphonic.count)
    }

    static func countNeighborSamePitch(_ notes: [MIDINote], gap: Double) -> Int {
        let byPitch = Dictionary(grouping: notes, by: \.pitch)
        var c = 0
        for (_, group) in byPitch {
            let sorted = group.sorted { $0.onset < $1.onset }
            for i in 1 ..< sorted.count {
                if sorted[i].onset - (sorted[i-1].onset + sorted[i-1].duration) < gap { c += 1 }
            }
        }
        return c
    }
}
