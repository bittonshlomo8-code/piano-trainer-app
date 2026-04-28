import Foundation

/// Per-operation tally tracked across all repair passes. Surfaced in run
/// metadata so the inspector / Data Flow can show exactly what the clinic
/// did.
public struct MidiRepairLog: Equatable, Sendable, Codable {
    public var pitchRangeGated: Int = 0
    public var shortNotesRemoved: Int = 0
    public var longNotesClamped: Int = 0
    public var samePitchFragmentsMerged: Int = 0
    public var samePitchOverlapsTrimmed: Int = 0
    public var notesPerSecondCapped: Int = 0
    public var simultaneousCapped: Int = 0
    public var isolatedGhostsRemoved: Int = 0
    public var timingRepaired: Int = 0
    public var chordReductions: Int = 0
    public var sustainExtensions: Int = 0
    public var melodyLineCollapses: Int = 0
    public var qualityGateDropped: Int = 0

    public var totalChanges: Int {
        pitchRangeGated + shortNotesRemoved + longNotesClamped
            + samePitchFragmentsMerged + samePitchOverlapsTrimmed
            + notesPerSecondCapped + simultaneousCapped
            + isolatedGhostsRemoved + timingRepaired
            + chordReductions + sustainExtensions
            + melodyLineCollapses + qualityGateDropped
    }
}

/// Input bundle handed to the clinic.
public struct MidiClinicInput: Sendable {
    public let rawNotes: [MIDINote]
    public let cleanedNotes: [MIDINote]   // already-cleaned notes; the clinic operates on these
    public let audioDurationSeconds: Double?
    public let pipelineKind: PipelineKind
    public let backendName: String
    public let isolatedStemPath: String?
    public let confidenceVelocityHint: Int? // optional confidence proxy

    public init(
        rawNotes: [MIDINote],
        cleanedNotes: [MIDINote],
        audioDurationSeconds: Double?,
        pipelineKind: PipelineKind,
        backendName: String,
        isolatedStemPath: String? = nil,
        confidenceVelocityHint: Int? = nil
    ) {
        self.rawNotes = rawNotes
        self.cleanedNotes = cleanedNotes
        self.audioDurationSeconds = audioDurationSeconds
        self.pipelineKind = pipelineKind
        self.backendName = backendName
        self.isolatedStemPath = isolatedStemPath
        self.confidenceVelocityHint = confidenceVelocityHint
    }
}

/// Detailed report returned by the clinic; stamped onto the persisted
/// `TranscriptionRun.pipelineParameters` via `MidiClinicMetadata`.
public struct MidiClinicReport: Sendable {
    public let profile: MidiRepairProfile
    public let beforeDiagnosis: MidiDiagnosis
    public let afterDiagnosis: MidiDiagnosis
    public let beforeScore: Double
    public let afterScore: Double
    public let issuesDetected: [MidiDiagnosis.Issue]
    public let repairs: MidiRepairLog
    public let passesRun: Int
    public let lowConfidence: Bool
    public let lowConfidenceWarning: String?
    public let repairedNotes: [MIDINote]
}

/// Global MIDI clinic. Diagnoses → repairs → re-scores up to 3 passes,
/// then returns the repaired notes plus a structured report.
public final class MidiClinic: @unchecked Sendable {

    public let acceptanceScore: Double
    public let minScoreImprovement: Double
    public let maxRepairLossFraction: Double

    /// - acceptanceScore: stop early when score reaches this.
    /// - minScoreImprovement: stop when an additional pass moves the
    ///   score by less than this.
    /// - maxRepairLossFraction: refuse a repair pass if it would drop
    ///   more than this fraction of the surviving notes (we'd rather
    ///   keep a noisy run than emit a near-empty one).
    public init(
        acceptanceScore: Double = 0.85,
        minScoreImprovement: Double = 0.03,
        maxRepairLossFraction: Double = 0.40
    ) {
        self.acceptanceScore = acceptanceScore
        self.minScoreImprovement = minScoreImprovement
        self.maxRepairLossFraction = maxRepairLossFraction
    }

    public func process(
        input: MidiClinicInput,
        profile providedProfile: MidiRepairProfile? = nil
    ) -> MidiClinicReport {

        // Choose the profile. Default by pipeline kind, but escalate to
        // melody-only if the diagnosis says the input is monophonic.
        var notes = input.cleanedNotes.isEmpty ? input.rawNotes : input.cleanedNotes
        let baseProfile = providedProfile ?? MidiRepairProfile.default(for: input.pipelineKind)
        let context0 = baseProfile.diagnosisContext.with(audioDuration: input.audioDurationSeconds)
        let initialDiag = MidiDiagnoser.diagnose(notes: notes, context: context0)

        // Auto-promote to melody-only when the cleanSoloPiano default is
        // active AND the input is clearly monophonic with low polyphony,
        // few chord clusters, and tight tessitura.
        var profile = baseProfile
        if baseProfile.id == .cleanSoloPiano,
           initialDiag.stats.maxSimultaneous <= 1,
           initialDiag.stats.pitchRangeWidth <= 30,
           initialDiag.stats.maxNotesIn1sWindow <= 6 {
            profile = .melodyOnly
        }
        let context = profile.diagnosisContext.with(audioDuration: input.audioDurationSeconds)

        var beforeDiag = MidiDiagnoser.diagnose(notes: notes, context: context)
        let beforeDiagFrozen = beforeDiag
        let beforeScore = beforeDiag.qualityScore
        var lastScore = beforeScore
        var log = MidiRepairLog()

        var passes = 0
        var afterDiag = beforeDiag
        for _ in 0 ..< 3 {
            passes += 1
            let beforeCount = notes.count
            let (next, passLog) = applyRepairs(notes, profile: profile)
            // The loss-gate is a safety net — it should not fire when the
            // input was already catastrophic (everything is garbage) or when
            // the post-repair note set is reasonable on its own. Refuse only
            // when:
            //   • the pass deleted more than `maxRepairLossFraction` of notes,
            //   • the input wasn't catastrophic (lastScore >= 0.30 — below
            //     this we assume the input is mostly garbage and aggressive
            //     deletion is the right answer), AND
            //   • the prospective output isn't itself reasonable (< 0.65) AND
            //     hasn't improved meaningfully over the input.
            let lossFraction = beforeCount > 0
                ? Double(beforeCount - next.count) / Double(beforeCount)
                : 0
            let prospective = MidiDiagnoser.diagnose(notes: next, context: context)
            let prospectiveScore = prospective.qualityScore
            let inputWasCatastrophic = lastScore < 0.30
            let prospectiveIsReasonable = prospectiveScore >= 0.65
            let improvedMeaningfully = prospectiveScore > lastScore + minScoreImprovement
            if lossFraction > maxRepairLossFraction
               && !inputWasCatastrophic
               && !prospectiveIsReasonable
               && !improvedMeaningfully {
                TranscriptionRunLog.pipeline.info(
                    "clinic refused pass=\(passes, privacy: .public) lossFraction=\(String(format: "%.2f", lossFraction), privacy: .public) prospectiveScore=\(String(format: "%.3f", prospectiveScore), privacy: .public)"
                )
                break
            }
            mergeLog(into: &log, from: passLog)
            notes = next
            afterDiag = prospective
            let improvement = afterDiag.qualityScore - lastScore
            TranscriptionRunLog.pipeline.info(
                "clinic pass=\(passes, privacy: .public) score=\(String(format: "%.3f", afterDiag.qualityScore), privacy: .public) Δ=\(String(format: "%+.3f", improvement), privacy: .public) notes=\(notes.count) totalRepairs=\(log.totalChanges)"
            )
            if afterDiag.qualityScore >= acceptanceScore { break }
            if improvement < minScoreImprovement { break }
            lastScore = afterDiag.qualityScore
        }

        // Final invariants gate.
        let (gated, gatedDropped) = MidiRepairEngine.qualityGate(
            notes,
            pitchLow: profile.pitchLow, pitchHigh: profile.pitchHigh,
            minDuration: profile.minNoteDuration,
            maxDuration: profile.maxNoteDuration
        )
        log.qualityGateDropped += gatedDropped
        if gated.count != notes.count {
            notes = gated
            afterDiag = MidiDiagnoser.diagnose(notes: notes, context: context)
        }

        let lowConfidence = afterDiag.qualityScore < 0.65
        let warn: String? = {
            if afterDiag.qualityScore < 0.40 {
                return "Clinic could not raise the score above 0.40. Output likely needs manual correction."
            }
            if afterDiag.qualityScore < 0.65 {
                return "Clinic improved the run but final quality is fair, not good. Consider re-recording cleaner audio or switching pipeline."
            }
            return nil
        }()

        // Combine the (initial-profile) issues with the (chosen-profile)
        // issues so the user sees both — useful when auto-promotion to
        // melody-only happens.
        let combinedIssues = Array(Set(beforeDiagFrozen.issues + beforeDiag.issues))

        return MidiClinicReport(
            profile: profile,
            beforeDiagnosis: beforeDiag,
            afterDiagnosis: afterDiag,
            beforeScore: beforeScore,
            afterScore: afterDiag.qualityScore,
            issuesDetected: combinedIssues,
            repairs: log,
            passesRun: passes,
            lowConfidence: lowConfidence,
            lowConfidenceWarning: warn,
            repairedNotes: notes
        )
    }

    // MARK: - Per-pass repair sequence

    private func applyRepairs(_ input: [MIDINote], profile: MidiRepairProfile) -> ([MIDINote], MidiRepairLog) {
        var log = MidiRepairLog()
        var notes = input

        // 1. Pitch range gate.
        let (g1, c1) = MidiRepairEngine.pitchRangeGate(notes, low: profile.pitchLow, high: profile.pitchHigh)
        log.pitchRangeGated += c1; notes = g1

        // 2. Merge same-pitch fragments FIRST. This must run before
        //    `removeShortNotes` so machine-gun fragments (e.g. 12 same-pitch
        //    notes hammered every 30ms with 20ms duration) coalesce into a
        //    sustained note rather than getting deleted entirely.
        let (g2, c2) = MidiRepairEngine.mergeSamePitchFragments(notes, maxGap: profile.mergeFragmentMaxGap)
        log.samePitchFragmentsMerged += c2; notes = g2

        // 3. Drop very-short notes per profile.
        let (g3, c3) = MidiRepairEngine.removeShortNotes(notes, minDuration: profile.minNoteDuration)
        log.shortNotesRemoved += c3; notes = g3

        // 4. Clamp absurdly long notes.
        let (g4, c4) = MidiRepairEngine.removeUnsupportedLongNotes(notes, maxDuration: profile.maxNoteDuration, clampDuration: profile.maxNoteDuration)
        log.longNotesClamped += c4; notes = g4

        // 5. Trim same-pitch overlaps.
        let (g5, c5) = MidiRepairEngine.trimSamePitchOverlaps(notes)
        log.samePitchOverlapsTrimmed += c5; notes = g5

        // 6. Remove isolated ghost notes.
        let (g6, c6) = MidiRepairEngine.removeIsolatedGhostNotes(
            notes,
            window: profile.isolatedNeighborWindow,
            maxGhostDuration: profile.isolatedNoteMinDuration,
            maxGhostVelocity: profile.ghostVelocity
        )
        log.isolatedGhostsRemoved += c6; notes = g6

        // 7. Preserve chord clusters (cap chord size).
        let (g7, c7) = MidiRepairEngine.preserveChordClusters(notes, window: profile.onsetClusterWindow, maxChord: profile.maxChord)
        log.chordReductions += c7; notes = g7

        // 8. Cap simultaneity.
        let (g8, c8) = MidiRepairEngine.capSimultaneousNotes(notes, maxSimultaneous: profile.maxSimultaneous)
        log.simultaneousCapped += c8; notes = g8

        // 9. Cap notes per second.
        let (g9, c9) = MidiRepairEngine.capNotesPerSecond(notes, maxPerSecond: profile.maxNotesPerSecond)
        log.notesPerSecondCapped += c9; notes = g9

        // 10. Optional sustain repair.
        if profile.preserveSustain {
            let (g10, c10) = MidiRepairEngine.repairSustainDurations(
                notes,
                maxExtensionSeconds: min(profile.maxNoteDuration, 4.0),
                minOriginalDuration: 0.20
            )
            log.sustainExtensions += c10; notes = g10
        }

        // 11. Optional melody-line extraction.
        if profile.extractMelodyLine {
            let (g11, c11) = MidiRepairEngine.melodyLineExtraction(notes, onsetWindow: profile.onsetClusterWindow)
            log.melodyLineCollapses += c11; notes = g11
        }

        // 12. Light timing-jitter smoothing if enabled.
        if profile.timingJitterMs > 0 {
            let (g12, c12) = MidiRepairEngine.smoothTimingJitter(notes, maxJitterMs: profile.timingJitterMs)
            log.timingRepaired += c12; notes = g12
        }

        return (notes, log)
    }

    private func mergeLog(into accum: inout MidiRepairLog, from rhs: MidiRepairLog) {
        accum.pitchRangeGated += rhs.pitchRangeGated
        accum.shortNotesRemoved += rhs.shortNotesRemoved
        accum.longNotesClamped += rhs.longNotesClamped
        accum.samePitchFragmentsMerged += rhs.samePitchFragmentsMerged
        accum.samePitchOverlapsTrimmed += rhs.samePitchOverlapsTrimmed
        accum.notesPerSecondCapped += rhs.notesPerSecondCapped
        accum.simultaneousCapped += rhs.simultaneousCapped
        accum.isolatedGhostsRemoved += rhs.isolatedGhostsRemoved
        accum.timingRepaired += rhs.timingRepaired
        accum.chordReductions += rhs.chordReductions
        accum.sustainExtensions += rhs.sustainExtensions
        accum.melodyLineCollapses += rhs.melodyLineCollapses
        accum.qualityGateDropped += rhs.qualityGateDropped
    }
}

/// Pipeline-side metadata stamped onto the run so the inspector's Data
/// Flow section can show the clinic's diagnosis without taking a typed
/// dependency on `MidiClinicReport`.
public enum MidiClinicMetadata {
    public static func parameters(for report: MidiClinicReport) -> [String: String] {
        var p: [String: String] = [
            "clinic.enabled": "true",
            "clinic.profile": report.profile.id.rawValue,
            "clinic.profileName": report.profile.name,
            "clinic.beforeScore": String(format: "%.4f", report.beforeScore),
            "clinic.afterScore": String(format: "%.4f", report.afterScore),
            "clinic.beforeGrade": report.beforeDiagnosis.qualityGrade.rawValue,
            "clinic.afterGrade": report.afterDiagnosis.qualityGrade.rawValue,
            "clinic.passesRun": String(report.passesRun),
            "clinic.notesBefore": String(report.beforeDiagnosis.stats.totalNotes),
            "clinic.notesAfter": String(report.afterDiagnosis.stats.totalNotes),
            "clinic.repairs.total": String(report.repairs.totalChanges),
            "clinic.repairs.timing": String(report.repairs.timingRepaired),
            "clinic.repairs.duration": String(
                report.repairs.shortNotesRemoved
                + report.repairs.longNotesClamped
                + report.repairs.sustainExtensions
            ),
            "clinic.repairs.ghostsRemoved": String(report.repairs.isolatedGhostsRemoved),
            "clinic.repairs.simultaneousCapped": String(report.repairs.simultaneousCapped),
            "clinic.repairs.notesPerSecondCapped": String(report.repairs.notesPerSecondCapped),
            "clinic.repairs.fragmentsMerged": String(report.repairs.samePitchFragmentsMerged),
            "clinic.repairs.overlapsTrimmed": String(report.repairs.samePitchOverlapsTrimmed),
            "clinic.repairs.chordReductions": String(report.repairs.chordReductions),
            "clinic.repairs.melodyLineCollapses": String(report.repairs.melodyLineCollapses),
            "clinic.repairs.pitchRangeGated": String(report.repairs.pitchRangeGated),
            "clinic.repairs.qualityGateDropped": String(report.repairs.qualityGateDropped),
            "clinic.lowConfidence": report.lowConfidence ? "true" : "false",
        ]
        if !report.issuesDetected.isEmpty {
            p["clinic.issues"] = report.issuesDetected.map(\.rawValue).joined(separator: ",")
        }
        if let warn = report.lowConfidenceWarning {
            p["clinic.warning"] = warn
        }
        return p
    }
}
