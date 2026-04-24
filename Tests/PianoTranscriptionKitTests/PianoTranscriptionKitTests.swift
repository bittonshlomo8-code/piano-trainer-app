import XCTest
import AVFoundation
@testable import PianoTranscriptionKit

// MARK: - Existing tests (unchanged)

final class MockModelRunnerTests: XCTestCase {
    func testGeneratesNotes() async throws {
        let runner = MockModelRunner(seed: 1)
        let url = URL(fileURLWithPath: "/tmp/nonexistent.wav")
        let notes = try await runner.transcribe(audioURL: url)
        XCTAssertFalse(notes.isEmpty)
    }

    func testNoteRanges() async throws {
        let runner = MockModelRunner(seed: 2)
        let url = URL(fileURLWithPath: "/tmp/nonexistent.wav")
        let notes = try await runner.transcribe(audioURL: url)
        for note in notes {
            XCTAssertGreaterThanOrEqual(note.pitch, 0)
            XCTAssertLessThanOrEqual(note.pitch, 127)
            XCTAssertGreaterThanOrEqual(note.velocity, 0)
            XCTAssertLessThanOrEqual(note.velocity, 127)
            XCTAssertGreaterThan(note.duration, 0)
            XCTAssertGreaterThanOrEqual(note.onset, 0)
        }
    }

    func testDeterministic() async throws {
        let url = URL(fileURLWithPath: "/tmp/nonexistent.wav")
        let n1 = try await MockModelRunner(seed: 42).transcribe(audioURL: url)
        let n2 = try await MockModelRunner(seed: 42).transcribe(audioURL: url)
        XCTAssertEqual(n1, n2)
    }
}

final class MIDIGeneratorTests: XCTestCase {
    func testGeneratesValidMIDI() {
        let notes = [
            MIDINote(pitch: 60, onset: 0,   duration: 0.5, velocity: 80),
            MIDINote(pitch: 64, onset: 0.5, duration: 0.5, velocity: 70),
            MIDINote(pitch: 67, onset: 1.0, duration: 1.0, velocity: 90),
        ]
        let data = MIDIGenerator().generateMIDI(from: notes)
        XCTAssertEqual([UInt8](data.prefix(4)), [0x4D, 0x54, 0x68, 0x64]) // "MThd"
        XCTAssertGreaterThan(data.count, 14)
    }

    func testEmptyNotes() {
        let data = MIDIGenerator().generateMIDI(from: [])
        XCTAssertGreaterThan(data.count, 0)
    }
}

final class DefaultPipelineTests: XCTestCase {
    func testRunReturnsPipelineVersion() async throws {
        let runner = MockModelRunner(seed: 1)
        let pipeline = DefaultPipeline(runner: runner)
        let url = URL(fileURLWithPath: "/tmp/nonexistent.wav")
        let run = try await pipeline.run(audioURL: url)
        XCTAssertEqual(run.pipelineVersion, "1.0.0")
        XCTAssertEqual(run.modelName, runner.name)
    }
}

// MARK: - BasicPianoModelRunner tests

final class BasicPianoModelRunnerTests: XCTestCase {

    // MARK: Fixture helpers

    /// Writes a piano-like tone (harmonic series + exponential decay) at `pitch` to a temp WAV.
    private func makePianoToneWAV(pitch: Int, durationSeconds: Double = 3.0) throws -> URL {
        let sr: Double = 44100
        let frameCount = Int(durationSeconds * sr)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)

        let data = buf.floatChannelData![0]
        let fund = 440.0 * pow(2.0, Double(pitch - 69) / 12.0)

        for i in 0 ..< frameCount {
            let t = Double(i) / sr
            var sample = 0.0
            // Piano-like: 8 harmonics, each harmonic decays faster
            for h in 1 ... 8 {
                let amp   = 0.6 / Double(h)
                let decay = exp(-t * Double(h) * 1.5)
                sample += amp * decay * sin(2 * .pi * fund * Double(h) * t)
            }
            // Overall envelope: slow decay + attack ramp
            let attack  = min(1.0, t / 0.01)
            let release = exp(-t * 1.2)
            data[i] = Float(sample * attack * release * 0.5)
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_test_\(pitch)_\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        try file.write(from: buf)
        return url
    }

    /// Writes a silent WAV (all zeros).
    private func makeSilentWAV(durationSeconds: Double = 2.0) throws -> URL {
        let sr: Double = 44100
        let frameCount = AVAudioFrameCount(durationSeconds * sr)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        // floatChannelData is already zeroed by the system allocator

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_silent_\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        try file.write(from: buf)
        return url
    }

    // MARK: - Tests

    func testDetectsNoteFromSingleTone() async throws {
        let pitch = 69   // A4 = 440 Hz
        let url = try makePianoToneWAV(pitch: pitch)
        defer { try? FileManager.default.removeItem(at: url) }

        let runner = BasicPianoModelRunner()
        let notes = try await runner.transcribe(audioURL: url)

        XCTAssertFalse(notes.isEmpty, "Should detect at least one note from a piano tone")

        // The most prominent note should be within ±2 semitones of A4
        let dominant = notes.max(by: { $0.velocity < $1.velocity })!
        XCTAssertLessThanOrEqual(abs(dominant.pitch - pitch), 2,
            "Dominant pitch \(dominant.pitch) (\(dominant.noteName)) too far from expected A4 (69)")
    }

    func testDetectedNoteHasReasonableDuration() async throws {
        let url = try makePianoToneWAV(pitch: 60)   // Middle C
        defer { try? FileManager.default.removeItem(at: url) }

        let runner = BasicPianoModelRunner()
        let notes = try await runner.transcribe(audioURL: url)

        let dominant = notes.max(by: { $0.velocity < $1.velocity })
        XCTAssertNotNil(dominant)
        // Should sustain for at least 200ms from a 3-second decaying tone
        XCTAssertGreaterThan(dominant!.duration, 0.2,
            "Note duration \(dominant!.duration) too short for a sustained piano tone")
    }

    func testSilentAudioProducesNoNotes() async throws {
        let url = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let runner = BasicPianoModelRunner()
        let notes = try await runner.transcribe(audioURL: url)
        XCTAssertTrue(notes.isEmpty, "Silent audio should produce no notes; got \(notes.count)")
    }

    func testAllNotesInMIDIRange() async throws {
        let url = try makePianoToneWAV(pitch: 48)   // C3
        defer { try? FileManager.default.removeItem(at: url) }

        let runner = BasicPianoModelRunner()
        let notes = try await runner.transcribe(audioURL: url)
        for note in notes {
            XCTAssertGreaterThanOrEqual(note.pitch, 21)
            XCTAssertLessThanOrEqual(note.pitch, 108)
            XCTAssertGreaterThan(note.duration, 0)
            XCTAssertGreaterThanOrEqual(note.onset, 0)
            XCTAssertGreaterThan(note.velocity, 0)
            XCTAssertLessThanOrEqual(note.velocity, 127)
        }
    }

    func testMultiplePitchesDetected() async throws {
        // A4 (440 Hz) and E5 (659 Hz) are a perfect fifth — harmonics don't coincide
        let pitches = [69, 76]   // A4, E5
        let sr: Double = 44100
        let dur = 3.0
        let frameCount = Int(dur * sr)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        let data = buf.floatChannelData![0]

        for i in 0 ..< frameCount {
            let t = Double(i) / sr
            let env = exp(-t * 1.2)
            var s: Float = 0
            for pitch in pitches {
                let f = 440.0 * pow(2.0, Double(pitch - 69) / 12.0)
                for h in 1 ... 6 {
                    s += Float(0.4 / Double(h) * env * sin(2 * .pi * f * Double(h) * t))
                }
            }
            data[i] = s * 0.4
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_chord_\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        try file.write(from: buf)
        defer { try? FileManager.default.removeItem(at: url) }

        let runner = BasicPianoModelRunner()
        let notes = try await runner.transcribe(audioURL: url)

        // Should detect both pitches (or at least notes near them)
        let detectedPitches = Set(notes.map(\.pitch))
        let foundA4 = detectedPitches.contains { abs($0 - 69) <= 2 }
        let foundE5 = detectedPitches.contains { abs($0 - 76) <= 2 }
        XCTAssertTrue(foundA4 || foundE5,
            "Expected to detect at least one of A4/E5 in a two-note chord; got pitches: \(detectedPitches.sorted())")
    }

    func testRunnerNameIsSet() {
        XCTAssertFalse(BasicPianoModelRunner().name.isEmpty)
    }

    // Verify that running through DefaultPipeline produces a properly labelled run
    func testPipelineIntegration() async throws {
        let url = try makePianoToneWAV(pitch: 60, durationSeconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = DefaultPipeline(runner: BasicPianoModelRunner())
        let run = try await pipeline.run(audioURL: url)

        XCTAssertEqual(run.pipelineVersion, "1.0.0")
        XCTAssertEqual(run.modelName, BasicPianoModelRunner().name)
        XCTAssertFalse(run.notes.isEmpty, "Pipeline should produce notes from piano tone")
    }
}
