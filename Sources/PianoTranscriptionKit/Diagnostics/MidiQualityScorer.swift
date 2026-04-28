import Foundation

/// Quality assessment of a candidate transcription. Pure function of the
/// note list + the source audio duration. Used by the quality-first
/// refinement runner to decide whether to retry, and surfaced in the
/// Data Flow inspector so users can see why a run was rejected.
public struct MidiQualityScore: Equatable, Sendable, Codable {

    public enum Grade: String, Equatable, Sendable, Codable {
        /// score >= 0.85 — accept without refinement.
        case good
        /// 0.65 ≤ score < 0.85 — usable but worth a refinement attempt.
        case fair
        /// 0.40 ≤ score < 0.65 — needs refinement; show "low confidence".
        case poor
        /// score < 0.40 — last-resort output; warn the user.
        case bad
    }

    /// 0.0 … 1.0 — higher is better.
    public let score: Double
    public let grade: Grade
    /// Human-readable problems detected. Empty when score is high.
    public let problems: [String]
    /// Per-signal contributions for transparency.
    public let signals: [String: Double]

    public init(score: Double, grade: Grade, problems: [String], signals: [String: Double]) {
        self.score = score
        self.grade = grade
        self.problems = problems
        self.signals = signals
    }
}

/// Scores a candidate transcription. Negative signals subtract from a
/// starting score of 1.0; positive signals can claw back a small amount.
/// Designed to produce a *relative* ranking between candidates first,
/// absolute correctness second — small score deltas are meaningful, but
/// the absolute thresholds (0.85 / 0.65 / 0.40) are calibrated against
/// hand-labeled good / fair / bad examples.
public enum MidiQualityScorer {

    public struct Profile: Equatable, Sendable {
        /// Plausible piano polyphony — anything past this is suspicious.
        public var maxSimultaneousNotes: Int
        /// Notes per second considered "dense" for this kind of input.
        public var densityNotesPerSecondCap: Double
        /// Plausible pitch range. Anything outside is a strong negative.
        public var pitchLowExpected: Int
        public var pitchHighExpected: Int
        /// Pitch range width above which we penalize — covers the "all over
        /// the keyboard" failure mode.
        public var maxPlausiblePitchSpan: Int
        /// Notes shorter than this are "very short"; many of them is bad.
        public var veryShortDurationSeconds: Double
        /// Notes longer than this are "very long"; many of them is bad.
        public var veryLongDurationSeconds: Double
        /// Same-pitch repeats faster than this rate are "machine-gun".
        public var machineGunMinIntervalSeconds: Double

        public static let cleanSoloPiano = Profile(
            maxSimultaneousNotes: 12,
            densityNotesPerSecondCap: 18,
            pitchLowExpected: 28,
            pitchHighExpected: 96,
            maxPlausiblePitchSpan: 64,
            veryShortDurationSeconds: 0.06,
            veryLongDurationSeconds: 9.0,
            machineGunMinIntervalSeconds: 0.04
        )

        public static let noisySoloPiano = Profile(
            maxSimultaneousNotes: 10,
            densityNotesPerSecondCap: 14,
            pitchLowExpected: 36,
            pitchHighExpected: 96,
            maxPlausiblePitchSpan: 60,
            veryShortDurationSeconds: 0.08,
            veryLongDurationSeconds: 7.0,
            machineGunMinIntervalSeconds: 0.05
        )

        public static let mixedInstruments = Profile(
            maxSimultaneousNotes: 8,
            densityNotesPerSecondCap: 12,
            pitchLowExpected: 40,
            pitchHighExpected: 92,
            maxPlausiblePitchSpan: 52,
            veryShortDurationSeconds: 0.08,
            veryLongDurationSeconds: 5.0,
            machineGunMinIntervalSeconds: 0.05
        )
    }

    public static func score(
        notes: [MIDINote],
        audioDurationSeconds: Double?,
        profile: Profile
    ) -> MidiQualityScore {
        guard !notes.isEmpty else {
            return MidiQualityScore(
                score: 0.0,
                grade: .bad,
                problems: ["No notes produced — the model emitted an empty transcription."],
                signals: ["empty": -1.0]
            )
        }

        var problems: [String] = []
        var signals: [String: Double] = [:]
        var s = 1.0

        let runEnd = notes.map { $0.onset + $0.duration }.max() ?? 0
        let durationDenom = max(audioDurationSeconds ?? runEnd, 0.001)
        let count = notes.count

        // 1. Density: notes/sec relative to the profile cap.
        let nps = Double(count) / durationDenom
        if nps > profile.densityNotesPerSecondCap {
            let over = nps / profile.densityNotesPerSecondCap
            let penalty = min(0.25, 0.10 * (over - 1))
            s -= penalty
            signals["density"] = -penalty
            problems.append(String(format: "Excessive density: %.1f notes/sec (cap %.1f)", nps, profile.densityNotesPerSecondCap))
        } else if nps > profile.densityNotesPerSecondCap * 0.7 {
            // Mild penalty for "approaching cap" — keeps top scores honest.
            s -= 0.03
            signals["density.mild"] = -0.03
        } else {
            signals["density.ok"] = +0.02
            s += 0.02
        }

        // 2. Pitch range width.
        let pitches = notes.map(\.pitch)
        let pitchSpan = (pitches.max() ?? 0) - (pitches.min() ?? 0)
        if pitchSpan > profile.maxPlausiblePitchSpan {
            let penalty = min(0.20, 0.15 * Double(pitchSpan - profile.maxPlausiblePitchSpan) / 12.0)
            s -= penalty
            signals["pitchSpan"] = -penalty
            problems.append("Pitch range \(pitchSpan) semitones is wider than expected \(profile.maxPlausiblePitchSpan).")
        }

        // 3. Out-of-range notes.
        let outOfRange = notes.filter { $0.pitch < profile.pitchLowExpected || $0.pitch > profile.pitchHighExpected }.count
        if outOfRange > 0 {
            let frac = Double(outOfRange) / Double(count)
            let penalty = min(0.20, frac * 0.40)
            s -= penalty
            signals["outOfRange"] = -penalty
            if frac > 0.05 {
                problems.append(String(format: "%.0f%% of notes outside expected piano range (MIDI %d–%d).",
                                       frac * 100, profile.pitchLowExpected, profile.pitchHighExpected))
            }
        }

        // 4. Simultaneity (rolling overlap count).
        let maxSimul = maxSimultaneousNoteCount(notes)
        if maxSimul > profile.maxSimultaneousNotes {
            let penalty = min(0.20, 0.06 * Double(maxSimul - profile.maxSimultaneousNotes))
            s -= penalty
            signals["simultaneous"] = -penalty
            problems.append("Up to \(maxSimul) simultaneous notes — exceeds plausible polyphony of \(profile.maxSimultaneousNotes).")
        }

        // 5. Very short notes.
        let veryShort = notes.filter { $0.duration < profile.veryShortDurationSeconds }.count
        let veryShortFrac = Double(veryShort) / Double(count)
        if veryShortFrac > 0.20 {
            let penalty = min(0.15, (veryShortFrac - 0.20) * 0.50)
            s -= penalty
            signals["veryShort"] = -penalty
            problems.append(String(format: "%.0f%% of notes shorter than %.0fms.", veryShortFrac * 100,
                                   profile.veryShortDurationSeconds * 1000))
        }

        // 6. Very long notes.
        let veryLong = notes.filter { $0.duration > profile.veryLongDurationSeconds }.count
        if veryLong > 0 {
            let frac = Double(veryLong) / Double(count)
            let penalty = min(0.20, 0.10 + frac * 1.0)
            s -= penalty
            signals["veryLong"] = -penalty
            problems.append("\(veryLong) note(s) longer than \(profile.veryLongDurationSeconds)s — likely stuck-note pipeline bugs.")
        }

        // 7. Machine-gun same-pitch repeats.
        let mg = machineGunCount(notes, minInterval: profile.machineGunMinIntervalSeconds)
        if mg > 0 {
            let penalty = min(0.10, 0.005 * Double(mg))
            s -= penalty
            signals["machineGun"] = -penalty
            if mg > 5 {
                problems.append("\(mg) same-pitch onsets spaced under \(Int(profile.machineGunMinIntervalSeconds * 1000))ms apart.")
            }
        }

        // 8. Audio-duration mismatch — model output ignores the source length.
        if let audio = audioDurationSeconds, audio > 0 {
            let drift = abs(runEnd - audio)
            if drift > 1.0 {
                let penalty = min(0.20, drift / audio * 0.50)
                s -= penalty
                signals["audioDriftSec"] = -penalty
                problems.append(String(format: "MIDI ends at %.2fs, audio is %.2fs (Δ %.2fs).", runEnd, audio, drift))
            }
        }

        // 9. Plausible polyphony bonus (positive signal).
        if maxSimul >= 2 && maxSimul <= profile.maxSimultaneousNotes {
            s += 0.03
            signals["polyphony.ok"] = +0.03
        }
        // 10. Sustain-preservation bonus — at least one credible long note
        //     within the legitimate sustain window.
        let credibleSustained = notes.filter {
            $0.duration > 1.0 && $0.duration <= profile.veryLongDurationSeconds
        }.count
        if credibleSustained > 0 {
            s += 0.03
            signals["sustain.ok"] = +0.03
        }

        // Clamp.
        s = max(0.0, min(1.0, s))
        let grade: MidiQualityScore.Grade =
            s >= 0.85 ? .good :
            s >= 0.65 ? .fair :
            s >= 0.40 ? .poor : .bad

        return MidiQualityScore(score: s, grade: grade, problems: problems, signals: signals)
    }

    /// Maximum number of notes overlapping at any instant. O(n log n).
    static func maxSimultaneousNoteCount(_ notes: [MIDINote]) -> Int {
        var events: [(t: Double, delta: Int)] = []
        events.reserveCapacity(notes.count * 2)
        for n in notes {
            events.append((n.onset, +1))
            events.append((n.onset + n.duration, -1))
        }
        events.sort { a, b in
            if a.t != b.t { return a.t < b.t }
            return a.delta < b.delta // process offs before ons at same instant
        }
        var current = 0
        var peak = 0
        for e in events {
            current += e.delta
            if current > peak { peak = current }
        }
        return peak
    }

    /// Counts same-pitch onset pairs separated by less than `minInterval`.
    static func machineGunCount(_ notes: [MIDINote], minInterval: Double) -> Int {
        let byPitch = Dictionary(grouping: notes, by: \.pitch)
        var hits = 0
        for (_, group) in byPitch {
            let onsets = group.map(\.onset).sorted()
            for k in 1 ..< onsets.count {
                if onsets[k] - onsets[k-1] < minInterval { hits += 1 }
            }
        }
        return hits
    }
}
