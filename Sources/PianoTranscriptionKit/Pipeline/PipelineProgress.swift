import Foundation

/// A snapshot of pipeline progress, emitted incrementally while a run executes.
public struct PipelineProgress: Sendable, Equatable {
    public let stage: Stage
    /// Fraction of the overall run completed, in [0, 1].
    public let fraction: Double
    /// Free-form detail for the current stage (e.g. "frame 420 / 812").
    public let detail: String?

    public init(stage: Stage, fraction: Double, detail: String? = nil) {
        self.stage = stage
        self.fraction = min(1, max(0, fraction))
        self.detail = detail
    }

    public enum Stage: String, Sendable, Equatable, CaseIterable {
        case loading    = "Loading audio"
        case analyzing  = "Analyzing spectrum"
        case detecting  = "Detecting notes"
        case finalizing = "Finalizing"
    }
}

public typealias PipelineProgressHandler = @Sendable (PipelineProgress) -> Void
