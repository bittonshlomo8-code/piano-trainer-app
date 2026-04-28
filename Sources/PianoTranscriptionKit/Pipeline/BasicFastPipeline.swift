import Foundation

/// "Basic / Legacy Baseline" pipeline — quick local test for simple piano audio.
///
/// Smoke-test runner. Goes through `TranscriptionRun.makeWithMandatoryCleanup`
/// so even if a future patch forgets the cleanup step, the run still cannot
/// land on disk with 200-second stuck notes.
public final class BasicFastPipeline: TranscriptionPipeline, @unchecked Sendable {
    public let kind: PipelineKind = .basicFast
    public let version: String = "1.2.0"

    private let runner: BasicPianoModelRunner
    private let cleanupConfig: TranscriptionCleanup.Config

    public var modelName: String { runner.name }
    public var modelVersion: String? { "1.0" }
    public var parameters: [String: String] {
        var p = runner.config.asParameters
        p["cleanup.maxNoteDurationSeconds"] = String(cleanupConfig.maxNoteDurationSeconds)
        p["cleanup.maxNotesPerClusterWindow"] = String(cleanupConfig.maxNotesPerClusterWindow)
        p["cleanup.maxNotesPerExactOnset"] = String(cleanupConfig.maxNotesPerExactOnset)
        p["cleanup.maxNotesPerDensityBucket"] = String(cleanupConfig.maxNotesPerDensityBucket)
        p["cleanup.forceTimelineMatch"] = String(cleanupConfig.forceTimelineMatch)
        return p
    }
    public var usesSourceSeparation: Bool { false }

    public init(
        runner: BasicPianoModelRunner = BasicPianoModelRunner(config: .basic),
        cleanupConfig: TranscriptionCleanup.Config = .mandatory
    ) {
        self.runner = runner
        self.cleanupConfig = cleanupConfig
    }

    public func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun {
        progress?(PipelineProgress(stage: .loading, fraction: 0.0))
        let audioDuration = AudioDurationProbe.durationSeconds(of: audioURL)
        let raw = try await runner.transcribe(audioURL: audioURL, progress: progress)
        let kindRaw = self.kind.rawValue
        let runnerName = self.runner.name
        let audioStr = audioDuration.map { String(format: "%.2f", $0) } ?? "?"
        TranscriptionRunLog.pipeline.info(
            "kind=\(kindRaw, privacy: .public) model=\(runnerName, privacy: .public) raw=\(raw.count) audio=\(audioStr, privacy: .public)s"
        )
        progress?(PipelineProgress(stage: .finalizing, fraction: 0.85, detail: "cleanup"))

        let run = TranscriptionRun.makeWithMandatoryCleanup(
            rawModelNotes: raw,
            audioDurationSeconds: audioDuration,
            pipelineVersion: version,
            modelName: runner.name,
            pipelineID: kind.rawValue,
            pipelineName: kind.displayName,
            modelVersion: modelVersion,
            pipelineParameters: parameters,
            usedSourceSeparation: false,
            inputAudioPath: audioURL.path,
            cleanupConfig: cleanupConfig
        )
        progress?(PipelineProgress(stage: .finalizing, fraction: 1.0,
                                   detail: "\(run.notes.count) notes (raw \(raw.count))"))
        return run
    }
}
