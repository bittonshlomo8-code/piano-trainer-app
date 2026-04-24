import Foundation
import AVFoundation

/// Lightweight, side-effect-safe verification of the pieces the pipeline depends on.
public enum PipelineDiagnostics {
    public static func run(
        project: Project,
        store: ProjectStore,
        runner: any ModelRunner
    ) async -> DiagnosticsReport {
        let start = Date()
        var checks: [DiagnosticsCheck] = []
        checks.append(checkProjectJSON(project: project))
        checks.append(checkWAVAccessible(audioURL: project.audioFileURL))
        checks.append(checkMIDIGeneration())
        checks.append(checkRunnerAvailable(runner: runner))
        _ = store  // reserved for future store-level checks
        let elapsed = Date().timeIntervalSince(start)
        return DiagnosticsReport(checks: checks, runAt: start, durationSeconds: elapsed)
    }

    static func checkProjectJSON(project: Project) -> DiagnosticsCheck {
        let name = "Project JSON save/load"
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptk_diag_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        do {
            let tempStore = ProjectStore(rootDirectory: tempRoot)
            try tempStore.save(project)
            let loaded = try tempStore.loadAll()
            guard let round = loaded.first(where: { $0.id == project.id }) else {
                return DiagnosticsCheck(name: name, passed: false, detail: "Project not found after load")
            }
            guard round.audioFileURL == project.audioFileURL else {
                return DiagnosticsCheck(name: name, passed: false, detail: "Audio URL mismatch after round-trip")
            }
            return DiagnosticsCheck(name: name, passed: true, detail: "Round-trip OK (\(round.runs.count) run\(round.runs.count == 1 ? "" : "s"))")
        } catch {
            return DiagnosticsCheck(name: name, passed: false, detail: error.localizedDescription)
        }
    }

    static func checkWAVAccessible(audioURL: URL) -> DiagnosticsCheck {
        let name = "Extracted WAV accessible"
        let fm = FileManager.default
        guard fm.fileExists(atPath: audioURL.path) else {
            return DiagnosticsCheck(name: name, passed: false, detail: "File not found: \(audioURL.lastPathComponent)")
        }
        guard fm.isReadableFile(atPath: audioURL.path) else {
            return DiagnosticsCheck(name: name, passed: false, detail: "File not readable: \(audioURL.lastPathComponent)")
        }
        do {
            let file = try AVAudioFile(forReading: audioURL)
            let frames = file.length
            let sr = file.fileFormat.sampleRate
            let seconds = sr > 0 ? Double(frames) / sr : 0
            let formatted = String(format: "%.2fs @ %.0f Hz", seconds, sr)
            return DiagnosticsCheck(name: name, passed: true, detail: formatted)
        } catch {
            return DiagnosticsCheck(name: name, passed: false, detail: "AVAudioFile: \(error.localizedDescription)")
        }
    }

    static func checkMIDIGeneration() -> DiagnosticsCheck {
        let name = "MIDI generation"
        let sample = [
            MIDINote(pitch: 60, onset: 0.0, duration: 0.5, velocity: 80),
            MIDINote(pitch: 64, onset: 0.5, duration: 0.5, velocity: 70),
            MIDINote(pitch: 67, onset: 1.0, duration: 0.5, velocity: 90),
        ]
        let data = MIDIGenerator().generateMIDI(from: sample)
        let header = [UInt8](data.prefix(4))
        guard header == [0x4D, 0x54, 0x68, 0x64] else {
            return DiagnosticsCheck(name: name, passed: false, detail: "Invalid SMF header")
        }
        return DiagnosticsCheck(name: name, passed: true, detail: "\(data.count) bytes, valid SMF")
    }

    static func checkRunnerAvailable(runner: any ModelRunner) -> DiagnosticsCheck {
        let name = "Model runner available"
        let runnerName = runner.name
        guard !runnerName.isEmpty else {
            return DiagnosticsCheck(name: name, passed: false, detail: "Runner has no name")
        }
        return DiagnosticsCheck(name: name, passed: true, detail: runnerName)
    }
}
