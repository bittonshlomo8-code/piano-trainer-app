import Foundation

/// Pluggable interface for isolating a piano stem from a mixed audio file.
public protocol PianoStemSeparator: Sendable {
    /// Display name shown in run history.
    var name: String { get }
    /// True when this separator can run on the current host. Mixed Audio
    /// pipelines refuse to run when this is false — they will not silently
    /// fall back to running the model on raw mixed audio.
    var isAvailable: Bool { get }
    /// Operator-facing reason when `isAvailable` is false.
    var unavailableReason: String? { get }
    /// Separates the piano stem from `audioURL`, writing the isolated stem
    /// into `outputDirectory` and returning its file URL. The stem must
    /// preserve the original timeline so downstream onsets line up with the
    /// source recording.
    func separate(
        audioURL: URL,
        outputDirectory: URL,
        progress: PipelineProgressHandler?
    ) async throws -> URL
}

public extension PianoStemSeparator {
    var isAvailable: Bool { true }
    var unavailableReason: String? { nil }
}

/// "Mixed Audio / Piano Isolation" pipeline — isolates a piano stem first,
/// then runs the configured piano transcriber on the **stem** (never the
/// mixed audio). When the separator is unavailable the pipeline throws
/// `PipelineError.unavailable` instead of silently falling back to
/// Piano-Focused on the raw mixed input — that fallback behavior was the
/// root cause of the catastrophic 1,835-note bytedance.midi output.
public final class MixedAudioPianoIsolationPipeline: TranscriptionPipeline, @unchecked Sendable {
    public let kind: PipelineKind = .mixedAudio
    public let version: String = "1.0.0"

    private let separator: PianoStemSeparator?
    private let stemOutputDirectory: URL?
    private let stemTranscriber: PianoSpecializedTranscriber
    private let cleanupConfig: TranscriptionCleanup.Config

    public var modelName: String {
        guard let separator else { return "Mixed Audio (separator missing)" }
        return "\(separator.name) → \(stemTranscriber.modelName)"
    }
    public var modelVersion: String? { stemTranscriber.modelVersion }
    public var parameters: [String: String] {
        var p: [String: String] = [
            "separator": separator?.name ?? "(none)",
            "transcriber": stemTranscriber.modelName,
            "transcriber.version": stemTranscriber.modelVersion,
        ]
        for (k, v) in stemTranscriber.parameters { p["transcriber.\(k)"] = v }
        for (k, v) in cleanupConfig.asParameters { p["cleanup.\(k)"] = v }
        return p
    }
    public var usesSourceSeparation: Bool { true }

    public init(
        separator: PianoStemSeparator? = nil,
        stemOutputDirectory: URL? = nil,
        stemTranscriber: PianoSpecializedTranscriber = FallbackPianoTranscriber(),
        cleanupConfig: TranscriptionCleanup.Config = .mixedAudio
    ) {
        self.separator = separator
        self.stemOutputDirectory = stemOutputDirectory
        self.stemTranscriber = stemTranscriber
        self.cleanupConfig = cleanupConfig
    }

    public func run(audioURL: URL, progress: PipelineProgressHandler?) async throws -> TranscriptionRun {
        guard let separator, separator.isAvailable else {
            let reason = separator?.unavailableReason
                ?? kind.unavailableReason
                ?? "Piano stem separator is not available — install Demucs (`pip install demucs`) to enable Mixed Audio / Piano Isolation."
            throw PipelineError.unavailable(reason: reason)
        }
        guard stemTranscriber.isAvailable else {
            throw PipelineError.unavailable(
                reason: stemTranscriber.unavailableReason
                    ?? "\(stemTranscriber.modelName) is not available; cannot transcribe isolated stem."
            )
        }

        let inputDuration = AudioDurationProbe.durationSeconds(of: audioURL)

        progress?(PipelineProgress(stage: .loading, fraction: 0.05, detail: "isolating piano stem"))
        let outputDir = stemOutputDirectory ?? audioURL.deletingLastPathComponent()
        let stemURL = try await separator.separate(
            audioURL: audioURL,
            outputDirectory: outputDir,
            progress: progress
        )
        let stemDuration = AudioDurationProbe.durationSeconds(of: stemURL)

        progress?(PipelineProgress(stage: .analyzing, fraction: 0.50, detail: "transcribing stem"))
        let result = try await stemTranscriber.transcribePiano(audioURL: stemURL, progress: progress)

        progress?(PipelineProgress(stage: .finalizing, fraction: 0.90, detail: "cleanup"))
        var cfg = cleanupConfig
        cfg.audioDurationSeconds = inputDuration ?? stemDuration

        var params = parameters
        params["dataflow.selectedMode"] = kind.rawValue
        params["dataflow.selectedModeDisplay"] = kind.displayName
        params["dataflow.actualSeparator"] = separator.name
        params["dataflow.actualTranscriber"] = result.modelName
        params["dataflow.transcriberFallback"] = result.isFallback ? "true" : "false"
        params["dataflow.fallback"] = "false"   // pipeline itself is real, not the FallbackTranscriptionPipeline
        params["dataflow.inputAudioPath"] = audioURL.path
        if let d = inputDuration { params["dataflow.inputAudioDuration"] = String(format: "%.2f", d) }
        params["dataflow.isolatedStemPath"] = stemURL.path
        if let d = stemDuration { params["dataflow.isolatedStemDuration"] = String(format: "%.2f", d) }
        params["dataflow.rawNoteCount"] = "\(result.notes.count)"
        params["backend.ran"] = "\(separator.name) → \(result.modelName)"
        params["backend.kind"] = "dedicated"
        params["backend.modelVersion"] = result.modelVersion
        for (k, v) in result.parameters { params["model.\(k)"] = v }

        let run = TranscriptionRun.makeWithMandatoryCleanup(
            rawModelNotes: result.notes,
            audioDurationSeconds: inputDuration ?? stemDuration,
            pipelineVersion: version,
            modelName: modelName,
            pipelineID: kind.rawValue,
            pipelineName: kind.displayName,
            modelVersion: modelVersion,
            pipelineParameters: params,
            usedSourceSeparation: true,
            inputAudioPath: audioURL.path,
            isolatedStemPath: stemURL.path,
            cleanupConfig: cfg
        )

        progress?(PipelineProgress(stage: .finalizing, fraction: 1.0,
                                   detail: "\(run.notes.count) notes (raw \(result.notes.count))"))
        return run
    }
}
