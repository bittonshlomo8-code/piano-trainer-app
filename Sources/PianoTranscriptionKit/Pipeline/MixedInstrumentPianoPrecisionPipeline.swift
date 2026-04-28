import Foundation

/// "Mixed Instruments / Piano Precision" pipeline.
///
/// Stages, in order:
///   1. Normalize source audio → deterministic mono WAV
///   2. Source separation → isolated piano stem (preserves timeline)
///   3. Piano-specialized transcription on the stem
///   4. Conservative post-processing (ghosts, bursts, sustain, octaves, velocity)
///   5. Diagnostics build (density, octave histogram, warnings, drift)
///   6. Artifact write — every intermediate step is persisted as a file
///
/// The pipeline never fakes separation: if the configured `SourceSeparator`
/// is unavailable, the run throws `PipelineError.unavailable` cleanly so the
/// UI can show a helpful reason.
public final class MixedInstrumentPianoPrecisionPipeline: TranscriptionPipeline, @unchecked Sendable {

    public let kind: PipelineKind = .mixedInstrumentPianoPrecision
    public let version: String = "0.1.0"

    public let separator: SourceSeparator
    public let transcriber: PianoSpecializedTranscriber
    public let postProcessor: MixedAudioPostProcessor
    public let normalizer: AudioNormalizer
    public let artifactRoot: URL?
    public let writeArtifacts: Bool

    public var modelName: String {
        "\(separator.name) → \(transcriber.modelName)"
    }
    public var modelVersion: String? { transcriber.modelVersion }
    public var parameters: [String: String] {
        var params = transcriber.parameters
        for (k, v) in postProcessor.config.asParameters { params["post.\(k)"] = v }
        params["separator"] = separator.name
        return params
    }
    public var usesSourceSeparation: Bool { true }

    public init(
        separator: SourceSeparator = UnavailableSourceSeparator(),
        transcriber: PianoSpecializedTranscriber = FallbackPianoTranscriber(),
        postProcessor: MixedAudioPostProcessor = MixedAudioPostProcessor(),
        normalizer: AudioNormalizer = AudioNormalizer(),
        artifactRoot: URL? = nil,
        writeArtifacts: Bool = true
    ) {
        self.separator = separator
        self.transcriber = transcriber
        self.postProcessor = postProcessor
        self.normalizer = normalizer
        self.artifactRoot = artifactRoot
        self.writeArtifacts = writeArtifacts
    }

    public func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun {
        guard separator.isAvailable else {
            throw PipelineError.unavailable(
                reason: separator.unavailableReason
                    ?? "Source separator is not available; precision pipeline cannot run."
            )
        }
        guard transcriber.isAvailable else {
            throw PipelineError.unavailable(
                reason: transcriber.unavailableReason
                    ?? "Piano-specialized transcriber is not available."
            )
        }

        let runID = UUID()
        let runDir = makeRunDirectory(runID: runID)
        if writeArtifacts {
            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        }

        // 1. Normalize ----------------------------------------------------
        progress?(PipelineProgress(stage: .loading, fraction: 0.05, detail: "normalizing audio"))
        let normalized = try normalizer.normalize(sourceURL: audioURL, outputDirectory: runDir)

        // 2. Separate -----------------------------------------------------
        progress?(PipelineProgress(stage: .loading, fraction: 0.15, detail: "isolating piano stem"))
        let separation = try await separator.separate(
            audioURL: normalized.url,
            outputDirectory: runDir,
            progress: progress
        )

        // 3. Transcribe ---------------------------------------------------
        progress?(PipelineProgress(stage: .analyzing, fraction: 0.40, detail: "piano transcription"))
        let result = try await transcriber.transcribePiano(audioURL: separation.stemURL, progress: progress)

        // 4. Post-process -------------------------------------------------
        // Two passes: the mixed-audio specific heuristics (octave correction,
        // sustain merge with velocity ratio, etc.) followed by the mandatory
        // shared cleanup so this pipeline's output meets the same integrity
        // bar as Basic/Legacy and Piano-Focused (audio-bounded notes, bounded
        // duration, capped clusters/density, timeline-matched). Running both
        // means RunComparison numbers stay apples-to-apples across pipelines.
        progress?(PipelineProgress(stage: .detecting, fraction: 0.80, detail: "mixed-audio cleanup"))
        let (mixedCleaned, postReport) = postProcessor.process(result.notes)

        progress?(PipelineProgress(stage: .detecting, fraction: 0.88, detail: "shared cleanup"))
        var sharedCleanupConfig = TranscriptionCleanup.Config.mandatory
        sharedCleanupConfig.audioDurationSeconds = normalized.durationSeconds
        let cleanupOutcome = TranscriptionCleanup.apply(mixedCleaned, config: sharedCleanupConfig)
        let processed = cleanupOutcome.cleaned

        // 5. Diagnostics --------------------------------------------------
        let diagnostics = MixedAudioDiagnosticsBuilder.build(
            notes: processed,
            context: .init(
                sourceDurationSeconds: normalized.durationSeconds,
                stemDurationSeconds: separation.stemDurationSeconds,
                post: postReport
            )
        )

        // 6. Artifacts ----------------------------------------------------
        var rawMIDIPath: URL?
        var postMIDIPath: URL?
        var rawJSONPath: URL?
        var postJSONPath: URL?
        var diagPath: URL?

        if writeArtifacts {
            let exporter = MIDIExporter()
            rawMIDIPath = runDir.appendingPathComponent("raw.mid")
            postMIDIPath = runDir.appendingPathComponent("processed.mid")
            rawJSONPath = runDir.appendingPathComponent("raw_notes.json")
            postJSONPath = runDir.appendingPathComponent("processed_notes.json")
            diagPath = runDir.appendingPathComponent("diagnostics.json")

            let rawRun = TranscriptionRun(
                pipelineVersion: version,
                modelName: result.modelName,
                notes: result.notes,
                pipelineID: kind.rawValue + ".raw",
                pipelineName: "\(kind.displayName) — raw"
            )
            try exporter.export(run: rawRun, to: rawMIDIPath!)
            let postRun = TranscriptionRun(
                pipelineVersion: version,
                modelName: result.modelName,
                notes: processed,
                pipelineID: kind.rawValue,
                pipelineName: kind.displayName
            )
            try exporter.export(run: postRun, to: postMIDIPath!)

            try writeJSON(result.notes, to: rawJSONPath!)
            try writeJSON(processed, to: postJSONPath!)
            try writeJSON(diagnostics, to: diagPath!)
        }

        progress?(PipelineProgress(stage: .finalizing, fraction: 1.0, detail: "\(processed.count) notes · \(diagnostics.warnings.count) warning(s)"))

        var runParameters = parameters
        runParameters["separator.method"] = separation.methodName
        if let q = separation.qualityScore {
            runParameters["separator.quality"] = String(format: "%.4f", q)
        }
        for (k, v) in separation.parameters { runParameters["separator.\(k)"] = v }
        runParameters["model.fallback"] = result.isFallback ? "true" : "false"
        runParameters["timelineDriftSeconds"] = String(format: "%.4f", diagnostics.timelineDriftSeconds)
        if writeArtifacts {
            runParameters["artifact.runDir"] = runDir.path
            if let p = rawMIDIPath  { runParameters["artifact.rawMIDI"]   = p.path }
            if let p = postMIDIPath { runParameters["artifact.postMIDI"]  = p.path }
            if let p = rawJSONPath  { runParameters["artifact.rawJSON"]   = p.path }
            if let p = postJSONPath { runParameters["artifact.postJSON"]  = p.path }
            if let p = diagPath     { runParameters["artifact.diagnostics"] = p.path }
            runParameters["artifact.normalizedAudio"] = normalized.url.path
        }
        // Diagnostics counters live in parameters too so consumers without
        // the typed report can still see them.
        for (k, v) in diagnostics.postProcessorCounters {
            runParameters["diag.\(k)"] = "\(v)"
        }
        runParameters["diag.totalNotes"] = "\(diagnostics.totalNotes)"
        runParameters["diag.warningCount"] = "\(diagnostics.warnings.count)"
        if !diagnostics.warnings.isEmpty {
            runParameters["diag.warnings"] = diagnostics.warnings.joined(separator: " | ")
        }

        return TranscriptionRun(
            id: runID,
            createdAt: Date(),
            pipelineVersion: version,
            modelName: modelName,
            notes: processed,
            label: "",
            pipelineID: kind.rawValue,
            pipelineName: kind.displayName,
            modelVersion: modelVersion,
            pipelineParameters: runParameters,
            usedSourceSeparation: true,
            inputAudioPath: normalized.url.path,
            isolatedStemPath: separation.stemURL.path,
            rawNotes: result.notes,
            cleanupReport: cleanupOutcome.report,
            sourceAudioDuration: normalized.durationSeconds
        )
    }

    private func makeRunDirectory(runID: UUID) -> URL {
        let root: URL
        if let custom = artifactRoot {
            root = custom
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            root = support.appendingPathComponent("PianoTrainer/PrecisionRuns")
        }
        return root.appendingPathComponent(runID.uuidString)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
