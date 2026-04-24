import Foundation

public protocol TranscriptionPipeline: Sendable {
    var version: String { get }
    /// Run the pipeline, emitting progress updates as stages complete.
    /// Implementations should always deliver a final `finalizing` update at fraction 1.0.
    func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun
}

public extension TranscriptionPipeline {
    func run(audioURL: URL) async throws -> TranscriptionRun {
        try await run(audioURL: audioURL, progress: nil)
    }
}
