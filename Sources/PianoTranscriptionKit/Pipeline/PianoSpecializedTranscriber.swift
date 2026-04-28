import Foundation

/// Output of a piano-specialized transcription model with full provenance.
public struct PianoTranscriptionResult: Sendable, Equatable {
    public let notes: [MIDINote]
    public let modelName: String
    public let modelVersion: String
    public let sampleRate: Double
    public let parameters: [String: String]
    /// True when the implementation is a fallback (e.g. the basic spectral
    /// runner) rather than a real piano-specialized model. Surfaced in
    /// diagnostics so users know not to trust the output as "specialized".
    public let isFallback: Bool

    public init(
        notes: [MIDINote],
        modelName: String,
        modelVersion: String,
        sampleRate: Double,
        parameters: [String: String] = [:],
        isFallback: Bool = false
    ) {
        self.notes = notes
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.sampleRate = sampleRate
        self.parameters = parameters
        self.isFallback = isFallback
    }
}

/// Piano-specialized transcription stage used by the precision pipeline.
///
/// Real implementations would wrap a Core ML / Onsets-and-Frames / hFT-style
/// model. The protocol exists so the pipeline can swap models without
/// changing orchestration code, and so the post-processor + diagnostics can
/// always rely on `PianoTranscriptionResult` provenance.
public protocol PianoSpecializedTranscriber: Sendable {
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    /// Model identity surfaced before a run starts. The pipeline uses these
    /// to populate run metadata even when no transcription has happened yet.
    var modelName: String { get }
    var modelVersion: String { get }
    var parameters: [String: String] { get }

    func transcribePiano(
        audioURL: URL,
        progress: PipelineProgressHandler?
    ) async throws -> PianoTranscriptionResult
}

/// Wraps the existing `BasicPianoModelRunner` (piano-focused config) into
/// the `PianoSpecializedTranscriber` interface. Marked `isFallback = true`
/// so diagnostics make clear that this is the safety net, not a real
/// piano-specialized model.
public final class FallbackPianoTranscriber: PianoSpecializedTranscriber, @unchecked Sendable {
    public let isAvailable = true
    public let unavailableReason: String? = nil

    private let runner: BasicPianoModelRunner

    public var modelName: String { runner.name }
    public let modelVersion: String = "1.0"
    public var parameters: [String: String] { runner.config.asParameters }

    public init(config: BasicPianoModelRunner.Config = .pianoFocused) {
        self.runner = BasicPianoModelRunner(config: config)
    }

    public func transcribePiano(
        audioURL: URL,
        progress: PipelineProgressHandler?
    ) async throws -> PianoTranscriptionResult {
        let notes = try await runner.transcribe(audioURL: audioURL, progress: progress)
        return PianoTranscriptionResult(
            notes: notes,
            modelName: runner.name,
            modelVersion: "1.0",
            sampleRate: 44100,
            parameters: runner.config.asParameters,
            isFallback: true
        )
    }
}
