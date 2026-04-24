import Foundation

/// Minimal v1 pipeline: Audio → ModelRunner → TranscriptionRun
public final class DefaultPipeline: TranscriptionPipeline, @unchecked Sendable {
    public let version = "1.0.0"

    private let runner: any ModelRunner

    public init(runner: any ModelRunner) {
        self.runner = runner
    }

    public func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun {
        progress?(PipelineProgress(stage: .loading, fraction: 0.0))
        let notes = try await runner.transcribe(audioURL: audioURL, progress: progress)
        progress?(PipelineProgress(stage: .finalizing, fraction: 1.0, detail: "\(notes.count) notes"))
        return TranscriptionRun(
            pipelineVersion: version,
            modelName: runner.name,
            notes: notes
        )
    }
}
