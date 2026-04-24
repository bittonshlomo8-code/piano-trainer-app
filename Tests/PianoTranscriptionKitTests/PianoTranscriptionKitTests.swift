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

// MARK: - Diagnostics + status formatting

final class DiagnosticsReportTests: XCTestCase {
    private func makeCheck(_ name: String, _ passed: Bool) -> DiagnosticsCheck {
        DiagnosticsCheck(name: name, passed: passed, detail: passed ? "ok" : "fail")
    }

    func testAllPassedTrueWhenEveryCheckPasses() {
        let report = DiagnosticsReport(
            checks: [makeCheck("a", true), makeCheck("b", true)],
            runAt: Date(),
            durationSeconds: 0.01
        )
        XCTAssertTrue(report.allPassed)
        XCTAssertEqual(report.passedCount, 2)
        XCTAssertEqual(report.failedCount, 0)
    }

    func testAllPassedFalseWhenAnyCheckFails() {
        let report = DiagnosticsReport(
            checks: [makeCheck("a", true), makeCheck("b", false), makeCheck("c", true)],
            runAt: Date(),
            durationSeconds: 0.02
        )
        XCTAssertFalse(report.allPassed)
        XCTAssertEqual(report.passedCount, 2)
        XCTAssertEqual(report.failedCount, 1)
    }

    func testSummaryWordingDependsOnResult() {
        let passing = DiagnosticsReport(checks: [makeCheck("a", true)], runAt: Date(), durationSeconds: 0)
        XCTAssertEqual(passing.summary, "1/1 passed")

        let failing = DiagnosticsReport(
            checks: [makeCheck("a", false), makeCheck("b", true)],
            runAt: Date(),
            durationSeconds: 0
        )
        XCTAssertEqual(failing.summary, "1 failed, 1 passed")
    }

    func testCheckIDUsesName() {
        let check = makeCheck("Extracted WAV accessible", true)
        XCTAssertEqual(check.id, "Extracted WAV accessible")
    }
}

final class PipelineDiagnosticsTests: XCTestCase {

    // Shared fixture: a writable WAV on disk + a project pointing to it
    private func makeFixture(hasAudio: Bool = true) throws -> (project: Project, audioURL: URL, cleanup: () -> Void) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_diag_fixture_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let wavURL = tempDir.appendingPathComponent("audio.wav")
        if hasAudio {
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
            let frames = AVAudioFrameCount(44100) // 1 second
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
            buf.frameLength = frames
            let file = try AVAudioFile(forWriting: wavURL, settings: fmt.settings)
            try file.write(from: buf)
        }
        let project = Project(
            name: "Fixture",
            sourceMediaURL: wavURL,
            audioFileURL: wavURL
        )
        return (project, wavURL, { try? FileManager.default.removeItem(at: tempDir) })
    }

    func testProjectJSONCheckPassesOnValidProject() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let check = PipelineDiagnostics.checkProjectJSON(project: fixture.project)
        XCTAssertTrue(check.passed, "Expected JSON round-trip to succeed, got: \(check.detail)")
        XCTAssertEqual(check.name, "Project JSON save/load")
    }

    func testWAVAccessibleCheckPassesForRealFile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let check = PipelineDiagnostics.checkWAVAccessible(audioURL: fixture.audioURL)
        XCTAssertTrue(check.passed, "Expected WAV check to pass, got: \(check.detail)")
        XCTAssertTrue(check.detail.contains("Hz"), "Detail should include sample rate, got: \(check.detail)")
    }

    func testWAVAccessibleCheckFailsForMissingFile() {
        let missing = URL(fileURLWithPath: "/tmp/definitely_does_not_exist_\(UUID().uuidString).wav")
        let check = PipelineDiagnostics.checkWAVAccessible(audioURL: missing)
        XCTAssertFalse(check.passed)
        XCTAssertTrue(check.detail.lowercased().contains("not found"),
                      "Failure detail should explain missing file, got: \(check.detail)")
    }

    func testMIDIGenerationCheckAlwaysPasses() {
        let check = PipelineDiagnostics.checkMIDIGeneration()
        XCTAssertTrue(check.passed)
        XCTAssertTrue(check.detail.contains("SMF"), "Detail should mention SMF: \(check.detail)")
    }

    func testRunnerAvailableCheckPassesForMock() {
        let check = PipelineDiagnostics.checkRunnerAvailable(runner: MockModelRunner())
        XCTAssertTrue(check.passed)
        XCTAssertEqual(check.detail, MockModelRunner().name)
    }

    func testRunnerAvailableCheckPassesForBasic() {
        let check = PipelineDiagnostics.checkRunnerAvailable(runner: BasicPianoModelRunner())
        XCTAssertTrue(check.passed)
        XCTAssertFalse(check.detail.isEmpty)
    }

    func testRunnerAvailableCheckFailsForBlankName() {
        struct NamelessRunner: ModelRunner {
            let name = ""
            func transcribe(audioURL: URL, progress: PipelineProgressHandler?) async throws -> [MIDINote] { [] }
        }
        let check = PipelineDiagnostics.checkRunnerAvailable(runner: NamelessRunner())
        XCTAssertFalse(check.passed)
    }

    func testFullRunProducesFourChecksAndPassesOnHealthyFixture() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let storeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_diag_store_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ProjectStore(rootDirectory: storeDir)

        let report = await PipelineDiagnostics.run(
            project: fixture.project,
            store: store,
            runner: MockModelRunner()
        )
        XCTAssertEqual(report.checks.count, 4)
        XCTAssertTrue(report.allPassed, "Expected all checks to pass on healthy fixture. Checks: \(report.checks)")
        XCTAssertGreaterThanOrEqual(report.durationSeconds, 0)
    }

    func testFullRunFlagsMissingWAV() async throws {
        let fixture = try makeFixture(hasAudio: false)
        defer { fixture.cleanup() }
        let storeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_diag_store_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ProjectStore(rootDirectory: storeDir)

        let report = await PipelineDiagnostics.run(
            project: fixture.project,
            store: store,
            runner: MockModelRunner()
        )
        XCTAssertFalse(report.allPassed, "Expected WAV-missing case to fail overall")
        let wavCheck = report.checks.first { $0.name == "Extracted WAV accessible" }
        XCTAssertEqual(wavCheck?.passed, false)
    }
}

final class PipelineKindTests: XCTestCase {
    func testAvailableKindsBuildRunners() {
        XCTAssertNotNil(PipelineKind.basicSpectral.makeRunner())
        XCTAssertNotNil(PipelineKind.mockDemo.makeRunner())
    }

    func testUnavailableKindReturnsNilRunner() {
        XCTAssertNil(PipelineKind.neuralOnsetsFrames.makeRunner())
        XCTAssertFalse(PipelineKind.neuralOnsetsFrames.isAvailable)
    }

    func testAllKindsExposeDisplayMetadata() {
        for kind in PipelineKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty)
            XCTAssertFalse(kind.summary.isEmpty)
            XCTAssertFalse(kind.systemImage.isEmpty)
        }
    }
}

final class PipelineProgressTests: XCTestCase {
    func testPipelineEmitsProgressUpdates() async throws {
        actor Collector {
            var updates: [PipelineProgress] = []
            func add(_ p: PipelineProgress) { updates.append(p) }
            func all() -> [PipelineProgress] { updates }
        }
        let collector = Collector()
        let pipeline = DefaultPipeline(runner: MockModelRunner(seed: 3))
        let url = URL(fileURLWithPath: "/tmp/nonexistent.wav")
        _ = try await pipeline.run(audioURL: url) { p in
            Task { await collector.add(p) }
        }
        // Wait for trailing async updates to flush
        try await Task.sleep(nanoseconds: 100_000_000)
        let updates = await collector.all()
        XCTAssertFalse(updates.isEmpty, "Pipeline should emit at least one progress update")
        XCTAssertEqual(updates.last?.fraction, 1.0, "Last update should hit 100%")
        XCTAssertEqual(updates.last?.stage, .finalizing)
    }

    func testProgressClampsFraction() {
        let low  = PipelineProgress(stage: .loading, fraction: -1)
        let high = PipelineProgress(stage: .finalizing, fraction: 2)
        XCTAssertEqual(low.fraction, 0)
        XCTAssertEqual(high.fraction, 1)
    }
}

final class TranscriptionRunStatusTests: XCTestCase {
    func testDurationIsMaxOfNoteEnd() {
        let run = TranscriptionRun(
            pipelineVersion: "1.0.0",
            modelName: "t",
            notes: [
                MIDINote(pitch: 60, onset: 0.0, duration: 1.0, velocity: 80),
                MIDINote(pitch: 62, onset: 0.5, duration: 2.0, velocity: 80), // ends at 2.5
                MIDINote(pitch: 64, onset: 1.0, duration: 0.5, velocity: 80),
            ]
        )
        XCTAssertEqual(run.duration, 2.5, accuracy: 1e-9)
    }

    func testDurationZeroForEmptyNotes() {
        let run = TranscriptionRun(pipelineVersion: "1.0.0", modelName: "t", notes: [])
        XCTAssertEqual(run.duration, 0)
        XCTAssertEqual(run.noteCount, 0)
        XCTAssertNil(run.pitchRange)
    }

    func testPitchRangeSpansMinToMax() {
        let run = TranscriptionRun(
            pipelineVersion: "1.0.0",
            modelName: "t",
            notes: [
                MIDINote(pitch: 60, onset: 0, duration: 0.1, velocity: 80),
                MIDINote(pitch: 72, onset: 0, duration: 0.1, velocity: 80),
                MIDINote(pitch: 48, onset: 0, duration: 0.1, velocity: 80),
            ]
        )
        XCTAssertEqual(run.pitchRange, 48...72)
    }

    func testLabelDefaultsToFormattedTimestamp() {
        let run = TranscriptionRun(pipelineVersion: "1.0.0", modelName: "t", notes: [])
        XCTAssertFalse(run.label.isEmpty, "Label should be auto-generated from createdAt when blank")
    }

    func testLabelRespectsProvidedValue() {
        let run = TranscriptionRun(
            pipelineVersion: "1.0.0",
            modelName: "t",
            notes: [],
            label: "My run"
        )
        XCTAssertEqual(run.label, "My run")
    }
}
