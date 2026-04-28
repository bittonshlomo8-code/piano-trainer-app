import Foundation

/// Adapter for Qiuqiang Kong's high-fidelity piano transcription system
/// (commonly referred to as "ByteDance Piano Transcription"). The reference
/// implementation is a Python module — this adapter expects the user to
/// install a thin wrapper script that takes
///   `wrapper <input_audio> <output_midi>`
/// and exits with status 0 on success.
///
/// Set `PIANO_TRANSCRIPTION_PATH=/full/path/to/wrapper` to point the adapter
/// at your installation. Until that variable is set or a `piano-transcription`
/// binary is on PATH, the adapter reports unavailable with explicit
/// instructions — the registry then disables the matching pipeline so the
/// user never gets fake output.
public final class ByteDancePianoTranscriber: PianoSpecializedTranscriber, @unchecked Sendable {

    public static let envOverride = "PIANO_TRANSCRIPTION_PATH"
    /// Repo-local wrapper produced by `scripts/setup-transcription-deps.sh`.
    public static let executableName = "piano-transcription-wrapper"

    public let modelName: String = "ByteDance Piano Transcription"
    public let modelVersion: String = "v0.0.6 / Kong et al."

    public var parameters: [String: String] {
        [
            "executable": resolvedExecutable?.path ?? "(missing)",
            "envOverride": Self.envOverride,
        ]
    }

    public var isAvailable: Bool { resolvedExecutable != nil }

    public var unavailableReason: String? {
        guard !isAvailable else { return nil }
        return "ByteDance Piano Transcription wrapper not installed. Run `bash scripts/setup-transcription-deps.sh` to install the model and write the wrapper."
    }

    public init() {}

    private var resolvedExecutable: URL? {
        let status = TranscriptionBackendRegistry.shared.resolve(.byteDance)
        return status.resolvedPath.map { URL(fileURLWithPath: $0) }
    }

    public func transcribePiano(audioURL: URL, progress: PipelineProgressHandler?) async throws -> PianoTranscriptionResult {
        guard let exe = resolvedExecutable else {
            throw PipelineError.unavailable(reason: unavailableReason ?? "ByteDance Piano Transcription unavailable.")
        }

        progress?(PipelineProgress(stage: .analyzing, fraction: 0.10, detail: "running ByteDance model"))

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_bytedance_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outputMIDI = tmpDir.appendingPathComponent("output.mid")
        let result: ExternalCommandRunner.Result = try await Task.detached(priority: .userInitiated) {
            try ExternalCommandRunner.run(
                executable: exe,
                arguments: [audioURL.path, outputMIDI.path],
                displayName: Self.executableName
            )
        }.value

        progress?(PipelineProgress(stage: .detecting, fraction: 0.85, detail: "parsing MIDI"))

        guard FileManager.default.fileExists(atPath: outputMIDI.path) else {
            throw PipelineError.unavailable(
                reason: "ByteDance wrapper exited \(result.exitStatus) but produced no MIDI at \(outputMIDI.path). stderr: \(result.stderr)"
            )
        }
        let notes = try MIDIReader.read(url: outputMIDI)

        var params = parameters
        params["midi.notesParsed"] = "\(notes.count)"
        let trimmedStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStderr.isEmpty {
            params["stderr.tail"] = String(trimmedStderr.suffix(280))
        }

        return PianoTranscriptionResult(
            notes: notes,
            modelName: modelName,
            modelVersion: modelVersion,
            sampleRate: 16000, // ByteDance's internal sample rate
            parameters: params,
            isFallback: false
        )
    }
}
