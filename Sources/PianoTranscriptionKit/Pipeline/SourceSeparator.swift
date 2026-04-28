import Foundation

/// Result of a source-separation pass. The stem must preserve the original
/// audio's timeline so onsets line up with the source recording. Quality and
/// method metadata are surfaced so diagnostics can explain why output looks
/// the way it does.
public struct SeparationResult: Sendable, Equatable {
    /// File URL of the isolated piano stem (mono float32 44.1 kHz preferred).
    public let stemURL: URL
    /// Human-readable name of the separation method used (e.g. "Demucs v4",
    /// "Spleeter 2-stems"). Surfaced in diagnostics and run metadata.
    public let methodName: String
    /// Optional quality/confidence score in [0, 1]. nil when the separator
    /// can't self-rate the result.
    public let qualityScore: Double?
    /// Duration of the produced stem, in seconds. Compared against the
    /// original audio duration to flag misaligned output.
    public let stemDurationSeconds: Double
    /// Free-form metadata persisted alongside the run (model version,
    /// device, sample rate, etc.).
    public let parameters: [String: String]

    public init(
        stemURL: URL,
        methodName: String,
        qualityScore: Double? = nil,
        stemDurationSeconds: Double,
        parameters: [String: String] = [:]
    ) {
        self.stemURL = stemURL
        self.methodName = methodName
        self.qualityScore = qualityScore
        self.stemDurationSeconds = stemDurationSeconds
        self.parameters = parameters
    }
}

/// Generic source-separation stage. Implementations isolate a single
/// instrument stem (piano, in this app's case) from a mixed audio file
/// while preserving the source's timeline.
///
/// `SourceSeparator` is the richer interface used by the precision pipeline.
/// The older `PianoStemSeparator` remains for the simpler isolation pipeline
/// — both protocols can coexist while concrete implementations land.
public protocol SourceSeparator: Sendable {
    /// Display name used in diagnostics + run metadata.
    var name: String { get }
    /// Whether this separator can run on the current host. Used by the
    /// pipeline registry to decide if the precision pipeline should be
    /// surfaced as available.
    var isAvailable: Bool { get }
    /// When `isAvailable` is false, an explanation the UI can show.
    var unavailableReason: String? { get }

    /// Produce the isolated stem. Must throw `PipelineError.unavailable` (or
    /// equivalent) if the dependency is missing — never write a fake stem.
    func separate(
        audioURL: URL,
        outputDirectory: URL,
        progress: PipelineProgressHandler?
    ) async throws -> SeparationResult
}

/// Stub separator that always reports unavailable. Used as the registry's
/// default plug-in so the precision pipeline can declare itself disabled
/// cleanly until a real separator (Demucs, Spleeter, OpenUnmix CoreML …)
/// is wired in.
public struct UnavailableSourceSeparator: SourceSeparator {
    public let name = "None"
    public let isAvailable = false
    public let unavailableReason: String? = "No source separator is installed. Add a Demucs/Spleeter/OpenUnmix backend to enable piano isolation."

    public init() {}

    public func separate(
        audioURL: URL,
        outputDirectory: URL,
        progress: PipelineProgressHandler?
    ) async throws -> SeparationResult {
        throw PipelineError.unavailable(reason: unavailableReason ?? "Source separator unavailable.")
    }
}
