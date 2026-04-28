import Foundation

/// Shared pipeline body used by adapters that delegate to an external
/// piano-transcription model (Basic Pitch, ByteDance, etc.). All paths route
/// through `TranscriptionRun.makeWithMandatoryCleanup` so every advanced run
/// inherits the same bounded-duration / capped-cluster / timeline-matched
/// invariants that the in-house pipelines enforce — and `RunComparison`
/// numbers stay apples-to-apples across models.
public final class ExternalModelPipeline: TranscriptionPipeline, @unchecked Sendable {

    public let kind: PipelineKind
    public let version: String
    public let transcriber: PianoSpecializedTranscriber
    public let cleanupConfig: TranscriptionCleanup.Config

    public var modelName: String { transcriber.modelName }
    public var modelVersion: String? { transcriber.modelVersion }
    public var parameters: [String: String] {
        var p = transcriber.parameters
        p["cleanup.maxNoteDurationSeconds"] = String(cleanupConfig.maxNoteDurationSeconds)
        p["cleanup.maxNotesPerClusterWindow"] = String(cleanupConfig.maxNotesPerClusterWindow)
        p["cleanup.maxNotesPerExactOnset"] = String(cleanupConfig.maxNotesPerExactOnset)
        p["cleanup.maxNotesPerDensityBucket"] = String(cleanupConfig.maxNotesPerDensityBucket)
        p["cleanup.forceTimelineMatch"] = String(cleanupConfig.forceTimelineMatch)
        return p
    }
    public var usesSourceSeparation: Bool { false }

    public init(
        kind: PipelineKind,
        transcriber: PianoSpecializedTranscriber,
        cleanupConfig: TranscriptionCleanup.Config = .mandatory,
        version: String = "1.0.0"
    ) {
        self.kind = kind
        self.transcriber = transcriber
        self.cleanupConfig = cleanupConfig
        self.version = version
    }

    public func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun {
        guard transcriber.isAvailable else {
            throw PipelineError.unavailable(
                reason: transcriber.unavailableReason ?? "\(transcriber.modelName) is unavailable."
            )
        }
        progress?(PipelineProgress(stage: .loading, fraction: 0.0))
        let audioDuration = AudioDurationProbe.durationSeconds(of: audioURL)
        let result = try await transcriber.transcribePiano(audioURL: audioURL, progress: progress)
        let kindRaw = self.kind.rawValue
        let audioStr = audioDuration.map { String(format: "%.2f", $0) } ?? "?"
        TranscriptionRunLog.pipeline.info(
            "kind=\(kindRaw, privacy: .public) model=\(result.modelName, privacy: .public) raw=\(result.notes.count) fallback=\(result.isFallback) audio=\(audioStr, privacy: .public)s"
        )
        progress?(PipelineProgress(stage: .finalizing, fraction: 0.90, detail: "cleanup"))

        var params = parameters
        for (k, v) in result.parameters { params["model.\(k)"] = v }
        params["model.fallback"] = result.isFallback ? "true" : "false"
        params["model.sampleRate"] = String(format: "%.0f", result.sampleRate)
        // Explicit "Backend ran" identity so the sidebar can show whether the
        // dedicated external model actually executed (vs. silently falling back).
        params["backend.ran"] = result.modelName
        params["backend.kind"] = result.isFallback ? "fallback" : "dedicated"
        params["backend.modelVersion"] = result.modelVersion
        // Run was executed *directly* on the input — no separation. If this
        // model expects a clean piano signal, stamp the suitability warning
        // so the sidebar can surface "this run was on mixed audio" honestly.
        if let warning = kind.mixedAudioSuitabilityWarning {
            params["suitability.directOnMixedAudioRisk"] = "true"
            params["suitability.warning"] = warning
        }
        params["dataflow.actualSeparator"] = "(none — direct on input)"
        params["dataflow.actualTranscriber"] = result.modelName
        params["dataflow.fallback"] = result.isFallback ? "true" : "false"
        params["dataflow.inputAudioPath"] = audioURL.path
        if let d = audioDuration {
            params["dataflow.inputAudioDuration"] = String(format: "%.2f", d)
        }
        params["dataflow.rawNoteCount"] = "\(result.notes.count)"

        let run = TranscriptionRun.makeWithMandatoryCleanup(
            rawModelNotes: result.notes,
            audioDurationSeconds: audioDuration,
            pipelineVersion: version,
            modelName: result.modelName,
            pipelineID: kind.rawValue,
            pipelineName: kind.displayName,
            modelVersion: result.modelVersion,
            pipelineParameters: params,
            usedSourceSeparation: false,
            inputAudioPath: audioURL.path,
            cleanupConfig: cleanupConfig
        )
        progress?(PipelineProgress(stage: .finalizing, fraction: 1.0,
                                   detail: "\(run.notes.count) notes (raw \(result.notes.count))"))
        return run
    }
}
