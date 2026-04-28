import Foundation

/// Adapter that drives Demucs (`python -m demucs` or the `demucs` console
/// script) to produce a piano-focused stem from a mixed audio recording.
///
/// Demucs is the de-facto open-weights source separator for music; the
/// `mdx_extra` / `htdemucs_ft` checkpoints distinguish vocals/drums/bass/other,
/// where "other" tends to capture piano + harmonic instruments. We invoke it
/// in two-stems mode (`--two-stems=other`) which yields exactly two outputs:
///   • `<basename>/other.wav`        ← what we want (piano-leaning stem)
///   • `<basename>/no_other.wav`     ← drums/bass/vocals — discarded
///
/// Availability is gated on the `demucs` binary being on PATH (or
/// `DEMUCS_PATH` overriding it). When the binary is missing,
/// `isAvailable == false` so the registry can keep `Mixed Audio / Piano
/// Isolation` honest about whether real separation can run today.
public final class DemucsSourceSeparator: PianoStemSeparator, SourceSeparator, @unchecked Sendable {

    public static let envOverride = "DEMUCS_PATH"
    public static let executableName = "demucs"

    public let name: String = "Demucs (htdemucs)"

    /// Demucs model checkpoint passed as `-n <model>`. Default `htdemucs`
    /// is a good general-purpose choice; for piano-heavy material
    /// `htdemucs_ft` (fine-tuned) is sometimes better. The user can
    /// override via `DEMUCS_MODEL`.
    public var model: String {
        ProcessInfo.processInfo.environment["DEMUCS_MODEL"] ?? "htdemucs"
    }

    /// Two-stems target. We pull "other" because piano is grouped there in
    /// htdemucs's training. For HIFI-GAN-flavored variants the user can
    /// override via `DEMUCS_STEM`.
    public var stem: String {
        ProcessInfo.processInfo.environment["DEMUCS_STEM"] ?? "other"
    }

    public var isAvailable: Bool { resolvedExecutable != nil }

    public var unavailableReason: String? {
        guard !isAvailable else { return nil }
        return """
        Demucs not found. Install with `pip install demucs` and ensure the \
        `\(Self.executableName)` script is on PATH, or set \(Self.envOverride) \
        to its full path.
        """
    }

    public init() {}

    private var resolvedExecutable: URL? {
        ExternalCommandRunner.locate(executable: Self.executableName, envOverride: Self.envOverride)
    }

    // MARK: - PianoStemSeparator (simpler protocol used by MixedAudioPianoIsolationPipeline)

    public func separate(
        audioURL: URL,
        outputDirectory: URL,
        progress: PipelineProgressHandler?
    ) async throws -> URL {
        let result = try await separateInternal(
            audioURL: audioURL,
            outputDirectory: outputDirectory,
            progress: progress
        )
        return result.stemURL
    }

    // MARK: - SourceSeparator (richer protocol used by MixedInstrumentPianoPrecisionPipeline)

    public func separate(
        audioURL: URL,
        outputDirectory: URL,
        progress: PipelineProgressHandler?
    ) async throws -> SeparationResult {
        try await separateInternal(audioURL: audioURL, outputDirectory: outputDirectory, progress: progress)
    }

    // MARK: - Implementation

    private func separateInternal(
        audioURL: URL,
        outputDirectory: URL,
        progress: PipelineProgressHandler?
    ) async throws -> SeparationResult {
        guard let exe = resolvedExecutable else {
            throw PipelineError.unavailable(reason: unavailableReason ?? "Demucs unavailable.")
        }

        progress?(PipelineProgress(stage: .loading, fraction: 0.10, detail: "running demucs"))

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let model = self.model
        let stem = self.stem
        let stemRoot = outputDirectory.appendingPathComponent("demucs_\(UUID().uuidString.prefix(6))")

        let result: ExternalCommandRunner.Result = try await Task.detached(priority: .userInitiated) {
            try ExternalCommandRunner.run(
                executable: exe,
                arguments: [
                    "-n", model,
                    "--two-stems=\(stem)",
                    "-o", stemRoot.path,
                    audioURL.path,
                ],
                displayName: Self.executableName
            )
        }.value

        progress?(PipelineProgress(stage: .detecting, fraction: 0.85, detail: "locating stem"))

        // Demucs writes to:  <stemRoot>/<model>/<basename-without-ext>/{stem,no_stem}.wav
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        let stemDir = stemRoot.appendingPathComponent(model).appendingPathComponent(baseName)
        let stemURL = stemDir.appendingPathComponent("\(stem).wav")

        guard FileManager.default.fileExists(atPath: stemURL.path) else {
            // Fall back: the layout has shifted across Demucs versions; pick
            // the largest .wav in the output tree as a heuristic.
            let candidate = largestWAV(in: stemRoot)
            guard let resolved = candidate else {
                throw PipelineError.unavailable(
                    reason: "Demucs exited \(result.exitStatus) but no stem found under \(stemRoot.path). stderr tail: \(result.stderr.suffix(280))"
                )
            }
            return makeResult(stemURL: resolved, model: model, stem: stem, stderr: result.stderr)
        }

        return makeResult(stemURL: stemURL, model: model, stem: stem, stderr: result.stderr)
    }

    private func makeResult(stemURL: URL, model: String, stem: String, stderr: String) -> SeparationResult {
        let stemDuration = AudioDurationProbe.durationSeconds(of: stemURL) ?? 0
        var params: [String: String] = [
            "demucs.model": model,
            "demucs.stem": stem,
            "demucs.executable": resolvedExecutable?.path ?? "(unknown)",
        ]
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            params["demucs.stderr.tail"] = String(trimmed.suffix(280))
        }
        return SeparationResult(
            stemURL: stemURL,
            methodName: name,
            qualityScore: nil,
            stemDurationSeconds: stemDuration,
            parameters: params
        )
    }

    private func largestWAV(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var best: (URL, Int) = (root, -1)
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "wav" else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > best.1 { best = (url, size) }
        }
        return best.1 > 0 ? best.0 : nil
    }
}
