import Foundation

/// A user-selectable transcription strategy. Pipelines own the entire flow
/// from audio file to `TranscriptionRun` and are responsible for stamping the
/// run with their identity (so each persisted run records exactly which
/// pipeline produced it).
public protocol TranscriptionPipeline: Sendable {
    /// User-selected pipeline kind that produced this implementation.
    var kind: PipelineKind { get }
    /// Pipeline schema version, used to invalidate cached output if the
    /// pipeline's logic ever changes incompatibly.
    var version: String { get }
    /// Human-readable name of the underlying model/runner. Stored on the run
    /// so older runs remain identifiable even if defaults shift later.
    var modelName: String { get }
    /// Optional version string for the model/runner (e.g. "v1.2").
    var modelVersion: String? { get }
    /// Snapshot of tuning parameters applied during the run.
    var parameters: [String: String] { get }
    /// Whether this pipeline applies source separation before transcription.
    var usesSourceSeparation: Bool { get }

    /// Run the pipeline, emitting progress updates as stages complete.
    /// Implementations should always deliver a final `finalizing` update at fraction 1.0.
    func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun
}

public extension TranscriptionPipeline {
    var modelVersion: String? { nil }
    var parameters: [String: String] { [:] }
    var usesSourceSeparation: Bool { false }

    func run(audioURL: URL) async throws -> TranscriptionRun {
        try await run(audioURL: audioURL, progress: nil)
    }
}

/// Errors thrown by pipelines themselves (distinct from runner errors).
public enum PipelineError: Error, LocalizedError {
    case unavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        }
    }
}
