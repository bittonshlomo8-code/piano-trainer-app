import Foundation

/// One transcription attempt — what backend produced it, what cleanup was
/// applied, what notes came out, and how the quality scorer rated it.
public struct TranscriptionCandidate: Sendable {
    public let label: String
    public let backendName: String
    public let cleanupProfile: String
    public let rawNotes: [MIDINote]
    public let cleanedNotes: [MIDINote]
    public let cleanupReport: TranscriptionCleanup.Report
    public let quality: MidiQualityScore
    public let durationSeconds: Double
    /// Free-form parameters from the backend / cleanup config; surfaced
    /// in run metadata for reproducibility.
    public let parameters: [String: String]
}

/// Outcome of the quality-first runner. Carries the chosen candidate and
/// the full list of attempts so the inspector can show what was tried,
/// and the persisted run can stamp the refinement story.
public struct TranscriptionOutcome: Sendable {
    public let chosen: TranscriptionCandidate
    public let candidates: [TranscriptionCandidate]
    /// `true` when refinement actually ran (i.e. score on attempt 1 was
    /// below the acceptance threshold).
    public let refinementTriggered: Bool
    /// Acceptance threshold used for this run.
    public let acceptanceThreshold: Double
    /// User-facing warning when the chosen candidate is still poor.
    public let lowConfidenceWarning: String?
}

/// One attempt the runner can execute. Closures so the runner can vary
/// backend + cleanup + parameters without binding to concrete types.
public struct TranscriptionAttempt: Sendable {
    public let label: String
    public let backendName: String
    public let cleanupProfile: String
    public let cleanupConfig: TranscriptionCleanup.Config
    public let parameters: [String: String]
    /// Async closure that returns the raw notes. Captures the actual
    /// backend invocation (e.g. ByteDance on a stem URL).
    public let produceRawNotes: @Sendable (PipelineProgressHandler?) async throws -> [MIDINote]

    public init(
        label: String,
        backendName: String,
        cleanupProfile: String,
        cleanupConfig: TranscriptionCleanup.Config,
        parameters: [String: String] = [:],
        produceRawNotes: @escaping @Sendable (PipelineProgressHandler?) async throws -> [MIDINote]
    ) {
        self.label = label
        self.backendName = backendName
        self.cleanupProfile = cleanupProfile
        self.cleanupConfig = cleanupConfig
        self.parameters = parameters
        self.produceRawNotes = produceRawNotes
    }
}

/// Runs a primary attempt, scores it, and runs additional candidates when
/// the score is below threshold. Returns the highest-scoring candidate.
///
/// Quality is preferred over speed: every refinement candidate gets the
/// full backend + cleanup pipeline. There is no early-exit short-circuit
/// inside refinement — once we trigger refinement we always score every
/// candidate so the user sees the complete story in Data Flow.
public final class QualityFirstTranscriptionRunner: @unchecked Sendable {

    public let scoringProfile: MidiQualityScorer.Profile
    public let acceptanceThreshold: Double
    public let audioDurationSeconds: Double?

    public init(
        scoringProfile: MidiQualityScorer.Profile,
        acceptanceThreshold: Double = 0.85,
        audioDurationSeconds: Double?
    ) {
        self.scoringProfile = scoringProfile
        self.acceptanceThreshold = max(0.0, min(1.0, acceptanceThreshold))
        self.audioDurationSeconds = audioDurationSeconds
    }

    public func run(
        primary: TranscriptionAttempt,
        refinements: [TranscriptionAttempt],
        progress: PipelineProgressHandler?
    ) async throws -> TranscriptionOutcome {
        var candidates: [TranscriptionCandidate] = []

        // Run primary first.
        let firstStart = Date()
        let firstCandidate = try await execute(attempt: primary, progress: progress)
        let firstElapsed = Date().timeIntervalSince(firstStart)
        TranscriptionRunLog.pipeline.info(
            "qfirst primary label=\(primary.label, privacy: .public) score=\(String(format: "%.3f", firstCandidate.quality.score), privacy: .public) grade=\(firstCandidate.quality.grade.rawValue, privacy: .public) elapsed=\(String(format: "%.1fs", firstElapsed), privacy: .public)"
        )
        candidates.append(firstCandidate)

        if firstCandidate.quality.score >= acceptanceThreshold {
            return TranscriptionOutcome(
                chosen: firstCandidate,
                candidates: candidates,
                refinementTriggered: false,
                acceptanceThreshold: acceptanceThreshold,
                lowConfidenceWarning: nil
            )
        }

        // Refinement triggered — run every alternative candidate.
        progress?(PipelineProgress(stage: .analyzing, fraction: 0.0,
                                   detail: "score \(String(format: "%.2f", firstCandidate.quality.score)) — refining"))
        for (idx, alt) in refinements.enumerated() {
            let attemptStart = Date()
            do {
                let candidate = try await execute(attempt: alt, progress: progress)
                let elapsed = Date().timeIntervalSince(attemptStart)
                TranscriptionRunLog.pipeline.info(
                    "qfirst refine[\(idx + 1, privacy: .public)] label=\(alt.label, privacy: .public) score=\(String(format: "%.3f", candidate.quality.score), privacy: .public) grade=\(candidate.quality.grade.rawValue, privacy: .public) elapsed=\(String(format: "%.1fs", elapsed), privacy: .public)"
                )
                candidates.append(candidate)
            } catch {
                // A failed refinement attempt isn't fatal — we still have
                // the primary. Log it and keep going.
                TranscriptionRunLog.pipeline.error(
                    "qfirst refine[\(idx + 1, privacy: .public)] label=\(alt.label, privacy: .public) FAILED: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // Pick the highest-scoring candidate. Tiebreak by note count — fewer
        // notes at equal score usually means cleaner output (less garbage).
        let chosen = candidates.max { a, b in
            if a.quality.score != b.quality.score { return a.quality.score < b.quality.score }
            return a.cleanedNotes.count > b.cleanedNotes.count
        } ?? firstCandidate

        let warn: String?
        if chosen.quality.score < 0.40 {
            warn = "Low-confidence transcription. Output likely needs manual correction."
        } else if chosen.quality.score < 0.65 {
            warn = "Refinement improved the result but quality is still mixed — consider re-recording cleaner audio."
        } else {
            warn = nil
        }

        return TranscriptionOutcome(
            chosen: chosen,
            candidates: candidates,
            refinementTriggered: true,
            acceptanceThreshold: acceptanceThreshold,
            lowConfidenceWarning: warn
        )
    }

    private func execute(
        attempt: TranscriptionAttempt,
        progress: PipelineProgressHandler?
    ) async throws -> TranscriptionCandidate {
        let started = Date()
        let raw = try await attempt.produceRawNotes(progress)
        var cfg = attempt.cleanupConfig
        cfg.audioDurationSeconds = audioDurationSeconds
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        let quality = MidiQualityScorer.score(
            notes: outcome.cleaned,
            audioDurationSeconds: audioDurationSeconds,
            profile: scoringProfile
        )
        return TranscriptionCandidate(
            label: attempt.label,
            backendName: attempt.backendName,
            cleanupProfile: attempt.cleanupProfile,
            rawNotes: raw,
            cleanedNotes: outcome.cleaned,
            cleanupReport: outcome.report,
            quality: quality,
            durationSeconds: Date().timeIntervalSince(started),
            parameters: attempt.parameters
        )
    }
}

/// Helpers for stamping refinement metadata onto a `TranscriptionRun`'s
/// `pipelineParameters` so the inspector can show the full story.
public enum TranscriptionRefinementMetadata {
    public static func parameters(for outcome: TranscriptionOutcome) -> [String: String] {
        var p: [String: String] = [
            "refinement.triggered": outcome.refinementTriggered ? "true" : "false",
            "refinement.acceptanceThreshold": String(format: "%.2f", outcome.acceptanceThreshold),
            "refinement.candidatesTried": String(outcome.candidates.count),
            "refinement.chosenLabel": outcome.chosen.label,
            "refinement.chosenBackend": outcome.chosen.backendName,
            "refinement.chosenCleanupProfile": outcome.chosen.cleanupProfile,
            "refinement.chosenScore": String(format: "%.4f", outcome.chosen.quality.score),
            "refinement.chosenGrade": outcome.chosen.quality.grade.rawValue,
        ]
        if let warn = outcome.lowConfidenceWarning {
            p["refinement.warning"] = warn
        }
        if !outcome.chosen.quality.problems.isEmpty {
            p["refinement.chosenProblems"] = outcome.chosen.quality.problems.joined(separator: " | ")
        }
        for (i, c) in outcome.candidates.enumerated() {
            p["refinement.candidate.\(i + 1).label"] = c.label
            p["refinement.candidate.\(i + 1).backend"] = c.backendName
            p["refinement.candidate.\(i + 1).cleanupProfile"] = c.cleanupProfile
            p["refinement.candidate.\(i + 1).score"] = String(format: "%.4f", c.quality.score)
            p["refinement.candidate.\(i + 1).grade"] = c.quality.grade.rawValue
            p["refinement.candidate.\(i + 1).noteCount"] = String(c.cleanedNotes.count)
            p["refinement.candidate.\(i + 1).durationSeconds"] = String(format: "%.2f", c.durationSeconds)
        }
        return p
    }
}
