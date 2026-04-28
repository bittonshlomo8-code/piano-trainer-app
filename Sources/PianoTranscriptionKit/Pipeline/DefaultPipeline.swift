import Foundation

/// Minimal v1 pipeline: Audio → ModelRunner → TranscriptionRun.
///
/// Kept as a thin building block used by the concrete user-facing pipelines
/// and by tests. Cleanup goes through `TranscriptionRun.makeWithMandatoryCleanup`
/// so even the test-mock path produces bounded runs by default; opt-out is
/// only available via `applyCleanup: false`, which is reserved for tests
/// that explicitly want to inspect raw model output.
public final class DefaultPipeline: TranscriptionPipeline, @unchecked Sendable {
    public let kind: PipelineKind
    public let version: String = "1.1.0"
    public let runner: any ModelRunner
    public var modelName: String { runner.name }
    public let applyCleanup: Bool

    public init(runner: any ModelRunner, kind: PipelineKind = .basicFast, applyCleanup: Bool = true) {
        self.runner = runner
        self.kind = kind
        self.applyCleanup = applyCleanup
    }

    public func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun {
        progress?(PipelineProgress(stage: .loading, fraction: 0.0))
        let audioDuration = AudioDurationProbe.durationSeconds(of: audioURL)
        let raw = try await runner.transcribe(audioURL: audioURL, progress: progress)

        if applyCleanup {
            let run = TranscriptionRun.makeWithMandatoryCleanup(
                rawModelNotes: raw,
                audioDurationSeconds: audioDuration,
                pipelineVersion: version,
                modelName: runner.name,
                pipelineID: kind.rawValue,
                pipelineName: kind.displayName,
                inputAudioPath: audioURL.path
            )
            progress?(PipelineProgress(stage: .finalizing, fraction: 1.0,
                                       detail: "\(run.notes.count) notes (raw \(raw.count))"))
            return run
        }

        progress?(PipelineProgress(stage: .finalizing, fraction: 1.0, detail: "\(raw.count) notes"))
        return TranscriptionRun(
            pipelineVersion: version,
            modelName: runner.name,
            notes: raw,
            pipelineID: kind.rawValue,
            pipelineName: kind.displayName,
            inputAudioPath: audioURL.path,
            sourceAudioDuration: audioDuration
        )
    }
}
