import Foundation

/// Used by the registry for modes that the user explicitly asked NOT to
/// silently substitute when the dedicated backend (e.g. ByteDance Python
/// wrapper) is missing. Selecting this pipeline throws
/// `PipelineError.unavailable` immediately with the install instructions —
/// no Piano-Focused fallback masquerades as the requested model.
public final class MissingBackendThrowingPipeline: TranscriptionPipeline, @unchecked Sendable {
    public let kind: PipelineKind
    public let version: String = "1.0.0"
    public let reason: String

    public var modelName: String { "Unavailable: \(kind.displayName)" }
    public var modelVersion: String? { nil }
    public var parameters: [String: String] {
        [
            "backend.ran": "none",
            "backend.kind": "missing",
            "missing.reason": reason,
        ]
    }
    public var usesSourceSeparation: Bool { false }

    public init(kind: PipelineKind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    public func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun {
        TranscriptionRunLog.pipeline.error(
            "kind=\(self.kind.rawValue, privacy: .public) backend=missing reason=\(self.reason, privacy: .public)"
        )
        throw PipelineError.unavailable(reason: reason)
    }
}
