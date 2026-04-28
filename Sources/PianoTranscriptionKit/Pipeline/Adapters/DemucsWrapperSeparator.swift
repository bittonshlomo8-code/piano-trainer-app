import Foundation
import AVFoundation

/// Source-separator that drives the repo-local `demucs-wrapper` script.
/// Splits the input into htdemucs two-stems "other" / "no_other" and
/// returns the path of **`other.wav`** — the piano-like residual after
/// drums, bass, and vocals are stripped.
///
/// Important: `--two-stems other` in htdemucs writes
///   `other.wav`     = the "other" (piano-like) stem
///   `no_other.wav`  = drums + bass + vocals (everything we want stripped)
/// We pick `other.wav`. The earlier draft picked `no_other.wav` by mistake,
/// which sent the drums+bass+vocals signal into the piano transcriber and
/// produced the catastrophic note clouds the user reported.
///
/// Conforms to BOTH `SourceSeparator` (used by the modern Mixed
/// Instruments / Advanced pipeline) and `PianoStemSeparator` (used by the
/// older Mixed Audio pipeline). Single class, single subprocess.
public final class DemucsWrapperSeparator: SourceSeparator, PianoStemSeparator, @unchecked Sendable {

    public static let envOverride = "DEMUCS_PATH"
    public static let executableName = "demucs-wrapper"

    public let name: String = "Demucs (htdemucs · two-stems other)"

    public var isAvailable: Bool { resolvedExecutable != nil }
    public var unavailableReason: String? {
        guard !isAvailable else { return nil }
        return "Demucs wrapper not installed. Run `bash scripts/setup-transcription-deps.sh` to install Demucs and write the wrapper."
    }

    public init() {}

    private var resolvedExecutable: URL? {
        let status = TranscriptionBackendRegistry.shared.resolve(.demucs)
        return status.resolvedPath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - SourceSeparator

    public func separate(
        audioURL: URL,
        outputDirectory: URL,
        progress: PipelineProgressHandler?
    ) async throws -> SeparationResult {
        let stemURL = try await runDemucs(
            audioURL: audioURL,
            outputDirectory: outputDirectory,
            progress: progress
        )
        let dur = AudioDurationProbe.durationSeconds(of: stemURL) ?? 0
        return SeparationResult(
            stemURL: stemURL,
            methodName: name,
            qualityScore: nil,
            stemDurationSeconds: dur,
            parameters: [
                "model": "htdemucs",
                "stems": "other",
                "selectedStem": "other.wav"
            ]
        )
    }

    // MARK: - PianoStemSeparator

    public func separate(
        audioURL: URL,
        outputDirectory: URL,
        progress: PipelineProgressHandler?
    ) async throws -> URL {
        try await runDemucs(audioURL: audioURL, outputDirectory: outputDirectory, progress: progress)
    }

    // MARK: - Private

    /// Invokes the `demucs-wrapper` script and returns the path of the
    /// piano-isolated stem (`no_other.wav`). Throws `PipelineError.unavailable`
    /// if the wrapper is missing, `CommandError.nonZeroExit` if Demucs fails.
    private func runDemucs(
        audioURL: URL,
        outputDirectory: URL,
        progress: PipelineProgressHandler?
    ) async throws -> URL {
        guard let exe = resolvedExecutable else {
            throw PipelineError.unavailable(reason: unavailableReason ?? "Demucs unavailable.")
        }
        progress?(PipelineProgress(stage: .loading, fraction: 0.05, detail: "isolating piano stem"))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let result: ExternalCommandRunner.Result = try await Task.detached(priority: .userInitiated) {
            try ExternalCommandRunner.run(
                executable: exe,
                arguments: [audioURL.path, outputDirectory.path],
                displayName: Self.executableName
            )
        }.value

        // htdemucs writes <output>/<model>/<basename>/{other,no_other}.wav.
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        let primary = outputDirectory
            .appendingPathComponent("htdemucs")
            .appendingPathComponent(baseName)
            .appendingPathComponent("other.wav")
        if FileManager.default.fileExists(atPath: primary.path) {
            return primary
        }
        // Recursively search for `other.wav` anywhere under the output
        // directory — different htdemucs versions occasionally tweak the
        // folder layout. Per spec, this is the canonical stem name.
        if let alt = try? findStem(named: "other.wav", in: outputDirectory) {
            return alt
        }
        throw PipelineError.unavailable(
            reason: "Demucs completed but no other.wav stem was found under \(outputDirectory.path). stderr: \(result.stderr)"
        )
    }

    private func findStem(named target: String, in dir: URL) throws -> URL {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        var best: (URL, Int)? = nil
        while let candidate = enumerator?.nextObject() as? URL {
            guard candidate.lastPathComponent == target else { continue }
            let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if best == nil || size > best!.1 {
                best = (candidate, size)
            }
        }
        guard let chosen = best else {
            throw PipelineError.unavailable(reason: "No \(target) found under \(dir.path)")
        }
        return chosen.0
    }
}
