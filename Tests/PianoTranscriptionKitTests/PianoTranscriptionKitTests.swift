import XCTest
@testable import PianoTranscriptionKit

final class MockModelRunnerTests: XCTestCase {
    func testGeneratesNotes() async throws {
        let runner = MockModelRunner(seed: 1)
        // Use a temp WAV that does not actually exist — duration fallback kicks in
        let url = URL(fileURLWithPath: "/tmp/nonexistent.wav")
        let notes = try await runner.transcribe(audioURL: url)
        XCTAssertFalse(notes.isEmpty, "Mock runner should return notes")
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
        let notes1 = try await MockModelRunner(seed: 42).transcribe(audioURL: url)
        let notes2 = try await MockModelRunner(seed: 42).transcribe(audioURL: url)
        XCTAssertEqual(notes1, notes2)
    }
}

final class MIDIGeneratorTests: XCTestCase {
    func testGeneratesValidMIDI() {
        let notes = [
            MIDINote(pitch: 60, onset: 0, duration: 0.5, velocity: 80),
            MIDINote(pitch: 64, onset: 0.5, duration: 0.5, velocity: 70),
            MIDINote(pitch: 67, onset: 1.0, duration: 1.0, velocity: 90),
        ]
        let gen = MIDIGenerator()
        let data = gen.generateMIDI(from: notes)

        // Check MIDI header magic bytes
        let header = [UInt8](data.prefix(4))
        XCTAssertEqual(header, [0x4D, 0x54, 0x68, 0x64]) // "MThd"
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
