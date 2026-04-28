import Foundation

/// Routes a `PipelineKind` to the Piano-Focused pipeline when the dedicated
/// backend (source separator, Basic Pitch CLI, ByteDance wrapper, …) is not
/// installed on the host.
///
/// The intent is laid out in the user-facing spec: every dropdown mode must
/// stay selectable. When dependencies are missing we *do not* hide the mode
/// or throw `unsupportedMode` — we run a clearly-labeled fallback. The run
/// stamps `fallback.applied=true` plus the original mode name and an install
/// hint so the UI can show "Using Piano-Focused fallback for this mode until
/// dedicated model files are installed."
public final class FallbackTranscriptionPipeline: TranscriptionPipeline, @unchecked Sendable {

    public let kind: PipelineKind
    public let version: String = "1.0.0"

    /// User-facing reason explaining why we're on the fallback.
    public let fallbackReason: String

    private let inner: PianoFocusedPipeline

    public var modelName: String { inner.modelName }
    public var modelVersion: String? { inner.modelVersion }
    public var parameters: [String: String] {
        var p = inner.parameters
        p["fallback.applied"] = "true"
        p["fallback.requestedKind"] = kind.rawValue
        p["fallback.requestedDisplayName"] = kind.displayName
        p["fallback.reason"] = fallbackReason
        return p
    }
    public var usesSourceSeparation: Bool { false }

    public init(kind: PipelineKind,
                fallbackReason: String,
                inner: PianoFocusedPipeline = PianoFocusedPipeline()) {
        self.kind = kind
        self.fallbackReason = fallbackReason
        self.inner = inner
    }

    public func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun {
        progress?(PipelineProgress(stage: .loading, fraction: 0.0,
                                   detail: "fallback to Piano-Focused"))
        let run = try await inner.run(audioURL: audioURL, progress: progress)

        // Re-stamp the run so the user-facing pipeline identity reflects the
        // *requested* mode, not Piano-Focused. The fallback flag in
        // `pipelineParameters` is what marks this as a fallback execution.
        var params = run.pipelineParameters
        params["fallback.applied"] = "true"
        params["fallback.requestedKind"] = kind.rawValue
        params["fallback.requestedDisplayName"] = kind.displayName
        params["fallback.reason"] = fallbackReason
        params["fallback.executedBy"] = inner.kind.rawValue
        params["backend.ran"] = inner.modelName
        params["backend.kind"] = "fallback"
        params["backend.modelVersion"] = inner.modelVersion ?? ""

        return TranscriptionRun(
            id: run.id,
            createdAt: run.createdAt,
            pipelineVersion: version,
            modelName: run.modelName,
            notes: run.notes,
            label: run.label,
            pipelineID: kind.rawValue,
            pipelineName: kind.displayName,
            modelVersion: run.modelVersion,
            pipelineParameters: params,
            usedSourceSeparation: run.usedSourceSeparation,
            inputAudioPath: run.inputAudioPath,
            isolatedStemPath: run.isolatedStemPath,
            rawNotes: run.rawNotes,
            cleanupReport: run.cleanupReport,
            sourceAudioDuration: run.sourceAudioDuration
        )
    }
}

public extension TranscriptionRun {
    /// Convenience accessor for the UI: was this run produced by the
    /// `FallbackTranscriptionPipeline`?
    var ranOnFallback: Bool {
        pipelineParameters["fallback.applied"] == "true"
    }

    /// Display reason (or nil if not a fallback). Surfaced as a one-liner
    /// in the inspector / pipeline picker.
    var fallbackReason: String? {
        ranOnFallback ? pipelineParameters["fallback.reason"] : nil
    }

    /// Human-readable name of the backend that actually executed this run.
    /// Returns the model name (e.g. "Basic Pitch (Spotify)" or "BasicSpectral v1")
    /// — falls back to `modelName` for older runs that didn't record this stamp.
    var backendRan: String {
        pipelineParameters["backend.ran"] ?? modelName
    }

    /// Whether the run executed the dedicated external model (`dedicated`)
    /// or the Piano-Focused fallback (`fallback`). Older runs return nil.
    var backendKind: String? {
        pipelineParameters["backend.kind"]
    }

    /// Suitability warning for this run, if the pipeline stamped one
    /// (e.g. a piano-specialized model run directly on mixed audio).
    var suitabilityWarning: String? {
        pipelineParameters["suitability.warning"]
    }

    /// Convenience getter for any `dataflow.*` parameter so the sidebar can
    /// render the Data Flow section without splatting raw dictionary keys.
    func dataflow(_ key: String) -> String? {
        pipelineParameters["dataflow.\(key)"]
    }
}
