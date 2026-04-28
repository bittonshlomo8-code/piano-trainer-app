import Foundation

/// `ModelRunner` adapter that runs Spotify's Basic Pitch and exposes the
/// result as a plain `[MIDINote]` array — same interface as
/// `BasicPianoModelRunner`. This is the path the rest of the app uses
/// whenever a `ModelRunner` is expected (registry diagnostics, future
/// custom pipelines, etc.).
///
/// Internally this delegates to `BasicPitchTranscriber` (the
/// `PianoSpecializedTranscriber` adapter) so there is one place where the
/// CLI is shelled out from. The split is deliberate:
///   • `BasicPitchTranscriber` carries full model identity (sample rate,
///     model version, fallback flag) for the precision/external pipeline.
///   • `BasicPitchModelRunner` strips that down to the simpler
///     `ModelRunner` shape for any pipeline that only wants notes.
///
/// Mac-first today; designed so a future Core ML conversion can replace
/// the shell-out with a native model load without changing this adapter's
/// public surface.
public final class BasicPitchModelRunner: ModelRunner, @unchecked Sendable {

    public var name: String { transcriber.modelName }

    /// True when the underlying CLI / model is reachable.
    public var isAvailable: Bool { transcriber.isAvailable }
    public var unavailableReason: String? { transcriber.unavailableReason }

    private let transcriber: BasicPitchTranscriber

    public init(transcriber: BasicPitchTranscriber = BasicPitchTranscriber()) {
        self.transcriber = transcriber
    }

    public func transcribe(audioURL: URL, progress: PipelineProgressHandler?) async throws -> [MIDINote] {
        guard transcriber.isAvailable else {
            throw PipelineError.unavailable(
                reason: transcriber.unavailableReason ?? "Basic Pitch unavailable."
            )
        }
        let result = try await transcriber.transcribePiano(audioURL: audioURL, progress: progress)
        return result.notes
    }
}
