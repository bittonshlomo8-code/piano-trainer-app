import Foundation

// MARK: - Pipeline error helpers

private func throwIfMissing(_ available: Bool, kind: PipelineKind, reason: String?) throws {
    if !available {
        let baseReason = reason ?? "\(kind.displayName) backend is not installed."
        let installHint = " Run `bash scripts/setup-transcription-deps.sh` from the project root."
        throw PipelineError.unavailable(reason: baseReason + (baseReason.contains("setup-transcription") ? "" : installHint))
    }
}

private func stampOutcome(
    on params: inout [String: String],
    outcome: TranscriptionOutcome
) {
    for (k, v) in TranscriptionRefinementMetadata.parameters(for: outcome) { params[k] = v }
}

/// Runs the global MIDI clinic on a pipeline's chosen candidate. Returns
/// (repairedNotes, clinicReport) — the caller persists `repairedNotes` on
/// the `TranscriptionRun` and stamps `MidiClinicMetadata.parameters(for:)`
/// onto its `pipelineParameters`. Every production pipeline goes through
/// this helper so audio → model → cleanup → clinic → MIDI is uniform.
private func applyClinic(
    chosen: TranscriptionCandidate,
    audioDurationSeconds: Double?,
    pipelineKind: PipelineKind,
    isolatedStemPath: String? = nil
) -> (notes: [MIDINote], report: MidiClinicReport) {
    let clinic = MidiClinic()
    let input = MidiClinicInput(
        rawNotes: chosen.rawNotes,
        cleanedNotes: chosen.cleanedNotes,
        audioDurationSeconds: audioDurationSeconds,
        pipelineKind: pipelineKind,
        backendName: chosen.backendName,
        isolatedStemPath: isolatedStemPath
    )
    let report = clinic.process(input: input)
    TranscriptionRunLog.pipeline.info(
        "clinic done pipeline=\(pipelineKind.rawValue, privacy: .public) profile=\(report.profile.id.rawValue, privacy: .public) before=\(String(format: "%.3f", report.beforeScore), privacy: .public) after=\(String(format: "%.3f", report.afterScore), privacy: .public) repairs=\(report.repairs.totalChanges) passes=\(report.passesRun)"
    )
    return (report.repairedNotes, report)
}

/// Runs the Piano Playability Critic on the post-clinic note set. The
/// critic is the last stage before MIDI export; its job is to ensure the
/// output is physically playable by human hands. Pipeline order is:
///   audio → transcription → MIDI Clinic → Playability Critic → final MIDI
///
/// Uses `MidiQualityScorer.cleanSoloPiano` as the musical-quality guard
/// for solo-piano kinds, and the noisier mixed profile for the mixed
/// pipeline so a clinic that already produced a slightly-noisy run
/// doesn't get its repairs rejected by an inappropriate quality bar.
private func applyPlayabilityCritic(
    notes: [MIDINote],
    audioDurationSeconds: Double?,
    pipelineKind: PipelineKind
) -> (notes: [MIDINote], report: PlayabilityReport) {
    let qualityProfile: MidiQualityScorer.Profile = {
        switch pipelineKind {
        case .cleanSoloPiano:           return .cleanSoloPiano
        case .noisySoloPiano:           return .noisySoloPiano
        case .mixedInstrumentsAdvanced: return .mixedInstruments
        default:                        return .cleanSoloPiano
        }
    }()
    let critic = PianoPlayabilityCritic(
        config: .init(qualityProfile: qualityProfile)
    )
    let report = critic.process(notes, audioDurationSeconds: audioDurationSeconds)
    TranscriptionRunLog.pipeline.info(
        "playability done pipeline=\(pipelineKind.rawValue, privacy: .public) before=\(String(format: "%.3f", report.beforeDiagnosis.score), privacy: .public) after=\(String(format: "%.3f", report.afterDiagnosis.score), privacy: .public) qBefore=\(String(format: "%.3f", report.beforeQualityScore), privacy: .public) qAfter=\(String(format: "%.3f", report.afterQualityScore), privacy: .public) repairs=\(report.repairs.totalChanges) passes=\(report.passesRun) reason=\(report.stopReason, privacy: .public)"
    )
    return (report.repairedNotes, report)
}

// MARK: - Clean Solo Piano

/// Quality-first pipeline for clean / studio piano recordings.
///
/// Primary: ByteDance + sustain-preserving cleanup. If the score is below
/// 0.85 we additionally try Basic Pitch (fallback model still wired
/// directly here, not silently — every candidate is recorded), Basic Pitch
/// with stricter cleanup, and a melody-only profile in case the input is
/// monophonic. The highest-scoring candidate wins.
public final class CleanSoloPianoPipeline: TranscriptionPipeline, @unchecked Sendable {
    public let kind: PipelineKind = .cleanSoloPiano
    public let version: String = "2.0.0"

    private let byteDance: PianoSpecializedTranscriber
    private let basicPitch: PianoSpecializedTranscriber
    private let acceptanceThreshold: Double

    public var modelName: String { byteDance.modelName }
    public var modelVersion: String? { byteDance.modelVersion }
    public var parameters: [String: String] {
        var p = byteDance.parameters
        p["pipeline.architecture"] = "ByteDance primary; quality-first refinement (Basic Pitch + stricter cleanup) when score < \(acceptanceThreshold)"
        return p
    }
    public var usesSourceSeparation: Bool { false }

    public init(
        transcriber: PianoSpecializedTranscriber = ByteDancePianoTranscriber(),
        basicPitch: PianoSpecializedTranscriber = BasicPitchTranscriber(),
        acceptanceThreshold: Double = 0.85,
        // Legacy alias kept for back-compat with callers that pass
        // `cleanupConfig:` — the new pipeline drives cleanup via named
        // profiles in the runner, so this argument is intentionally unused.
        cleanupConfig: TranscriptionCleanup.Config = .soloPiano
    ) {
        self.byteDance = transcriber
        self.basicPitch = basicPitch
        self.acceptanceThreshold = acceptanceThreshold
        _ = cleanupConfig
    }

    public func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun {
        // ByteDance is required as the primary backend for clean solo piano.
        try throwIfMissing(byteDance.isAvailable, kind: kind, reason: byteDance.unavailableReason)

        progress?(PipelineProgress(stage: .loading, fraction: 0.0))
        let audioDuration = AudioDurationProbe.durationSeconds(of: audioURL)

        let runner = QualityFirstTranscriptionRunner(
            scoringProfile: .cleanSoloPiano,
            acceptanceThreshold: acceptanceThreshold,
            audioDurationSeconds: audioDuration
        )

        let primary = TranscriptionAttempt(
            label: "ByteDance + sustain-preserving cleanup",
            backendName: byteDance.modelName,
            cleanupProfile: "soloPiano",
            cleanupConfig: .soloPiano,
            parameters: ["primary": "true"]
        ) { p in
            try await self.byteDance.transcribePiano(audioURL: audioURL, progress: p).notes
        }

        var refinements: [TranscriptionAttempt] = [
            TranscriptionAttempt(
                label: "ByteDance + strict ghost-note cleanup",
                backendName: byteDance.modelName,
                cleanupProfile: "noisyPiano",
                cleanupConfig: .noisyPiano
            ) { p in
                try await self.byteDance.transcribePiano(audioURL: audioURL, progress: p).notes
            },
            TranscriptionAttempt(
                label: "ByteDance + melody-only profile",
                backendName: byteDance.modelName,
                cleanupProfile: "melodyOnly",
                cleanupConfig: .melodyOnly
            ) { p in
                try await self.byteDance.transcribePiano(audioURL: audioURL, progress: p).notes
            },
        ]
        if basicPitch.isAvailable {
            refinements.append(TranscriptionAttempt(
                label: "Basic Pitch + conservative cleanup",
                backendName: basicPitch.modelName,
                cleanupProfile: "soloPiano",
                cleanupConfig: .soloPiano
            ) { p in
                try await self.basicPitch.transcribePiano(audioURL: audioURL, progress: p).notes
            })
        }

        let outcome = try await runner.run(primary: primary, refinements: refinements, progress: progress)
        progress?(PipelineProgress(stage: .finalizing, fraction: 0.92, detail: "MIDI clinic"))

        // Global MIDI clinic — diagnose + repair the chosen candidate.
        let clinic = applyClinic(
            chosen: outcome.chosen,
            audioDurationSeconds: audioDuration,
            pipelineKind: kind
        )

        // Piano Playability Critic — final stage: ensure the part is
        // physically playable. Quality-gated, so it never erases melody.
        progress?(PipelineProgress(stage: .finalizing, fraction: 0.96, detail: "playability check"))
        let playability = applyPlayabilityCritic(
            notes: clinic.notes,
            audioDurationSeconds: audioDuration,
            pipelineKind: kind
        )

        progress?(PipelineProgress(stage: .finalizing, fraction: 1.0,
                                   detail: "after-clinic \(String(format: "%.2f", clinic.report.afterScore)); playability \(String(format: "%.2f", playability.report.afterDiagnosis.score))"))

        var params = parameters
        params["model.fallback"] = "false"
        params["backend.kind"] = "dedicated"
        params["backend.ran"] = outcome.chosen.backendName
        for (k, v) in outcome.chosen.parameters { params["chosen.\(k)"] = v }
        stampOutcome(on: &params, outcome: outcome)
        for (k, v) in MidiClinicMetadata.parameters(for: clinic.report) { params[k] = v }
        for (k, v) in PlayabilityCriticMetadata.parameters(for: playability.report) { params[k] = v }

        return TranscriptionRun.makeWithMandatoryCleanup(
            rawModelNotes: playability.notes,
            audioDurationSeconds: audioDuration,
            pipelineVersion: version,
            modelName: outcome.chosen.backendName,
            pipelineID: kind.rawValue,
            pipelineName: kind.displayName,
            modelVersion: byteDance.modelVersion,
            pipelineParameters: params,
            usedSourceSeparation: false,
            inputAudioPath: audioURL.path
        )
    }
}

// MARK: - Noisy Solo Piano

/// Quality-first pipeline for solo piano recorded with phone-mic / room
/// noise / hum. Primary is Basic Pitch + noisy-piano cleanup. Refinement
/// alternatives include stricter cleanup, ByteDance on the same audio
/// (when available — a noisy clean piano can still come out usable from
/// the high-resolution model), and a melody-only profile.
public final class NoisySoloPianoPipeline: TranscriptionPipeline, @unchecked Sendable {
    public let kind: PipelineKind = .noisySoloPiano
    public let version: String = "2.0.0"

    private let basicPitch: PianoSpecializedTranscriber
    private let byteDance: PianoSpecializedTranscriber
    private let acceptanceThreshold: Double

    public var modelName: String { basicPitch.modelName }
    public var modelVersion: String? { basicPitch.modelVersion }
    public var parameters: [String: String] {
        var p = basicPitch.parameters
        p["pipeline.architecture"] = "Basic Pitch primary; quality-first refinement when score < \(acceptanceThreshold)"
        return p
    }
    public var usesSourceSeparation: Bool { false }

    public init(
        transcriber: PianoSpecializedTranscriber = BasicPitchTranscriber(),
        byteDance: PianoSpecializedTranscriber = ByteDancePianoTranscriber(),
        acceptanceThreshold: Double = 0.80,
        cleanupConfig: TranscriptionCleanup.Config = .noisyPiano
    ) {
        self.basicPitch = transcriber
        self.byteDance = byteDance
        self.acceptanceThreshold = acceptanceThreshold
        _ = cleanupConfig
    }

    public func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun {
        try throwIfMissing(basicPitch.isAvailable, kind: kind, reason: basicPitch.unavailableReason)

        progress?(PipelineProgress(stage: .loading, fraction: 0.0))
        let audioDuration = AudioDurationProbe.durationSeconds(of: audioURL)
        let runner = QualityFirstTranscriptionRunner(
            scoringProfile: .noisySoloPiano,
            acceptanceThreshold: acceptanceThreshold,
            audioDurationSeconds: audioDuration
        )

        let primary = TranscriptionAttempt(
            label: "Basic Pitch + noisy-piano cleanup",
            backendName: basicPitch.modelName,
            cleanupProfile: "noisyPiano",
            cleanupConfig: .noisyPiano,
            parameters: ["primary": "true"]
        ) { p in
            try await self.basicPitch.transcribePiano(audioURL: audioURL, progress: p).notes
        }

        var refinements: [TranscriptionAttempt] = [
            TranscriptionAttempt(
                label: "Basic Pitch + stricter cleanup",
                backendName: basicPitch.modelName,
                cleanupProfile: "mixedAudioStrict",
                cleanupConfig: .mixedAudioStrict
            ) { p in
                try await self.basicPitch.transcribePiano(audioURL: audioURL, progress: p).notes
            },
            TranscriptionAttempt(
                label: "Basic Pitch + melody-only profile",
                backendName: basicPitch.modelName,
                cleanupProfile: "melodyOnly",
                cleanupConfig: .melodyOnly
            ) { p in
                try await self.basicPitch.transcribePiano(audioURL: audioURL, progress: p).notes
            },
        ]
        if byteDance.isAvailable {
            refinements.append(TranscriptionAttempt(
                label: "ByteDance + noisy-piano cleanup",
                backendName: byteDance.modelName,
                cleanupProfile: "noisyPiano",
                cleanupConfig: .noisyPiano
            ) { p in
                try await self.byteDance.transcribePiano(audioURL: audioURL, progress: p).notes
            })
        }

        let outcome = try await runner.run(primary: primary, refinements: refinements, progress: progress)
        progress?(PipelineProgress(stage: .finalizing, fraction: 0.92, detail: "MIDI clinic"))

        let clinic = applyClinic(
            chosen: outcome.chosen,
            audioDurationSeconds: audioDuration,
            pipelineKind: kind
        )

        progress?(PipelineProgress(stage: .finalizing, fraction: 0.96, detail: "playability check"))
        let playability = applyPlayabilityCritic(
            notes: clinic.notes,
            audioDurationSeconds: audioDuration,
            pipelineKind: kind
        )

        progress?(PipelineProgress(stage: .finalizing, fraction: 1.0,
                                   detail: "after-clinic \(String(format: "%.2f", clinic.report.afterScore)); playability \(String(format: "%.2f", playability.report.afterDiagnosis.score))"))

        var params = parameters
        params["model.fallback"] = "false"
        params["backend.kind"] = "dedicated"
        params["backend.ran"] = outcome.chosen.backendName
        stampOutcome(on: &params, outcome: outcome)
        for (k, v) in MidiClinicMetadata.parameters(for: clinic.report) { params[k] = v }
        for (k, v) in PlayabilityCriticMetadata.parameters(for: playability.report) { params[k] = v }

        return TranscriptionRun.makeWithMandatoryCleanup(
            rawModelNotes: playability.notes,
            audioDurationSeconds: audioDuration,
            pipelineVersion: version,
            modelName: outcome.chosen.backendName,
            pipelineID: kind.rawValue,
            pipelineName: kind.displayName,
            modelVersion: basicPitch.modelVersion,
            pipelineParameters: params,
            usedSourceSeparation: false,
            inputAudioPath: audioURL.path
        )
    }
}

// MARK: - Mixed Instruments / Advanced

/// Source-separation pipeline for songs with vocals / drums / strings /
/// other instruments alongside piano.
///
/// **Dependency rules** (per spec):
///   • Demucs is REQUIRED.
///   • Basic Pitch is the preferred post-separation transcriber.
///   • ByteDance is OPTIONAL — used as a refinement candidate when
///     available, never as the only requirement.
///   • Demucs is missing → throw with setup instructions.
///   • Basic Pitch AND ByteDance both missing → throw.
///   • Otherwise → run.
///
/// **Flow** (per spec):
///   input → Demucs (htdemucs --two-stems other) → recursively locate
///   `other.wav` → run Basic Pitch on the stem → if Basic Pitch score is
///   below threshold AND ByteDance is available, also run ByteDance on
///   the stem → score every candidate → pick best → mandatory cleanup.
///
/// ByteDance is NEVER run on the raw mixed audio — only on the isolated
/// stem. This was the catastrophic-quality failure mode in the prior
/// implementation.
public final class MixedInstrumentsAdvancedPipeline: TranscriptionPipeline, @unchecked Sendable {
    public let kind: PipelineKind = .mixedInstrumentsAdvanced
    public let version: String = "2.0.0"

    private let separator: SourceSeparator
    private let basicPitch: PianoSpecializedTranscriber
    private let byteDance: PianoSpecializedTranscriber
    private let acceptanceThreshold: Double
    private let stemDirectoryProvider: () -> URL

    public var modelName: String {
        let primary = basicPitch.isAvailable ? basicPitch.modelName : byteDance.modelName
        return "\(separator.name) → \(primary)"
    }
    public var modelVersion: String? { basicPitch.modelVersion ?? byteDance.modelVersion }
    public var parameters: [String: String] {
        var p: [String: String] = [
            "pipeline.architecture": "Demucs (htdemucs · two-stems other → other.wav) → Basic Pitch primary; ByteDance refinement when available",
            "separator.name": separator.name,
            "primary.transcriber": basicPitch.isAvailable ? basicPitch.modelName : byteDance.modelName,
        ]
        return p
    }
    public var usesSourceSeparation: Bool { true }

    public init(
        separator: SourceSeparator = DemucsWrapperSeparator(),
        basicPitch: PianoSpecializedTranscriber = BasicPitchTranscriber(),
        byteDance: PianoSpecializedTranscriber = ByteDancePianoTranscriber(),
        acceptanceThreshold: Double = 0.80,
        cleanupConfig: TranscriptionCleanup.Config = .mixedAudioStrict,
        stemDirectoryProvider: @escaping () -> URL = {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ptk_advanced_stems_\(UUID().uuidString)")
        }
    ) {
        self.separator = separator
        self.basicPitch = basicPitch
        self.byteDance = byteDance
        self.acceptanceThreshold = acceptanceThreshold
        self.stemDirectoryProvider = stemDirectoryProvider
        _ = cleanupConfig
    }

    /// Two-arg legacy initializer kept for callers that still pass a single
    /// `transcriber:` parameter. Routes that single transcriber to BOTH
    /// slots so existing tests keep their original semantics; the new
    /// dependency rule is enforced via `basicPitch` / `byteDance`
    /// availability flags at run time.
    public convenience init(
        separator: SourceSeparator,
        transcriber: PianoSpecializedTranscriber,
        cleanupConfig: TranscriptionCleanup.Config = .mixedAudioStrict,
        stemDirectoryProvider: @escaping () -> URL = {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ptk_advanced_stems_\(UUID().uuidString)")
        }
    ) {
        self.init(
            separator: separator,
            basicPitch: transcriber,
            byteDance: transcriber,
            acceptanceThreshold: 0.80,
            cleanupConfig: cleanupConfig,
            stemDirectoryProvider: stemDirectoryProvider
        )
    }

    public func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun {
        // Hard requirement: Demucs.
        try throwIfMissing(separator.isAvailable, kind: kind, reason: separator.unavailableReason)

        // Soft requirement: at least one transcription backend.
        let hasBasicPitch = basicPitch.isAvailable
        let hasByteDance = byteDance.isAvailable
        guard hasBasicPitch || hasByteDance else {
            throw PipelineError.unavailable(reason:
                "Mixed Instruments / Advanced needs Basic Pitch OR ByteDance after separation. Run `bash scripts/setup-transcription-deps.sh`."
            )
        }

        // 1. Demucs separation.
        progress?(PipelineProgress(stage: .loading, fraction: 0.0, detail: "isolating piano stem"))
        let audioDuration = AudioDurationProbe.durationSeconds(of: audioURL)
        let stemDir = stemDirectoryProvider()
        try FileManager.default.createDirectory(at: stemDir, withIntermediateDirectories: true)
        let separation = try await separator.separate(
            audioURL: audioURL,
            outputDirectory: stemDir,
            progress: progress
        )

        // 2. Quality-first transcription on the stem.
        progress?(PipelineProgress(stage: .analyzing, fraction: 0.55, detail: "transcribing piano stem"))
        let runner = QualityFirstTranscriptionRunner(
            scoringProfile: .mixedInstruments,
            acceptanceThreshold: acceptanceThreshold,
            audioDurationSeconds: audioDuration
        )
        let stemURL = separation.stemURL

        // Pick the primary based on what's available, preferring Basic
        // Pitch (more robust on stems with residual instrument leakage).
        let primary: TranscriptionAttempt
        var refinements: [TranscriptionAttempt] = []
        if hasBasicPitch {
            primary = TranscriptionAttempt(
                label: "Demucs → Basic Pitch + strict mixed cleanup",
                backendName: basicPitch.modelName,
                cleanupProfile: "mixedAudioStrict",
                cleanupConfig: .mixedAudioStrict,
                parameters: ["primary": "true"]
            ) { p in
                try await self.basicPitch.transcribePiano(audioURL: stemURL, progress: p).notes
            }
            refinements.append(TranscriptionAttempt(
                label: "Demucs → Basic Pitch + noisy-piano cleanup",
                backendName: basicPitch.modelName,
                cleanupProfile: "noisyPiano",
                cleanupConfig: .noisyPiano
            ) { p in
                try await self.basicPitch.transcribePiano(audioURL: stemURL, progress: p).notes
            })
            if hasByteDance {
                refinements.append(TranscriptionAttempt(
                    label: "Demucs → ByteDance + strict mixed cleanup",
                    backendName: byteDance.modelName,
                    cleanupProfile: "mixedAudioStrict",
                    cleanupConfig: .mixedAudioStrict
                ) { p in
                    try await self.byteDance.transcribePiano(audioURL: stemURL, progress: p).notes
                })
                refinements.append(TranscriptionAttempt(
                    label: "Demucs → ByteDance + melody-only profile",
                    backendName: byteDance.modelName,
                    cleanupProfile: "melodyOnly",
                    cleanupConfig: .melodyOnly
                ) { p in
                    try await self.byteDance.transcribePiano(audioURL: stemURL, progress: p).notes
                })
            }
        } else {
            // Only ByteDance available — still operate on the stem (NEVER on
            // raw mixed audio). Marked as less stable in metadata.
            primary = TranscriptionAttempt(
                label: "Demucs → ByteDance + strict mixed cleanup (less stable)",
                backendName: byteDance.modelName,
                cleanupProfile: "mixedAudioStrict",
                cleanupConfig: .mixedAudioStrict,
                parameters: ["primary": "true", "stability": "less-stable"]
            ) { p in
                try await self.byteDance.transcribePiano(audioURL: stemURL, progress: p).notes
            }
            refinements.append(TranscriptionAttempt(
                label: "Demucs → ByteDance + melody-only profile",
                backendName: byteDance.modelName,
                cleanupProfile: "melodyOnly",
                cleanupConfig: .melodyOnly
            ) { p in
                try await self.byteDance.transcribePiano(audioURL: stemURL, progress: p).notes
            })
        }

        let outcome = try await runner.run(primary: primary, refinements: refinements, progress: progress)
        progress?(PipelineProgress(stage: .finalizing, fraction: 0.92, detail: "MIDI clinic"))

        let clinic = applyClinic(
            chosen: outcome.chosen,
            audioDurationSeconds: audioDuration,
            pipelineKind: kind,
            isolatedStemPath: stemURL.path
        )

        progress?(PipelineProgress(stage: .finalizing, fraction: 0.96, detail: "playability check"))
        let playability = applyPlayabilityCritic(
            notes: clinic.notes,
            audioDurationSeconds: audioDuration,
            pipelineKind: kind
        )

        progress?(PipelineProgress(stage: .finalizing, fraction: 1.0,
                                   detail: "after-clinic \(String(format: "%.2f", clinic.report.afterScore)); playability \(String(format: "%.2f", playability.report.afterDiagnosis.score))"))

        var params = parameters
        for (k, v) in separation.parameters { params["separator.\(k)"] = v }
        params["model.fallback"] = "false"
        params["backend.kind"] = "dedicated"
        params["backend.ran"] = "\(separation.methodName) → \(outcome.chosen.backendName)"
        params["separator.method"] = separation.methodName
        params["separator.stemDuration"] = String(format: "%.4f", separation.stemDurationSeconds)
        stampOutcome(on: &params, outcome: outcome)
        for (k, v) in MidiClinicMetadata.parameters(for: clinic.report) { params[k] = v }
        for (k, v) in PlayabilityCriticMetadata.parameters(for: playability.report) { params[k] = v }

        // Data Flow metadata: selected vs. actual pipeline, separator +
        // transcription wrapper paths, separated stem path, fallback false.
        // Reads `TranscriptionBackendRegistry` for the resolved wrapper
        // paths the run actually shelled out to.
        let demucsStatus = TranscriptionBackendRegistry.shared.resolve(.demucs)
        let basicPitchStatus = TranscriptionBackendRegistry.shared.resolve(.basicPitch)
        let byteDanceStatus = TranscriptionBackendRegistry.shared.resolve(.byteDance)
        let chosenIsBasicPitch = outcome.chosen.backendName == basicPitch.modelName
        let transcriptionStatus = chosenIsBasicPitch ? basicPitchStatus : byteDanceStatus
        let inputDur = AudioDurationProbe.durationSeconds(of: audioURL)

        params["dataflow.fallback"] = "false"
        params["dataflow.selectedMode"] = kind.rawValue
        params["dataflow.selectedModeDisplay"] = kind.displayName
        params["dataflow.actualPipeline"] = kind.displayName
        params["dataflow.actualSeparator"] = separation.methodName
        params["dataflow.separatorBackend"] = demucsStatus.wrapperName
        if let p = demucsStatus.resolvedPath {
            params["dataflow.separatorPath"] = p
        }
        params["dataflow.actualTranscriber"] = outcome.chosen.backendName
        params["dataflow.transcriptionBackend"] = transcriptionStatus.wrapperName
        if let p = transcriptionStatus.resolvedPath {
            params["dataflow.transcriptionPath"] = p
        }
        params["dataflow.inputAudioPath"] = audioURL.path
        if let d = inputDur { params["dataflow.inputAudioDuration"] = String(format: "%.2f", d) }
        params["dataflow.isolatedStemPath"] = stemURL.path
        params["dataflow.isolatedStemDuration"] = String(format: "%.2f", separation.stemDurationSeconds)
        params["dataflow.rawNoteCount"] = "\(outcome.chosen.rawNotes.count)"

        return TranscriptionRun.makeWithMandatoryCleanup(
            rawModelNotes: playability.notes,
            audioDurationSeconds: audioDuration,
            pipelineVersion: version,
            modelName: "\(separation.methodName) → \(outcome.chosen.backendName)",
            pipelineID: kind.rawValue,
            pipelineName: kind.displayName,
            modelVersion: basicPitch.modelVersion ?? byteDance.modelVersion,
            pipelineParameters: params,
            usedSourceSeparation: true,
            inputAudioPath: audioURL.path,
            isolatedStemPath: stemURL.path
        )
    }
}
