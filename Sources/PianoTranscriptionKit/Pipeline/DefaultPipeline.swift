import Foundation

/// Minimal v1 pipeline: Audio → ModelRunner → TranscriptionRun
public final class DefaultPipeline: TranscriptionPipeline, @unchecked Sendable {
    public let version = "1.0.0"

    private let runner: any ModelRunner

    public init(runner: any ModelRunner) {
        self.runner = runner
    }

    public func run(audioURL: URL) async throws -> TranscriptionRun {
        let notes = try await runner.transcribe(audioURL: audioURL)
        return TranscriptionRun(
            pipelineVersion: version,
            modelName: runner.name,
            notes: notes
        )
    }
}
