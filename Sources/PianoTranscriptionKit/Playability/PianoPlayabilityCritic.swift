import Foundation

/// Aggregate report returned by `PianoPlayabilityCritic`. Pipelines stamp
/// the per-key parameters returned by `PlayabilityCriticMetadata` onto
/// the persisted run so the inspector's Data Flow can show every
/// repair the critic performed.
public struct PlayabilityReport: Sendable {
    public let beforeDiagnosis: PlayabilityDiagnosis
    public let afterDiagnosis: PlayabilityDiagnosis
    public let beforeQualityScore: Double
    public let afterQualityScore: Double
    public let repairs: PlayabilityRepairLog
    public let passesRun: Int
    /// `true` when the critic accepted at least one repair. `false` when
    /// the input was already playable, or when every prospective repair
    /// would have hurt musical quality enough that we kept the original.
    public let appliedRepairs: Bool
    public let repairedNotes: [MIDINote]
    /// Reason the critic stopped (early acceptance, no improvement, quality
    /// regression, etc.). Surfaced for transparency.
    public let stopReason: String
}

/// Top-level orchestrator. Runs hand assignment → diagnosis → (repair →
/// re-diagnose)* → returns the final note list plus a structured report.
///
/// Quality gate: a repair pass is only accepted when the playability score
/// improves AND the musical quality score from `MidiQualityScorer` does
/// not drop by more than `maxQualityDrop`. This guards against the critic
/// trimming ghost notes that, while making the part "playable", actually
/// erase the melody.
public final class PianoPlayabilityCritic: @unchecked Sendable {

    public struct Config: Sendable, Equatable {
        public var assignment: HandAssignmentEngine.Config
        public var diagnoser: PlayabilityDiagnoser.Config
        public var repair: PlayabilityRepairEngine.Config
        /// Maximum number of repair passes.
        public var maxPasses: Int
        /// Stop early when score reaches this.
        public var acceptanceScore: Double
        /// Stop when an additional pass moves the playability score by
        /// less than this.
        public var minScoreImprovement: Double
        /// Reject a repair pass that drops the musical quality score by
        /// more than this absolute amount.
        public var maxQualityDrop: Double
        /// Quality scorer profile used for the musical-quality gate.
        public var qualityProfile: MidiQualityScorer.Profile
        public init(
            assignment: HandAssignmentEngine.Config = .init(),
            diagnoser: PlayabilityDiagnoser.Config = .init(),
            repair: PlayabilityRepairEngine.Config = .init(),
            maxPasses: Int = 3,
            acceptanceScore: Double = 0.95,
            minScoreImprovement: Double = 0.02,
            maxQualityDrop: Double = 0.05,
            qualityProfile: MidiQualityScorer.Profile = .cleanSoloPiano
        ) {
            self.assignment = assignment
            self.diagnoser = diagnoser
            self.repair = repair
            self.maxPasses = maxPasses
            self.acceptanceScore = acceptanceScore
            self.minScoreImprovement = minScoreImprovement
            self.maxQualityDrop = maxQualityDrop
            self.qualityProfile = qualityProfile
        }
    }

    public let config: Config
    public init(config: Config = .init()) { self.config = config }

    public func process(
        _ notes: [MIDINote],
        audioDurationSeconds: Double?
    ) -> PlayabilityReport {
        let engine = HandAssignmentEngine(config: config.assignment)
        let initialAssignment = engine.assign(notes)
        let beforeDiag = PlayabilityDiagnoser.diagnose(initialAssignment, config: config.diagnoser)
        let beforeQuality = MidiQualityScorer.score(
            notes: notes,
            audioDurationSeconds: audioDurationSeconds,
            profile: config.qualityProfile
        ).score

        // Already playable → exit immediately, no repairs.
        if beforeDiag.isPlayable {
            return PlayabilityReport(
                beforeDiagnosis: beforeDiag,
                afterDiagnosis: beforeDiag,
                beforeQualityScore: beforeQuality,
                afterQualityScore: beforeQuality,
                repairs: PlayabilityRepairLog(),
                passesRun: 0,
                appliedRepairs: false,
                repairedNotes: notes,
                stopReason: "already-playable"
            )
        }

        var assignment = initialAssignment
        var diag = beforeDiag
        var totalLog = PlayabilityRepairLog()
        var passes = 0
        var stopReason = "max-passes"

        for _ in 0 ..< config.maxPasses {
            passes += 1
            let result = PlayabilityRepairEngine.repair(assignment, diagnosis: diag, config: config.repair)
            let candidateNotes = result.assignment.notes.map(\.note)
            let candidateQuality = MidiQualityScorer.score(
                notes: candidateNotes,
                audioDurationSeconds: audioDurationSeconds,
                profile: config.qualityProfile
            ).score
            let candidateDiag = PlayabilityDiagnoser.diagnose(result.assignment, config: config.diagnoser)

            // Quality gate: refuse if musical quality dropped too far OR
            // playability didn't improve at all. We compare against the
            // most-recent accepted state, not the original input.
            let qualityDrop = (passes == 1 ? beforeQuality : currentQuality(notes: assignment.notes.map(\.note),
                                                                            audioDurationSeconds: audioDurationSeconds,
                                                                            profile: config.qualityProfile))
                - candidateQuality
            let scoreImprovement = candidateDiag.score - diag.score
            if qualityDrop > config.maxQualityDrop {
                stopReason = "quality-regression"
                TranscriptionRunLog.pipeline.info(
                    "playability refused pass=\(passes, privacy: .public) qualityDrop=\(String(format: "%.3f", qualityDrop), privacy: .public) scoreΔ=\(String(format: "%+.3f", scoreImprovement), privacy: .public)"
                )
                break
            }
            if scoreImprovement < config.minScoreImprovement && candidateDiag.score < config.acceptanceScore {
                stopReason = "no-improvement"
                TranscriptionRunLog.pipeline.info(
                    "playability stop pass=\(passes, privacy: .public) reason=no-improvement scoreΔ=\(String(format: "%+.3f", scoreImprovement), privacy: .public)"
                )
                break
            }

            // Accept the pass.
            assignment = result.assignment
            diag = candidateDiag
            mergeLog(into: &totalLog, from: result.log)
            TranscriptionRunLog.pipeline.info(
                "playability pass=\(passes, privacy: .public) score=\(String(format: "%.3f", diag.score), privacy: .public) Δ=\(String(format: "%+.3f", scoreImprovement), privacy: .public) repairs=\(totalLog.totalChanges) notes=\(assignment.notes.count)"
            )

            if diag.score >= config.acceptanceScore {
                stopReason = "acceptance"
                break
            }
            if scoreImprovement < config.minScoreImprovement {
                stopReason = "diminishing-returns"
                break
            }
        }

        let finalNotes = assignment.notes.map(\.note)
        let afterQuality = MidiQualityScorer.score(
            notes: finalNotes,
            audioDurationSeconds: audioDurationSeconds,
            profile: config.qualityProfile
        ).score

        return PlayabilityReport(
            beforeDiagnosis: beforeDiag,
            afterDiagnosis: diag,
            beforeQualityScore: beforeQuality,
            afterQualityScore: afterQuality,
            repairs: totalLog,
            passesRun: passes,
            appliedRepairs: totalLog.totalChanges > 0,
            repairedNotes: finalNotes,
            stopReason: stopReason
        )
    }

    private func currentQuality(
        notes: [MIDINote],
        audioDurationSeconds: Double?,
        profile: MidiQualityScorer.Profile
    ) -> Double {
        MidiQualityScorer.score(notes: notes, audioDurationSeconds: audioDurationSeconds, profile: profile).score
    }

    private func mergeLog(into accum: inout PlayabilityRepairLog, from rhs: PlayabilityRepairLog) {
        accum.ghostsRemoved += rhs.ghostsRemoved
        accum.lowConfidenceDropped += rhs.lowConfidenceDropped
        accum.octaveDuplicatesCollapsed += rhs.octaveDuplicatesCollapsed
        accum.notesReassigned += rhs.notesReassigned
        accum.jumpsRelieved += rhs.jumpsRelieved
        accum.sustainConflictsResolved += rhs.sustainConflictsResolved
    }
}

/// Pipeline-side metadata stamped onto a run so Data Flow can show what
/// the critic did without taking a typed dependency on `PlayabilityReport`.
public enum PlayabilityCriticMetadata {

    public static func parameters(for report: PlayabilityReport) -> [String: String] {
        var p: [String: String] = [
            "playability.enabled": "true",
            "playability.appliedRepairs": report.appliedRepairs ? "true" : "false",
            "playability.passesRun": String(report.passesRun),
            "playability.stopReason": report.stopReason,
            "playability.beforeScore": String(format: "%.4f", report.beforeDiagnosis.score),
            "playability.afterScore": String(format: "%.4f", report.afterDiagnosis.score),
            "playability.beforeQualityScore": String(format: "%.4f", report.beforeQualityScore),
            "playability.afterQualityScore": String(format: "%.4f", report.afterQualityScore),
            "playability.splitPitch": String(report.afterDiagnosis.splitPitch),
            "playability.before.impossibleSpans": String(
                report.beforeDiagnosis.leftHand.impossibleSpanCount
                + report.beforeDiagnosis.rightHand.impossibleSpanCount
            ),
            "playability.after.impossibleSpans": String(
                report.afterDiagnosis.leftHand.impossibleSpanCount
                + report.afterDiagnosis.rightHand.impossibleSpanCount
            ),
            "playability.before.impossibleJumps": String(
                report.beforeDiagnosis.leftHand.impossibleJumpCount
                + report.beforeDiagnosis.rightHand.impossibleJumpCount
            ),
            "playability.after.impossibleJumps": String(
                report.afterDiagnosis.leftHand.impossibleJumpCount
                + report.afterDiagnosis.rightHand.impossibleJumpCount
            ),
            "playability.before.tooManySimultaneous": String(
                report.beforeDiagnosis.leftHand.tooManySimultaneousCount
                + report.beforeDiagnosis.rightHand.tooManySimultaneousCount
            ),
            "playability.after.tooManySimultaneous": String(
                report.afterDiagnosis.leftHand.tooManySimultaneousCount
                + report.afterDiagnosis.rightHand.tooManySimultaneousCount
            ),
            "playability.before.sustainConflicts": String(
                report.beforeDiagnosis.leftHand.sustainConflictCount
                + report.beforeDiagnosis.rightHand.sustainConflictCount
            ),
            "playability.after.sustainConflicts": String(
                report.afterDiagnosis.leftHand.sustainConflictCount
                + report.afterDiagnosis.rightHand.sustainConflictCount
            ),
            "playability.repairs.total": String(report.repairs.totalChanges),
            "playability.repairs.ghostsRemoved": String(report.repairs.ghostsRemoved),
            "playability.repairs.lowConfidenceDropped": String(report.repairs.lowConfidenceDropped),
            "playability.repairs.octaveDuplicatesCollapsed": String(report.repairs.octaveDuplicatesCollapsed),
            "playability.repairs.notesReassigned": String(report.repairs.notesReassigned),
            "playability.repairs.jumpsRelieved": String(report.repairs.jumpsRelieved),
            "playability.repairs.sustainConflictsResolved": String(report.repairs.sustainConflictsResolved),
            "playability.notesBefore": String(
                report.beforeDiagnosis.leftHand.noteCount + report.beforeDiagnosis.rightHand.noteCount
            ),
            "playability.notesAfter": String(
                report.afterDiagnosis.leftHand.noteCount + report.afterDiagnosis.rightHand.noteCount
            ),
            "playability.left.maxSpan": String(report.afterDiagnosis.leftHand.maxSpanSemitones),
            "playability.right.maxSpan": String(report.afterDiagnosis.rightHand.maxSpanSemitones),
            "playability.left.maxSimul": String(report.afterDiagnosis.leftHand.maxSimultaneous),
            "playability.right.maxSimul": String(report.afterDiagnosis.rightHand.maxSimultaneous),
        ]
        // Compact textual summary of the worst issues (top 5) so the
        // Data Flow row "Playability issues found" is human-readable.
        let topIssues = report.beforeDiagnosis.issues
            .sorted { $0.severity > $1.severity }
            .prefix(5)
            .map { "[\($0.kind.rawValue) \($0.hand.rawValue) @\(String(format: "%.2fs", $0.timestamp))]" }
        if !topIssues.isEmpty {
            p["playability.before.topIssues"] = topIssues.joined(separator: " ")
        }
        // Mirror key facts onto the dataflow.* namespace so Data Flow can
        // pull them with the same helper as the rest of the inspector.
        p["dataflow.playabilityBeforeScore"] = String(format: "%.2f", report.beforeDiagnosis.score)
        p["dataflow.playabilityAfterScore"] = String(format: "%.2f", report.afterDiagnosis.score)
        p["dataflow.playabilityImpossibleSpansBefore"] = String(
            report.beforeDiagnosis.leftHand.impossibleSpanCount
            + report.beforeDiagnosis.rightHand.impossibleSpanCount
        )
        p["dataflow.playabilityImpossibleJumpsBefore"] = String(
            report.beforeDiagnosis.leftHand.impossibleJumpCount
            + report.beforeDiagnosis.rightHand.impossibleJumpCount
        )
        p["dataflow.playabilityNotesRemoved"] = String(
            report.repairs.ghostsRemoved + report.repairs.lowConfidenceDropped
            + report.repairs.octaveDuplicatesCollapsed + report.repairs.jumpsRelieved
        )
        p["dataflow.playabilityNotesReassigned"] = String(report.repairs.notesReassigned)
        p["dataflow.playabilityHandSplit"] = String(report.afterDiagnosis.splitPitch)
        p["dataflow.playabilityStopReason"] = report.stopReason
        return p
    }
}
