import Foundation

/// Adapter that drives Spotify's Basic Pitch CLI (`basic-pitch`).
///
/// Basic Pitch is a polyphonic piano + general-instrument transcription model
/// that runs on raw mixed audio and produces a Standard MIDI File. The
/// adapter shells out to the CLI, then parses the resulting MIDI back into
/// `MIDINote`s via `MIDIReader`.
///
/// Availability is gated on the CLI being on PATH. Set
/// `BASIC_PITCH_PATH=/full/path/to/basic-pitch` to override discovery.
/// When the binary is missing, `isAvailable == false` with a clear install
/// hint so the registry can surface the pipeline as disabled instead of
/// pretending to run.
public final class BasicPitchTranscriber: PianoSpecializedTranscriber, @unchecked Sendable {

    public static let envOverride = "BASIC_PITCH_PATH"
    /// Repo-local wrapper produced by `scripts/setup-transcription-deps.sh`.
    /// Resolves before the bare `basic-pitch` binary so the in-repo venv is
    /// always preferred over a global install.
    public static let executableName = "basic-pitch-wrapper"

    public let modelName: String = "Basic Pitch (Spotify)"
    public let modelVersion: String = "0.x"

    public var parameters: [String: String] {
        [
            "executable": resolvedExecutable?.path ?? "(missing)",
            "envOverride": Self.envOverride,
        ]
    }

    public var isAvailable: Bool { resolvedExecutable != nil }

    public var unavailableReason: String? {
        guard !isAvailable else { return nil }
        return "Basic Pitch wrapper not installed. Run `bash scripts/setup-transcription-deps.sh` to install Basic Pitch and write the wrapper."
    }

    public init() {}

    private var resolvedExecutable: URL? {
        let status = TranscriptionBackendRegistry.shared.resolve(.basicPitch)
        return status.resolvedPath.map { URL(fileURLWithPath: $0) }
    }

    public func transcribePiano(audioURL: URL, progress: PipelineProgressHandler?) async throws -> PianoTranscriptionResult {
        guard let exe = resolvedExecutable else {
            throw PipelineError.unavailable(reason: unavailableReason ?? "Basic Pitch unavailable.")
        }

        progress?(PipelineProgress(stage: .analyzing, fraction: 0.10, detail: "running basic-pitch"))

        // basic-pitch CLI signature: `basic-pitch <output_dir> <input_audio> [...flags]`.
        // We give it a fresh temp dir so we can predict the output filename
        // without colliding with prior runs.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_basicpitch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // The wrapper hardcodes `--save-midi --model-serialization onnx`
        // and takes positional `<input> <output_dir>`. This matches the
        // shape every other transcription wrapper produced by
        // setup-transcription-deps.sh uses.
        let result: ExternalCommandRunner.Result = try await Task.detached(priority: .userInitiated) {
            try ExternalCommandRunner.run(
                executable: exe,
                arguments: [audioURL.path, tmpDir.path],
                displayName: Self.executableName
            )
        }.value

        progress?(PipelineProgress(stage: .detecting, fraction: 0.85, detail: "parsing MIDI"))

        // Output is `<basename>_basic_pitch.mid` inside the temp dir.
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        let candidate = tmpDir.appendingPathComponent("\(baseName)_basic_pitch.mid")
        let midiURL: URL
        if FileManager.default.fileExists(atPath: candidate.path) {
            midiURL = candidate
        } else {
            // Fall back to "first .mid in temp dir" — the CLI's naming has
            // varied across versions so this keeps us forward-compatible.
            let contents = (try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)) ?? []
            guard let mid = contents.first(where: { $0.pathExtension.lowercased() == "mid" }) else {
                throw PipelineError.unavailable(
                    reason: "Basic Pitch produced no MIDI file in \(tmpDir.path). stderr: \(result.stderr)"
                )
            }
            midiURL = mid
        }

        let notes = try MIDIReader.read(url: midiURL)

        var params = parameters
        params["midi.notesParsed"] = "\(notes.count)"
        params["midi.outputFile"] = midiURL.lastPathComponent
        let trimmedStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStderr.isEmpty {
            params["stderr.tail"] = String(trimmedStderr.suffix(280))
        }

        return PianoTranscriptionResult(
            notes: notes,
            modelName: modelName,
            modelVersion: modelVersion,
            sampleRate: 22050, // Basic Pitch's internal sample rate
            parameters: params,
            isFallback: false
        )
    }
}
