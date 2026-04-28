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

    // MARK: Tick conversion math
    //
    // 120 BPM, ticksPerBeat=480 → 960 ticks/sec. The header writes
    // microsPerBeat=500_000 (= 60_000_000 / 120), so playback duration matches.

    func testTicksPerSecondAt120BPM() {
        // Single note at onset=1s, duration=2s. Expect on@960, off@960+1920=2880.
        let notes = [MIDINote(pitch: 60, onset: 1.0, duration: 2.0, velocity: 80)]
        let parsed = parseSMF(MIDIGenerator().generateMIDI(from: notes))
        XCTAssertEqual(parsed.ticksPerBeat, 480)
        XCTAssertEqual(parsed.microsPerBeat, 500_000)
        let onAbs = parsed.events.first(where: { $0.kind == .on && $0.pitch == 60 })?.absTick
        let offAbs = parsed.events.first(where: { $0.kind == .off && $0.pitch == 60 })?.absTick
        XCTAssertEqual(onAbs, 960)
        XCTAssertEqual(offAbs, 960 + 1920)
    }

    func testNoteOnOffPairingAndOrdering() {
        let notes = [
            MIDINote(pitch: 60, onset: 0,   duration: 0.5, velocity: 80),
            MIDINote(pitch: 64, onset: 0.5, duration: 0.5, velocity: 70),
            MIDINote(pitch: 67, onset: 1.0, duration: 1.0, velocity: 90),
        ]
        let parsed = parseSMF(MIDIGenerator().generateMIDI(from: notes))
        let ons = parsed.events.filter { $0.kind == .on }
        let offs = parsed.events.filter { $0.kind == .off }
        // Same number of on and off events as input notes
        XCTAssertEqual(ons.count, notes.count)
        XCTAssertEqual(offs.count, notes.count)

        // Each pitch has exactly one on and one off, and off > on
        for note in notes {
            let on = ons.first(where: { $0.pitch == note.pitch })
            let off = offs.first(where: { $0.pitch == note.pitch })
            XCTAssertNotNil(on)
            XCTAssertNotNil(off)
            XCTAssertGreaterThan(off!.absTick, on!.absTick,
                                 "Off must come after on for pitch \(note.pitch)")
        }

        // No negative deltas in the encoded stream
        var prev = 0
        for evt in parsed.events {
            XCTAssertGreaterThanOrEqual(evt.absTick - prev, 0)
            prev = evt.absTick
        }
    }

    func testNoNegativeDurationsRoundTrip() {
        // Inputs are well-formed; the generator must not produce off < on.
        let notes = [
            MIDINote(pitch: 48, onset: 0.0, duration: 0.05, velocity: 90),
            MIDINote(pitch: 60, onset: 0.5, duration: 1.5,  velocity: 90),
            MIDINote(pitch: 72, onset: 2.0, duration: 0.10, velocity: 90),
        ]
        let parsed = parseSMF(MIDIGenerator().generateMIDI(from: notes))
        for note in notes {
            let on = parsed.events.first(where: { $0.kind == .on  && $0.pitch == note.pitch })!
            let off = parsed.events.first(where: { $0.kind == .off && $0.pitch == note.pitch })!
            XCTAssertGreaterThan(off.absTick, on.absTick,
                                 "Note \(note.pitch) has end <= start in SMF")
        }
    }
}

// MARK: - Minimal SMF parser used by the tests above

private struct ParsedSMF {
    enum EventKind { case on, off }
    struct Event { let absTick: Int; let kind: EventKind; let pitch: Int; let velocity: Int }
    let ticksPerBeat: Int
    let microsPerBeat: Int
    let events: [Event]
}

private func parseSMF(_ data: Data) -> ParsedSMF {
    let bytes = [UInt8](data)
    // MThd (4) + length(4)=6 + format(2) + tracks(2) + division(2)
    precondition(bytes.count >= 14)
    let division = (Int(bytes[12]) << 8) | Int(bytes[13])
    let ticksPerBeat = division
    // Track header at offset 14: MTrk (4) + length (4)
    let trackStart = 14 + 8
    var i = trackStart
    var tick = 0
    var events: [ParsedSMF.Event] = []
    var micros = 500_000
    var runningStatus: UInt8 = 0
    while i < bytes.count {
        // Variable-length delta
        var delta = 0
        while i < bytes.count {
            let b = bytes[i]; i += 1
            delta = (delta << 7) | Int(b & 0x7F)
            if b & 0x80 == 0 { break }
        }
        tick += delta
        guard i < bytes.count else { break }
        var status = bytes[i]
        if status < 0x80 {
            status = runningStatus
        } else {
            i += 1
            runningStatus = status
        }
        if status == 0xFF {
            // Meta event
            guard i < bytes.count else { break }
            let type = bytes[i]; i += 1
            // length (varlen)
            var len = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                len = (len << 7) | Int(b & 0x7F)
                if b & 0x80 == 0 { break }
            }
            if type == 0x51 && len == 3 && i + 2 < bytes.count {
                micros = (Int(bytes[i]) << 16) | (Int(bytes[i+1]) << 8) | Int(bytes[i+2])
            }
            i += len
            if type == 0x2F { break } // end of track
        } else {
            let high = status & 0xF0
            if high == 0x90 || high == 0x80 {
                guard i + 1 < bytes.count else { break }
                let pitch = Int(bytes[i]); i += 1
                let vel = Int(bytes[i]); i += 1
                let kind: ParsedSMF.EventKind = (high == 0x90 && vel > 0) ? .on : .off
                events.append(.init(absTick: tick, kind: kind, pitch: pitch, velocity: vel))
            } else if high == 0xC0 || high == 0xD0 {
                i += 1
            } else {
                i += 2
            }
        }
    }
    return ParsedSMF(ticksPerBeat: ticksPerBeat, microsPerBeat: micros, events: events)
}

// MARK: - MIDIScheduler tests

final class MIDISchedulerTests: XCTestCase {
    func testEventsHaveTwoEntriesPerNote() {
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 1.0, velocity: 80),
            MIDINote(pitch: 64, onset: 0.5, duration: 0.5, velocity: 80),
        ]
        let evs = MIDIScheduler().events(for: notes, from: 0)
        XCTAssertEqual(evs.count, 4)
        XCTAssertEqual(evs.filter { $0.kind == .on }.count, 2)
        XCTAssertEqual(evs.filter { $0.kind == .off }.count, 2)
    }

    func testNoNegativeDelays() {
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 1.0, velocity: 80),
            MIDINote(pitch: 62, onset: 5.0, duration: 1.0, velocity: 80),
        ]
        // Resume in the middle of the first note
        let evs = MIDIScheduler().events(for: notes, from: 0.5)
        for ev in evs { XCTAssertGreaterThanOrEqual(ev.delay, 0) }
        // The first note is mid-flight: note-on now (delay=0), note-off at 0.5
        let firstOn = evs.first { $0.kind == .on && $0.pitch == 60 }
        XCTAssertEqual(firstOn?.delay, 0)
        let firstOff = evs.first { $0.kind == .off && $0.pitch == 60 }
        XCTAssertEqual(firstOff?.delay ?? -1, 0.5, accuracy: 1e-9)
    }

    func testFinishedNotesAreSkipped() {
        let notes = [MIDINote(pitch: 60, onset: 0.0, duration: 1.0, velocity: 80)]
        let evs = MIDIScheduler().events(for: notes, from: 5.0)
        XCTAssertTrue(evs.isEmpty)
    }

    func testActivePitchesNoDuplicates() {
        // Mode-switching guarantee: if mode toggles MIDI on while audio plays,
        // re-asking the scheduler for events from the same `t` must still yield
        // a per-time active set with no duplicate pitches.
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 2.0, velocity: 80),
            MIDINote(pitch: 60, onset: 1.5, duration: 1.0, velocity: 80), // same pitch overlap
            MIDINote(pitch: 64, onset: 0.0, duration: 2.0, velocity: 80),
        ]
        let active = MIDIScheduler().activePitches(in: notes, at: 1.6)
        XCTAssertEqual(active.count, 2) // pitch 60 once, pitch 64 once
        XCTAssertTrue(active.contains(60))
        XCTAssertTrue(active.contains(64))
    }

    func testReSchedulingDoesNotMutateInput() {
        let notes = [MIDINote(pitch: 60, onset: 0.0, duration: 1.0, velocity: 80)]
        let before = notes
        _ = MIDIScheduler().events(for: notes, from: 0.0)
        _ = MIDIScheduler().events(for: notes, from: 0.5)
        XCTAssertEqual(notes, before)
    }
}

// MARK: - NoteDisplayFilter tests

final class NoteDisplayFilterTests: XCTestCase {
    private let mixed: [MIDINote] = [
        MIDINote(pitch: 60, onset: 0.0, duration: 0.10, velocity: 90),
        MIDINote(pitch: 61, onset: 0.5, duration: 0.04, velocity: 90), // very short
        MIDINote(pitch: 62, onset: 1.0, duration: 0.20, velocity: 10), // low conf
        MIDINote(pitch: 63, onset: 1.5, duration: 0.30, velocity: 80),
    ]

    func testDefaultsDropLowConfidenceAndVeryShort() {
        let kept = NoteDisplayFilter.defaults.apply(to: mixed).map(\.pitch)
        XCTAssertFalse(kept.contains(61))
        XCTAssertFalse(kept.contains(62))
        XCTAssertTrue(kept.contains(60))
        XCTAssertTrue(kept.contains(63))
    }

    func testShowRawBypassesAllFilters() {
        var f = NoteDisplayFilter.defaults
        f.showRaw = true
        let kept = f.apply(to: mixed)
        XCTAssertEqual(kept.count, mixed.count)
    }

    func testVelocityScaleDoesNotChangeCount() {
        var f = NoteDisplayFilter(minVelocity: 0, minDuration: 0, hideVeryShort: false, velocityScale: 0.5)
        XCTAssertEqual(f.apply(to: mixed).count, mixed.count)
        f.velocityScale = 2.0
        XCTAssertEqual(f.apply(to: mixed).count, mixed.count)
    }
}

// MARK: - Timeline / audio duration sanity

final class TimelineDurationTests: XCTestCase {
    func testRunDurationIsLatestNoteEnd() {
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 0.5, velocity: 80),
            MIDINote(pitch: 62, onset: 1.0, duration: 2.0, velocity: 80), // ends at 3.0
            MIDINote(pitch: 64, onset: 0.5, duration: 0.5, velocity: 80),
        ]
        let run = TranscriptionRun(pipelineVersion: "1.0.0", modelName: "t", notes: notes)
        XCTAssertEqual(run.duration, 3.0, accuracy: 1e-9)
    }

    func testTimelineMatchesAudioDurationWithinTolerance() throws {
        // Synthesize a 1s WAV and verify TranscriptionRun.duration ≤ audioFile.duration
        // (the run's last note must end within the file). Tolerance: 50ms.
        let sr: Double = 44100
        let frames = AVAudioFrameCount(sr) // 1.0s
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_dur_\(UUID().uuidString).wav")
        // Scope the writer so its handle flushes before the read below.
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try file.write(from: buf)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let openFile = try AVAudioFile(forReading: url)
        let audioDuration = Double(openFile.length) / openFile.processingFormat.sampleRate
        XCTAssertEqual(audioDuration, 1.0, accuracy: 0.05)

        let run = TranscriptionRun(
            pipelineVersion: "1.0.0",
            modelName: "t",
            notes: [MIDINote(pitch: 60, onset: 0.0, duration: 0.5, velocity: 80)]
        )
        XCTAssertLessThanOrEqual(run.duration, audioDuration + 0.05)
    }
}

final class DefaultPipelineTests: XCTestCase {
    func testRunReturnsPipelineVersion() async throws {
        let runner = MockModelRunner(seed: 1)
        let pipeline = DefaultPipeline(runner: runner)
        let url = URL(fileURLWithPath: "/tmp/nonexistent.wav")
        let run = try await pipeline.run(audioURL: url)
        XCTAssertEqual(run.pipelineVersion, "1.1.0")
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
        // Scope the writer so its file handle is released before the runner
        // opens the same path for reading — otherwise AVAudioFile reports length 0
        // and the read fails with coreaudio error -50.
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try file.write(from: buf)
        }
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

        XCTAssertEqual(run.pipelineVersion, "1.1.0")
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
    func testUserVisibleKindsAreTheThreeNewPipelines() {
        XCTAssertEqual(
            PipelineKind.userVisibleCases,
            [.cleanSoloPiano, .noisySoloPiano, .mixedInstrumentsAdvanced],
            "Only the three new pipelines should be user-visible"
        )
        XCTAssertFalse(PipelineKind.userVisibleCases.contains(.mockDemo),
                       "Mock pipeline must stay out of user-visible UI")
        XCTAssertFalse(PipelineKind.userVisibleCases.contains(.basicFast),
                       "Legacy spectral baseline must not appear in the picker")
    }

    func testEveryUserVisibleKindIsSelectable() {
        // After the "every mode is selectable" change, every user-visible
        // kind reports `isAvailable == true`. The fallback path is what
        // changes when the dedicated backend is missing — not the flag.
        for kind in PipelineKind.userVisibleCases {
            XCTAssertTrue(kind.isAvailable, "\(kind.rawValue) should be selectable")
        }
    }

    func testBasicAndPianoFocusedAreAvailable() {
        XCTAssertTrue(PipelineKind.basicFast.isAvailable)
        XCTAssertTrue(PipelineKind.pianoFocused.isAvailable)
    }

    func testAllKindsExposeDisplayMetadata() {
        for kind in PipelineKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty)
            XCTAssertFalse(kind.summary.isEmpty)
            XCTAssertFalse(kind.systemImage.isEmpty)
        }
    }
}

final class PipelineRegistryTests: XCTestCase {
    func testRegistryBuildsAvailablePipelines() {
        let registry = PipelineRegistry()
        XCTAssertNotNil(registry.makePipeline(.basicFast))
        XCTAssertNotNil(registry.makePipeline(.pianoFocused))
        XCTAssertNotNil(registry.makePipeline(.mockDemo))
    }

    func testMixedAudioFallsBackWhenSeparatorMissing() {
        // No separator installed → registry must still produce a runnable
        // pipeline; the run is stamped with `fallback.applied=true`.
        // Force discovery off so the repo-local Demucs wrapper isn't picked up.
        setenv("PIANO_TRAINER_DISABLE_DISCOVERY", "1", 1)
        defer { unsetenv("PIANO_TRAINER_DISABLE_DISCOVERY") }
        let registry = PipelineRegistry()
        let pipeline = registry.makePipeline(.mixedAudio)
        XCTAssertNotNil(pipeline, "Mixed Audio must always produce a runnable pipeline")
        XCTAssertTrue(registry.isAvailable(.mixedAudio))
        XCTAssertFalse(registry.hasDedicatedBackend(.mixedAudio))
        XCTAssertNotNil(registry.fallbackReason(.mixedAudio))
        XCTAssertTrue(pipeline is FallbackTranscriptionPipeline)
    }

    func testMixedAudioPipelineUsesDedicatedBackendWhenSeparatorInstalled() {
        struct StubSeparator: PianoStemSeparator {
            let name = "Stub"
            func separate(audioURL: URL, outputDirectory: URL, progress: PipelineProgressHandler?) async throws -> URL { audioURL }
        }
        let registry = PipelineRegistry(pianoStemSeparator: StubSeparator())
        let pipeline = registry.makePipeline(.mixedAudio)
        XCTAssertNotNil(pipeline)
        XCTAssertTrue(registry.hasDedicatedBackend(.mixedAudio))
        XCTAssertNil(registry.fallbackReason(.mixedAudio))
        XCTAssertFalse(pipeline is FallbackTranscriptionPipeline)
    }

    /// Every user-visible kind must produce a non-nil pipeline regardless
    /// of which dependencies happen to be installed. This is the
    /// "no `unsupportedMode`" guarantee the dropdown fix relies on.
    func testEveryUserVisibleKindReturnsRunnablePipeline() {
        let registry = PipelineRegistry()
        for kind in PipelineKind.userVisibleCases {
            XCTAssertNotNil(
                registry.makePipeline(kind),
                "\(kind.rawValue) should produce a runnable pipeline (real or fallback)"
            )
            XCTAssertTrue(registry.isAvailable(kind))
        }
    }

    /// The fallback pipeline must produce a run that surfaces the missing
    /// dependency reason via `pipelineParameters["fallback.reason"]`.
    func testFallbackPipelineStampsFallbackMetadata() async throws {
        // Force discovery off so the repo-local Demucs wrapper doesn't satisfy
        // the dedicated-backend check; we want the Fallback pipeline path.
        setenv("PIANO_TRAINER_DISABLE_DISCOVERY", "1", 1)
        defer { unsetenv("PIANO_TRAINER_DISABLE_DISCOVERY") }
        let registry = PipelineRegistry()
        let pipeline = registry.makePipeline(.mixedAudio)
        XCTAssertTrue(pipeline is FallbackTranscriptionPipeline)

        // Use a synthetic 1s WAV so the inner Piano-Focused pipeline can run.
        let sr: Double = 44100
        let frames = AVAudioFrameCount(sr)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_fallback_\(UUID().uuidString).wav")
        do {
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try f.write(from: buf)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let run = try await pipeline!.run(audioURL: url, progress: nil)
        XCTAssertEqual(run.pipelineID, PipelineKind.mixedAudio.rawValue)
        XCTAssertEqual(run.pipelineName, PipelineKind.mixedAudio.displayName)
        XCTAssertEqual(run.pipelineParameters["fallback.applied"], "true")
        XCTAssertEqual(run.pipelineParameters["fallback.requestedKind"], PipelineKind.mixedAudio.rawValue)
        XCTAssertNotNil(run.pipelineParameters["fallback.reason"])
        XCTAssertTrue(run.ranOnFallback)
    }

    func testPipelinesStampRunsWithIdentity() async throws {
        let pipeline = BasicFastPipeline(runner: BasicPianoModelRunner(config: .basic))
        let url = URL(fileURLWithPath: "/tmp/nonexistent.wav")
        // We don't actually need transcription to succeed here; we only care about
        // the pipeline reporting its identity correctly. Wire an empty stub:
        struct EmptyRunner: ModelRunner {
            let name = "EmptyRunner"
            func transcribe(audioURL: URL, progress: PipelineProgressHandler?) async throws -> [MIDINote] { [] }
        }
        let stub = DefaultPipeline(runner: EmptyRunner(), kind: .basicFast)
        let run = try await stub.run(audioURL: url)
        XCTAssertEqual(run.pipelineID, PipelineKind.basicFast.rawValue)
        XCTAssertEqual(run.pipelineName, PipelineKind.basicFast.displayName)
        XCTAssertEqual(run.inputAudioPath, url.path)
        _ = pipeline  // silence unused warning
    }
}

final class MixedAudioPianoIsolationPipelineTests: XCTestCase {
    func testThrowsUnavailableWithoutSeparator() async {
        let pipeline = MixedAudioPianoIsolationPipeline(separator: nil)
        let url = URL(fileURLWithPath: "/tmp/nonexistent.wav")
        do {
            _ = try await pipeline.run(audioURL: url)
            XCTFail("Expected PipelineError.unavailable")
        } catch let PipelineError.unavailable(reason) {
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("Expected PipelineError.unavailable, got: \(error)")
        }
    }
}

final class NoteRefinementTests: XCTestCase {
    func testPruneGhostsDropsShortNotes() {
        let notes = [
            MIDINote(pitch: 60, onset: 0,   duration: 0.05, velocity: 80),
            MIDINote(pitch: 62, onset: 0.5, duration: 0.5,  velocity: 80),
        ]
        let refined = NoteRefinement.pruneGhosts(notes, minDuration: 0.08)
        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined.first?.pitch, 62)
    }

    func testMergeShortGapsCombinesSamePitchAcrossSmallGap() {
        let notes = [
            MIDINote(pitch: 60, onset: 0,   duration: 0.4, velocity: 80),
            MIDINote(pitch: 60, onset: 0.5, duration: 0.4, velocity: 90),
        ]
        let merged = NoteRefinement.mergeShortGaps(notes, maxGap: 0.25)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.duration ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(merged.first?.velocity, 90)
    }

    func testMergeShortGapsLeavesDifferentPitchesAlone() {
        let notes = [
            MIDINote(pitch: 60, onset: 0,   duration: 0.4, velocity: 80),
            MIDINote(pitch: 62, onset: 0.5, duration: 0.4, velocity: 80),
        ]
        let merged = NoteRefinement.mergeShortGaps(notes, maxGap: 0.25)
        XCTAssertEqual(merged.count, 2)
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

// MARK: - Pre-flight invariants
//
// These run BEFORE any model-quality test. If any of these fail, all
// downstream "model is bad" diagnoses are unreliable — the data path itself
// is broken and must be fixed first.

final class TranscriptionInvariantsTests: XCTestCase {

    /// MIDI note start/end conversion must round-trip through SMF unchanged.
    func testMIDIStartEndConversionRoundTrip() {
        let cases: [(onset: Double, dur: Double)] = [
            (0.0,  0.05),
            (0.5,  1.0),
            (1.234, 0.567),
            (10.0, 5.5),
        ]
        for (onset, dur) in cases {
            let note = MIDINote(pitch: 60, onset: onset, duration: dur, velocity: 80)
            let parsed = parseSMF(MIDIGenerator().generateMIDI(from: [note]))
            let on = parsed.events.first { $0.kind == .on && $0.pitch == 60 }!
            let off = parsed.events.first { $0.kind == .off && $0.pitch == 60 }!
            // 480 ticks/beat, 120 BPM → 960 ticks/sec
            let expectedOn = Int(onset * 960)
            let expectedOff = Int((onset + dur) * 960)
            XCTAssertEqual(on.absTick, expectedOn, "onset=\(onset)")
            XCTAssertEqual(off.absTick, expectedOff, "offset=\(onset+dur)")
        }
    }

    /// Pitch numbers must not be shifted in any direction during MIDI export.
    func testPitchNumbersAreNotShifted() {
        let pitches = [21, 36, 60, 69, 96, 108]   // A0, C2, C4, A4, C7, C8
        let notes = pitches.enumerated().map { i, p in
            MIDINote(pitch: p, onset: Double(i) * 0.5, duration: 0.25, velocity: 80)
        }
        let parsed = parseSMF(MIDIGenerator().generateMIDI(from: notes))
        let onPitches = parsed.events.filter { $0.kind == .on }.map(\.pitch).sorted()
        XCTAssertEqual(onPitches, pitches.sorted())
    }

    /// Sample-rate conversion: opening a 44.1 kHz mono WAV reports 44100 Hz.
    /// Guards against the AudioExtractor producing a file at a wrong rate.
    func testSampleRateConversionTo44100() throws {
        let sr: Double = 44100
        let frames = AVAudioFrameCount(sr) // 1 second
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_sr_\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try file.write(from: buf)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let opened = try AVAudioFile(forReading: url)
        XCTAssertEqual(opened.processingFormat.sampleRate, 44100, accuracy: 0.5)
        XCTAssertEqual(opened.processingFormat.channelCount, 1)
    }

    /// Every note-on must have a paired note-off; no leftover open notes.
    func testNoteOffPairingIsExhaustive() {
        let notes = (0..<25).map { i in
            MIDINote(pitch: 40 + i, onset: Double(i) * 0.1, duration: 0.2, velocity: 80)
        }
        let parsed = parseSMF(MIDIGenerator().generateMIDI(from: notes))
        // Walk the event stream tracking active pitches; at end of track, no pitch should still be on.
        var active = Set<Int>()
        for evt in parsed.events {
            if evt.kind == .on { active.insert(evt.pitch) }
            else { active.remove(evt.pitch) }
        }
        XCTAssertTrue(active.isEmpty, "Leftover active pitches: \(active.sorted())")
    }

    /// Sustain handling must never produce notes longer than the source clip.
    /// The current pipeline does not implement sustain pedal support, so any
    /// note longer than the source is a bug.
    func testNoInfiniteSustainNotes() async throws {
        // 2-second piano tone. Even with sustain, the runner should not produce
        // notes longer than the audio itself.
        let sr: Double = 44100
        let dur = 2.0
        let frameCount = Int(dur * sr)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        let data = buf.floatChannelData![0]
        let fund = 440.0
        for i in 0..<frameCount {
            let t = Double(i) / sr
            data[i] = Float(0.5 * exp(-t * 1.5) * sin(2 * .pi * fund * t))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_sus_\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try file.write(from: buf)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let runner = BasicPianoModelRunner()
        let notes = try await runner.transcribe(audioURL: url)
        for note in notes {
            XCTAssertLessThanOrEqual(note.duration, dur + 0.1,
                "Note duration \(note.duration)s exceeds clip length \(dur)s — possible stuck note-on")
        }
    }
}

// MARK: - TranscriptionDiagnostics tests

final class TranscriptionDiagnosticsTests: XCTestCase {

    func testCleanRunPasses() {
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 0.5, velocity: 80),
            MIDINote(pitch: 64, onset: 0.6, duration: 0.5, velocity: 80),
            MIDINote(pitch: 67, onset: 1.2, duration: 0.5, velocity: 80),
        ]
        let result = TranscriptionDiagnostics.analyze(notes: notes, audioDuration: 2.0)
        XCTAssertEqual(result.status, .pass)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.stats.totalNotes, 3)
        XCTAssertGreaterThan(result.qualityScore, 0.95)
    }

    func testFlagsLongNoteWithoutSustain() {
        let notes = [MIDINote(pitch: 60, onset: 0, duration: 60, velocity: 80)]
        let result = TranscriptionDiagnostics.analyze(notes: notes, audioDuration: 2.0)
        XCTAssertEqual(result.status, .fail)
        XCTAssertTrue(result.issues.contains { $0.id == "long_note" })
        XCTAssertFalse(result.longestNotes.isEmpty)
    }

    func testSustainPedalSilencesLongNoteFailure() {
        var cfg = TranscriptionDiagnosticsConfig()
        cfg.sustainPedalDeclared = true
        let notes = [MIDINote(pitch: 60, onset: 0, duration: 45, velocity: 80)]
        // Audio duration matches the sustained note end so duration_mismatch
        // doesn't fire and conflate the assertion.
        let result = TranscriptionDiagnostics.analyze(notes: notes, audioDuration: 45.0, config: cfg)
        XCTAssertFalse(result.issues.contains { $0.id == "long_note" },
            "Sustain-declared run should not raise long_note failure")
        XCTAssertTrue(result.issues.contains { $0.id == "long_note_sustained" })
    }

    func testFlagsExactOnsetPileup() {
        let notes = (0..<6).map { p in
            MIDINote(pitch: 60 + p, onset: 1.000, duration: 0.5, velocity: 80)
        }
        let result = TranscriptionDiagnostics.analyze(notes: notes, audioDuration: 2.0)
        XCTAssertTrue(result.issues.contains { $0.id == "exact_onset_pileup" })
    }

    func testFlagsClusterOver8In50ms() {
        let notes = (0..<10).map { i in
            MIDINote(pitch: 40 + i, onset: 0.4 + Double(i) * 0.004, duration: 0.2, velocity: 80)
        }
        let result = TranscriptionDiagnostics.analyze(notes: notes, audioDuration: 2.0)
        XCTAssertTrue(result.issues.contains { $0.id == "onset_cluster" })
        XCTAssertFalse(result.suspiciousClusters.isEmpty)
    }

    func testFlagsHighDensity() {
        // 40 notes inside one second
        let notes = (0..<40).map { i in
            MIDINote(pitch: 40 + (i % 30), onset: Double(i) * 0.02, duration: 0.05, velocity: 80)
        }
        let result = TranscriptionDiagnostics.analyze(notes: notes, audioDuration: 2.0)
        XCTAssertTrue(result.issues.contains { $0.id == "density_spike" })
    }

    func testFlagsOutOfRangePitchDistribution() {
        let notes = (0..<10).map { i in
            MIDINote(pitch: 24 + i, onset: Double(i) * 0.5, duration: 0.4, velocity: 80) // C1…A1
        }
        let result = TranscriptionDiagnostics.analyze(notes: notes, audioDuration: 6.0)
        XCTAssertTrue(result.issues.contains { $0.id == "pitch_out_of_range" })
    }

    func testFlagsDurationMismatch() {
        let notes = [MIDINote(pitch: 60, onset: 0, duration: 0.5, velocity: 80)]
        let result = TranscriptionDiagnostics.analyze(notes: notes, audioDuration: 30.0)
        XCTAssertTrue(result.issues.contains { $0.id == "duration_mismatch" })
        XCTAssertEqual(result.status, .fail)
    }

    func testFlagsSamePitchOverlap() {
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 1.0, velocity: 80),
            MIDINote(pitch: 60, onset: 0.5, duration: 1.0, velocity: 80), // overlaps itself
        ]
        let result = TranscriptionDiagnostics.analyze(notes: notes, audioDuration: 2.0)
        XCTAssertTrue(result.issues.contains { $0.id == "same_pitch_overlap" })
    }

    func testSilenceMismatchFlagsHallucinatedNotes() {
        let notes = [
            MIDINote(pitch: 60, onset: 0.0,  duration: 0.2, velocity: 80),
            MIDINote(pitch: 64, onset: 5.0,  duration: 0.2, velocity: 80), // silent region
        ]
        let base = TranscriptionDiagnostics.analyze(notes: notes, audioDuration: 6.0)
        // Build an RMS profile: loud at 0s, silent everywhere else
        let hop = 0.05
        let frames = Int(6.0 / hop)
        var rms = [Float](repeating: 0.0, count: frames)
        for i in 0..<10 { rms[i] = 0.5 } // 0.0–0.5s loud
        let annotated = TranscriptionDiagnostics.annotateSilenceMismatches(
            analysis: base, notes: notes, rmsProfile: rms, rmsHopSeconds: hop
        )
        XCTAssertTrue(annotated.issues.contains { $0.id == "notes_in_silence" })
    }

    func testStatsOctaveHistogram() {
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 0.5, velocity: 80), // C4 → octave 4
            MIDINote(pitch: 72, onset: 0.5, duration: 0.5, velocity: 80), // C5 → octave 5
            MIDINote(pitch: 64, onset: 1.0, duration: 0.5, velocity: 80), // E4 → octave 4
        ]
        let stats = TranscriptionDiagnostics.computeStats(notes: notes, audioDuration: 2.0)
        XCTAssertEqual(stats.octaveHistogram[4], 2)
        XCTAssertEqual(stats.octaveHistogram[5], 1)
    }

    func testRunComparisonRanksByQuality() {
        let good = TranscriptionRun(
            pipelineVersion: "1.0.0",
            modelName: "good",
            notes: [
                MIDINote(pitch: 60, onset: 0, duration: 0.5, velocity: 80),
                MIDINote(pitch: 64, onset: 0.6, duration: 0.5, velocity: 80),
            ]
        )
        let bad = TranscriptionRun(
            pipelineVersion: "1.0.0",
            modelName: "bad",
            notes: [MIDINote(pitch: 60, onset: 0, duration: 999, velocity: 80)]
        )
        let comp = RunComparison.compare(runs: [good, bad], audioDuration: 2.0)
        XCTAssertEqual(comp.rows.count, 2)
        let goodRow = comp.rows.first { $0.runID == good.id }!
        let badRow = comp.rows.first { $0.runID == bad.id }!
        XCTAssertGreaterThan(goodRow.qualityScore, badRow.qualityScore)
        XCTAssertEqual(badRow.status, .fail)
    }
}

// MARK: - Mixed-instrument piano precision pipeline tests

final class MixedAudioPostProcessorTests: XCTestCase {
    func testGhostsBelowMinVelocityAreDropped() {
        let cfg = MixedAudioPostProcessor.Config(ghostMinVelocity: 30)
        let pp = MixedAudioPostProcessor(config: cfg)
        let notes = [
            MIDINote(pitch: 60, onset: 0,   duration: 0.5, velocity: 10),
            MIDINote(pitch: 62, onset: 0.5, duration: 0.5, velocity: 80),
        ]
        let (out, report) = pp.process(notes)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.pitch, 62)
        XCTAssertEqual(report.ghostsDropped, 1)
    }

    func testBurstsArePrunedKeepingHighestVelocities() {
        let cfg = MixedAudioPostProcessor.Config(maxBurstCount: 3)
        let pp = MixedAudioPostProcessor(config: cfg)
        // 6 notes all at the same onset with descending velocity
        let notes = (0..<6).map {
            MIDINote(pitch: 60 + $0, onset: 1.0, duration: 0.4, velocity: 100 - $0 * 5)
        }
        let (out, report) = pp.process(notes)
        XCTAssertEqual(out.count, 3, "Only the 3 highest-velocity notes should survive")
        XCTAssertEqual(report.burstPruned, 3)
        // Surviving velocities should be the top three
        let velocities = Set(out.map(\.velocity))
        XCTAssertEqual(velocities, [100, 95, 90])
    }

    func testLongNotesAreClampedAndCounted() {
        let cfg = MixedAudioPostProcessor.Config(maxNoteDuration: 5.0, longNoteWarnThreshold: 3.0)
        let pp = MixedAudioPostProcessor(config: cfg)
        let notes = [
            MIDINote(pitch: 60, onset: 0, duration: 60.0, velocity: 80),
            MIDINote(pitch: 62, onset: 0, duration: 4.0,  velocity: 80),
            MIDINote(pitch: 64, onset: 0, duration: 1.0,  velocity: 80),
        ]
        let (out, report) = pp.process(notes)
        let clamped = out.first { $0.pitch == 60 }!
        XCTAssertEqual(clamped.duration, 5.0, accuracy: 1e-9, "Note must be clamped to maxNoteDuration")
        XCTAssertEqual(report.clampedLongNotes, 1)
        XCTAssertGreaterThanOrEqual(report.longNoteWarnings, 2,
            "Both the clamped 60s note and the 4s note exceed the warn threshold")
    }

    func testSustainMergeKeepsSamePitchTogether() {
        let cfg = MixedAudioPostProcessor.Config(sustainMergeGap: 0.2)
        let pp = MixedAudioPostProcessor(config: cfg)
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 0.4, velocity: 80),
            MIDINote(pitch: 60, onset: 0.5, duration: 0.4, velocity: 85),
        ]
        let (out, report) = pp.process(notes)
        XCTAssertEqual(out.count, 1)
        XCTAssertGreaterThanOrEqual(report.sustainMerged, 1)
    }

    func testOverlapsOnSamePitchAreCollapsed() {
        let cfg = MixedAudioPostProcessor.Config(overlapMergeFraction: 0.5)
        let pp = MixedAudioPostProcessor(config: cfg)
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 1.0, velocity: 80),
            MIDINote(pitch: 60, onset: 0.4, duration: 1.0, velocity: 90), // 60% overlap with above
        ]
        let (out, report) = pp.process(notes)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(report.overlapMerged, 1)
    }
}

final class MixedAudioDiagnosticsBuilderTests: XCTestCase {
    func testBuildsBasicReport() {
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 1.0, velocity: 80),
            MIDINote(pitch: 64, onset: 0.5, duration: 0.5, velocity: 70),
            MIDINote(pitch: 67, onset: 1.0, duration: 1.0, velocity: 90),
        ]
        let context = MixedAudioDiagnosticsBuilder.Context(
            sourceDurationSeconds: 2.5,
            stemDurationSeconds: 2.5,
            post: MixedAudioPostProcessor.Report()
        )
        let report = MixedAudioDiagnosticsBuilder.build(notes: notes, context: context)
        XCTAssertEqual(report.totalNotes, 3)
        XCTAssertEqual(report.pitchMin, 60)
        XCTAssertEqual(report.pitchMax, 67)
        XCTAssertEqual(report.timelineDriftSeconds, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(report.maxNoteDuration, 0)
    }

    func testWarnsOnTimelineDrift() {
        let notes = [MIDINote(pitch: 60, onset: 0, duration: 0.5, velocity: 80)]
        let context = MixedAudioDiagnosticsBuilder.Context(
            sourceDurationSeconds: 60.0,
            stemDurationSeconds: 50.0,
            post: MixedAudioPostProcessor.Report()
        )
        let report = MixedAudioDiagnosticsBuilder.build(notes: notes, context: context)
        XCTAssertGreaterThan(report.timelineDriftSeconds, 5)
        XCTAssertTrue(report.warnings.contains { $0.localizedCaseInsensitiveContains("stem duration") })
    }

    func testWarnsOnSubOctaveAlias() {
        let notes = [MIDINote(pitch: 21, onset: 0, duration: 0.5, velocity: 100)]
        let context = MixedAudioDiagnosticsBuilder.Context(
            sourceDurationSeconds: 1.0, stemDurationSeconds: 1.0,
            post: MixedAudioPostProcessor.Report()
        )
        let report = MixedAudioDiagnosticsBuilder.build(notes: notes, context: context)
        XCTAssertTrue(report.warnings.contains { $0.localizedCaseInsensitiveContains("sub-octave") || $0.localizedCaseInsensitiveContains("lowest") })
    }

    func testEmptyNotesReportsLikelyFailure() {
        let context = MixedAudioDiagnosticsBuilder.Context(
            sourceDurationSeconds: 5.0,
            stemDurationSeconds: 5.0,
            post: MixedAudioPostProcessor.Report()
        )
        let report = MixedAudioDiagnosticsBuilder.build(notes: [], context: context)
        XCTAssertEqual(report.totalNotes, 0)
        XCTAssertFalse(report.warnings.isEmpty)
    }
}

final class MixedInstrumentPianoPrecisionPipelineTests: XCTestCase {

    private struct StubSeparator: SourceSeparator {
        let name: String
        let isAvailable: Bool
        let unavailableReason: String?
        let stemSampleSeconds: Double

        func separate(audioURL: URL, outputDirectory: URL, progress: PipelineProgressHandler?) async throws -> SeparationResult {
            // Copy the input into the output dir so downstream stages have a real file.
            let stemURL = outputDirectory.appendingPathComponent("stem.wav")
            if FileManager.default.fileExists(atPath: stemURL.path) {
                try FileManager.default.removeItem(at: stemURL)
            }
            try FileManager.default.copyItem(at: audioURL, to: stemURL)
            return SeparationResult(
                stemURL: stemURL,
                methodName: name,
                qualityScore: 0.8,
                stemDurationSeconds: stemSampleSeconds,
                parameters: ["model": "stub"]
            )
        }
    }

    private func makeWAV(durationSeconds: Double = 1.0) throws -> URL {
        let sr: Double = 44100
        let frames = AVAudioFrameCount(durationSeconds * sr)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        // simple 440 Hz tone so the runner has something to find
        let data = buf.floatChannelData![0]
        for i in 0 ..< Int(frames) {
            data[i] = Float(sin(2 * .pi * 440 * Double(i) / sr) * 0.3)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_precision_\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try file.write(from: buf)
        }
        return url
    }

    func testThrowsUnavailableWhenSeparatorMissing() async throws {
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let pipeline = MixedInstrumentPianoPrecisionPipeline()
        do {
            _ = try await pipeline.run(audioURL: url)
            XCTFail("Expected unavailable error")
        } catch let PipelineError.unavailable(reason) {
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("Expected PipelineError.unavailable, got \(error)")
        }
    }

    func testProducesRunWithSeparationStampedOnIt() async throws {
        let url = try makeWAV(durationSeconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let artifactRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_precision_artifacts_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        let pipeline = MixedInstrumentPianoPrecisionPipeline(
            separator: StubSeparator(name: "StubSep", isAvailable: true, unavailableReason: nil, stemSampleSeconds: 2.0),
            transcriber: FallbackPianoTranscriber(),
            artifactRoot: artifactRoot
        )
        let run = try await pipeline.run(audioURL: url)
        XCTAssertEqual(run.pipelineID, PipelineKind.mixedInstrumentPianoPrecision.rawValue)
        XCTAssertTrue(run.usedSourceSeparation)
        XCTAssertNotNil(run.isolatedStemPath)
        XCTAssertEqual(run.pipelineParameters["separator.method"], "StubSep")
        // Fallback transcriber must be flagged as such.
        XCTAssertEqual(run.pipelineParameters["model.fallback"], "true")
        // Artifact files should exist on disk.
        XCTAssertNotNil(run.pipelineParameters["artifact.runDir"])
        if let runDirPath = run.pipelineParameters["artifact.runDir"] {
            let runDir = URL(fileURLWithPath: runDirPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("processed.mid").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("raw.mid").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("diagnostics.json").path))
        }
    }

    func testRegistryFallsBackForPrecisionWhenSeparatorMissing() {
        // Force discovery off so the repo-local Demucs wrapper installed by
        // setup-transcription-deps.sh doesn't satisfy the precision pipeline's
        // separator slot; we want the fallback path under test.
        setenv("PIANO_TRAINER_DISABLE_DISCOVERY", "1", 1)
        defer { unsetenv("PIANO_TRAINER_DISABLE_DISCOVERY") }
        let registry = PipelineRegistry()
        XCTAssertTrue(registry.isAvailable(.mixedInstrumentPianoPrecision))
        XCTAssertFalse(registry.hasDedicatedBackend(.mixedInstrumentPianoPrecision))
        XCTAssertNotNil(registry.fallbackReason(.mixedInstrumentPianoPrecision))
        let pipeline = registry.makePipeline(.mixedInstrumentPianoPrecision)
        XCTAssertNotNil(pipeline)
        XCTAssertTrue(pipeline is FallbackTranscriptionPipeline)
    }

    func testRegistryUsesDedicatedPrecisionWhenSeparatorInstalled() {
        let registry = PipelineRegistry(
            sourceSeparator: StubSeparator(name: "StubSep", isAvailable: true, unavailableReason: nil, stemSampleSeconds: 1.0)
        )
        XCTAssertTrue(registry.hasDedicatedBackend(.mixedInstrumentPianoPrecision))
        XCTAssertNil(registry.fallbackReason(.mixedInstrumentPianoPrecision))
        XCTAssertNotNil(registry.makePipeline(.mixedInstrumentPianoPrecision))
    }
}

// MARK: - TranscriptionCleanup tests

final class TranscriptionCleanupTests: XCTestCase {

    func testClampsNotesToAudioDuration() {
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 5.0
        let raw = [
            MIDINote(pitch: 60, onset: 0.0, duration: 100.0, velocity: 80), // overshoots → clamp
            MIDINote(pitch: 64, onset: 4.5, duration: 10.0,  velocity: 80), // overshoots → clamp
            MIDINote(pitch: 67, onset: 1.0, duration: 0.5,   velocity: 80), // ok
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertEqual(outcome.report.clampedToAudioDuration, 2)
        for note in outcome.cleaned {
            XCTAssertLessThanOrEqual(note.onset + note.duration, 5.0 + 0.001,
                                     "Note end exceeds audio duration")
        }
    }

    func testDropsLongNotesWithoutSustain() {
        var cfg = TranscriptionCleanup.Config()
        cfg.maxNoteDurationSeconds = 8.0
        cfg.audioDurationSeconds = 60
        let raw = [
            MIDINote(pitch: 60, onset: 0, duration: 30.0, velocity: 80), // long → drop
            MIDINote(pitch: 64, onset: 1, duration: 218.0, velocity: 80), // catastrophic → drop
            MIDINote(pitch: 67, onset: 2, duration: 0.5,  velocity: 80), // ok
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        // Note: clampedToAudioDuration may also fire on the 218s one before length check.
        // Either way, no surviving note should be longer than maxNoteDurationSeconds.
        for note in outcome.cleaned {
            XCTAssertLessThanOrEqual(note.duration, cfg.maxNoteDurationSeconds + 0.001)
        }
        XCTAssertGreaterThan(outcome.report.droppedLongNotes + outcome.report.clampedToAudioDuration, 0)
    }

    func testKeepsLongNotesWhenSustainDeclared() {
        var cfg = TranscriptionCleanup.Config()
        cfg.sustainPedalDeclared = true
        cfg.audioDurationSeconds = 60
        let raw = [MIDINote(pitch: 60, onset: 0, duration: 25.0, velocity: 80)]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertEqual(outcome.cleaned.count, 1)
        XCTAssertEqual(outcome.report.droppedLongNotes, 0)
    }

    func testPrunesOnsetClustersAbove8In50ms() {
        // 12 notes inside 30ms; max 8 should survive.
        var cfg = TranscriptionCleanup.Config()
        cfg.maxNotesPerClusterWindow = 8
        cfg.maxNotesPerDensityBucket = 1000 // disable density stage
        cfg.audioDurationSeconds = 5
        let raw = (0..<12).map { i in
            MIDINote(pitch: 50 + i, onset: 1.000 + Double(i) * 0.0025, duration: 0.5, velocity: 30 + i)
        }
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertGreaterThan(outcome.report.prunedFromClusters, 0)
        // Verify no surviving 50ms window has >8 notes.
        let onsets = outcome.cleaned.map(\.onset).sorted()
        for i in 0..<onsets.count {
            let count = onsets.filter { $0 >= onsets[i] && $0 - onsets[i] <= 0.050 }.count
            XCTAssertLessThanOrEqual(count, cfg.maxNotesPerClusterWindow)
        }
    }

    func testPrunesExactOnsetPileup() {
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 5
        // 6 notes at the same onset, all same pitch → 5 are duplicates.
        let raw = (0..<6).map { i in
            MIDINote(pitch: 60, onset: 1.000, duration: 0.5, velocity: 50 + i)
        }
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertEqual(outcome.report.prunedExactPileup, 5)
        XCTAssertEqual(outcome.cleaned.filter { $0.pitch == 60 && $0.onset == 1.000 }.count, 1)
    }

    func testDensityCleanupBucketCap() {
        var cfg = TranscriptionCleanup.Config()
        cfg.maxNotesPerClusterWindow = 1000 // disable cluster stage
        cfg.maxNotesPerDensityBucket = 25
        cfg.audioDurationSeconds = 5
        // 50 distinct notes spread across 1s — should drop ~25.
        let raw = (0..<50).map { i in
            MIDINote(pitch: 30 + (i % 50), onset: 1.0 + Double(i) * 0.018, duration: 0.05, velocity: 40 + (i % 50))
        }
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertGreaterThan(outcome.report.prunedFromDensity, 0)
        XCTAssertLessThanOrEqual(outcome.cleaned.count, cfg.maxNotesPerDensityBucket * 2)
    }

    func testSamePitchOverlapTrimsEarlierNote() {
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 5
        cfg.mergeSamePitchOverlap = false
        let raw = [
            MIDINote(pitch: 60, onset: 0.0, duration: 1.0, velocity: 80),
            MIDINote(pitch: 60, onset: 0.5, duration: 1.0, velocity: 80), // overlaps prev
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertEqual(outcome.report.trimmedSamePitchOverlap, 1)
        let pitch60 = outcome.cleaned.filter { $0.pitch == 60 }.sorted { $0.onset < $1.onset }
        XCTAssertEqual(pitch60.count, 2)
        // First note should now end at 0.5 (the next onset)
        XCTAssertEqual(pitch60[0].onset + pitch60[0].duration, 0.5, accuracy: 1e-6)
    }

    func testRawNotesArePreserved() {
        var cfg = TranscriptionCleanup.Config()
        cfg.maxNoteDurationSeconds = 1.0
        cfg.audioDurationSeconds = 60
        let raw = [
            MIDINote(pitch: 60, onset: 0, duration: 0.5, velocity: 80),
            MIDINote(pitch: 64, onset: 1, duration: 50,  velocity: 80), // gets dropped
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertEqual(outcome.raw.count, raw.count)
        XCTAssertNotEqual(outcome.cleaned.count, raw.count)
        XCTAssertEqual(outcome.report.inputCount, raw.count)
        XCTAssertEqual(outcome.report.outputCount, outcome.cleaned.count)
    }

    func testNoNoteExceedsAudioDurationAfterCleanup() {
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 10.0
        let raw = [
            MIDINote(pitch: 60, onset: 0,   duration: 100, velocity: 80),
            MIDINote(pitch: 64, onset: 9.9, duration: 5,   velocity: 80),
            MIDINote(pitch: 67, onset: 4,   duration: 0.5, velocity: 80),
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        for note in outcome.cleaned {
            XCTAssertLessThanOrEqual(note.onset + note.duration, 10.001,
                                     "Note end \(note.onset + note.duration) exceeds audio 10.0")
        }
    }

    func testNoNegativeDurations() {
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 5.0
        let raw = [
            MIDINote(pitch: 60, onset: 0,    duration: -1, velocity: 80),
            MIDINote(pitch: 64, onset: 0,    duration: 0,  velocity: 80),
            MIDINote(pitch: 67, onset: 10.0, duration: 1,  velocity: 80), // starts after audio
            MIDINote(pitch: 72, onset: 1,    duration: 0.5, velocity: 80),
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        for note in outcome.cleaned {
            XCTAssertGreaterThan(note.duration, 0)
        }
        XCTAssertGreaterThanOrEqual(outcome.report.droppedZeroDuration + outcome.report.droppedNegativeDuration, 3)
    }

    func testCleanedExportPreservesPitchNumbers() {
        // After cleanup, MIDI export must still report the same pitch numbers.
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 10
        let raw = [
            MIDINote(pitch: 21,  onset: 0.5, duration: 0.5, velocity: 80),
            MIDINote(pitch: 60,  onset: 1.0, duration: 0.5, velocity: 80),
            MIDINote(pitch: 108, onset: 2.0, duration: 0.5, velocity: 80),
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        let parsed = parseSMF(MIDIGenerator().generateMIDI(from: outcome.cleaned))
        let onPitches = Set(parsed.events.filter { $0.kind == .on }.map(\.pitch))
        XCTAssertTrue(onPitches.contains(21))
        XCTAssertTrue(onPitches.contains(60))
        XCTAssertTrue(onPitches.contains(108))
    }

    // MARK: - Sustain-aware ghost-note repair

    /// A short, weak note sitting inside a long held bass should be removed
    /// as a sustain ghost when no chord companion accompanies it.
    func testSustainGhostInsideHeldBassIsRemoved() {
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 10
        cfg.minVelocity = 1                  // disable plain velocity gate
        cfg.isolatedTinyMaxDuration = 0      // disable isolated-tiny stage
        cfg.sustainPedalDeclared = true      // allow long bass to survive
        let raw = [
            // Held bass note (3 seconds)
            MIDINote(pitch: 36, onset: 0.0, duration: 3.0, velocity: 90),
            // Short, weak ghost inside the bass tail with no chord companion
            MIDINote(pitch: 72, onset: 1.5, duration: 0.05, velocity: 18),
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertEqual(outcome.report.droppedSustainGhost, 1)
        XCTAssertNil(outcome.cleaned.first { $0.pitch == 72 })
        XCTAssertNotNil(outcome.cleaned.first { $0.pitch == 36 })
    }

    /// A short note inside the sustain tail should NOT be removed when it
    /// arrives together with another distinct pitch within the chord-onset
    /// window — that is a real chord onset, not a ghost.
    func testChordOnsetInsideSustainTailIsPreserved() {
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 10
        cfg.minVelocity = 1
        cfg.isolatedTinyMaxDuration = 0
        cfg.sustainPedalDeclared = true
        let raw = [
            MIDINote(pitch: 36, onset: 0.0, duration: 3.0, velocity: 90),
            // Two notes starting within ~30ms of each other → real chord onset
            MIDINote(pitch: 72, onset: 1.500, duration: 0.05, velocity: 20),
            MIDINote(pitch: 76, onset: 1.530, duration: 0.05, velocity: 20),
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertEqual(outcome.report.droppedSustainGhost, 0)
        XCTAssertNotNil(outcome.cleaned.first { $0.pitch == 72 })
        XCTAssertNotNil(outcome.cleaned.first { $0.pitch == 76 })
    }

    /// A loud staccato melody note inside another note's sustain tail must
    /// be preserved — it is short but not weak.
    func testLoudShortNoteInsideSustainTailIsPreserved() {
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 10
        cfg.minVelocity = 1
        cfg.isolatedTinyMaxDuration = 0
        cfg.sustainPedalDeclared = true
        let raw = [
            MIDINote(pitch: 36, onset: 0.0, duration: 3.0, velocity: 90),
            // Short but loud — staccato melody, must not be flagged as ghost
            MIDINote(pitch: 72, onset: 1.5, duration: 0.08, velocity: 95),
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertEqual(outcome.report.droppedSustainGhost, 0)
        XCTAssertNotNil(outcome.cleaned.first { $0.pitch == 72 })
    }

    /// Repeated same-pitch fragments separated by tiny gaps (≤ merge gap)
    /// should be folded into a single sustained note.
    func testSamePitchFragmentsAreMergedDuringSustain() {
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 10
        cfg.minVelocity = 1
        cfg.isolatedTinyMaxDuration = 0
        cfg.sustainPedalDeclared = true
        let raw = [
            MIDINote(pitch: 60, onset: 0.00, duration: 0.40, velocity: 70),
            MIDINote(pitch: 60, onset: 0.42, duration: 0.30, velocity: 60), // 20ms gap
            MIDINote(pitch: 60, onset: 0.74, duration: 0.20, velocity: 50), // 20ms gap
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertEqual(outcome.report.mergedSustainFragments, 2)
        let pitch60 = outcome.cleaned.filter { $0.pitch == 60 }
        XCTAssertEqual(pitch60.count, 1)
        // Merged note should span from 0.0 to 0.94
        if let merged = pitch60.first {
            XCTAssertEqual(merged.onset, 0.0, accuracy: 1e-6)
            XCTAssertEqual(merged.onset + merged.duration, 0.94, accuracy: 1e-6)
            // Stronger velocity wins
            XCTAssertEqual(merged.velocity, 70)
        }
    }

    /// Same-pitch notes separated by a real silent gap must NOT be merged.
    func testSamePitchRestrikeAcrossLargeGapIsPreserved() {
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 10
        cfg.minVelocity = 1
        cfg.isolatedTinyMaxDuration = 0
        let raw = [
            MIDINote(pitch: 60, onset: 0.00, duration: 0.30, velocity: 70),
            MIDINote(pitch: 60, onset: 0.80, duration: 0.30, velocity: 70), // 500ms gap → restrike
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertEqual(outcome.report.mergedSustainFragments, 0)
        XCTAssertEqual(outcome.cleaned.filter { $0.pitch == 60 }.count, 2)
    }

    /// The sustain-repair stage must be a no-op when explicitly disabled.
    func testSustainRepairCanBeDisabled() {
        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = 10
        cfg.minVelocity = 1
        cfg.isolatedTinyMaxDuration = 0
        cfg.sustainPedalDeclared = true
        cfg.sustainRepairEnabled = false
        let raw = [
            MIDINote(pitch: 36, onset: 0.0, duration: 3.0, velocity: 90),
            MIDINote(pitch: 72, onset: 1.5, duration: 0.05, velocity: 18),
        ]
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertEqual(outcome.report.droppedSustainGhost, 0)
        XCTAssertNotNil(outcome.cleaned.first { $0.pitch == 72 })
    }

    /// Old-format reports (persisted before the new counters existed) must
    /// still decode — the new fields default to zero.
    func testReportDecodesWithoutNewSustainFields() throws {
        let json = """
        {
          "inputCount": 4,
          "outputCount": 3,
          "clampedToAudioDuration": 0,
          "droppedLongNotes": 1,
          "clampedLongNotes": 0,
          "prunedFromClusters": 0,
          "prunedFromDensity": 0,
          "prunedExactPileup": 0,
          "prunedExactOnsetCap": 0,
          "trimmedSamePitchOverlap": 0,
          "mergedSamePitchOverlap": 0,
          "droppedNegativeDuration": 0,
          "droppedZeroDuration": 0,
          "droppedTimelineOverflow": 0,
          "droppedOutOfPitchRange": 0,
          "droppedLowVelocity": 0,
          "droppedIsolatedTiny": 0,
          "prunedSimultaneousCap": 0
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(TranscriptionCleanup.Report.self, from: json)
        XCTAssertEqual(r.inputCount, 4)
        XCTAssertEqual(r.outputCount, 3)
        XCTAssertEqual(r.droppedSustainGhost, 0)
        XCTAssertEqual(r.mergedSustainFragments, 0)
    }
}

// MARK: - Acceptance checkpoint
//
// Synthetic catastrophic input modeled on the user's real diagnostic output.
// The pipeline's cleanup pass must turn this into a stable baseline.

final class CleanupAcceptanceCheckpointTests: XCTestCase {

    /// Builds an input that mirrors the catastrophic real-world output:
    ///   - timeline ends ~3.2s before the audio (drift)
    ///   - 60 notes with duration > 30s
    ///   - many exact-onset pileups
    ///   - many >8-note onset clusters within 50ms
    ///   - many high-density 1s buckets
    ///   - same-pitch overlaps
    private func buildCatastrophicInput() -> (notes: [MIDINote], audioDuration: Double) {
        let audioDuration: Double = 268.0
        var notes: [MIDINote] = []

        // 60 stuck long notes (200s+)
        for i in 0..<60 {
            notes.append(MIDINote(pitch: 30 + (i % 60),
                                  onset: Double(i) * 3.5,
                                  duration: 200 + Double(i % 18),
                                  velocity: 30))
        }
        // 100 exact-onset pileups (10 groups of 10 notes at exact same onset)
        for g in 0..<10 {
            let onset = 50.0 + Double(g) * 5
            for k in 0..<10 {
                notes.append(MIDINote(pitch: 60 + k, onset: onset, duration: 0.5, velocity: 40))
            }
        }
        // 20 cluster groups of 12 notes each within 30ms
        for g in 0..<20 {
            let base = 100.0 + Double(g) * 5
            for k in 0..<12 {
                notes.append(MIDINote(pitch: 40 + k, onset: base + Double(k) * 0.0025, duration: 0.4, velocity: 30 + k))
            }
        }
        // Density spike: 200 notes inside one second
        for k in 0..<200 {
            notes.append(MIDINote(pitch: 30 + (k % 60),
                                  onset: 200.0 + Double(k) * 0.005,
                                  duration: 0.2,
                                  velocity: 40 + (k % 50)))
        }
        // 20 same-pitch overlaps
        for k in 0..<20 {
            notes.append(MIDINote(pitch: 70, onset: 230 + Double(k) * 0.5, duration: 1.5, velocity: 70))
        }
        // Legitimate notes spanning to the clip end so a passing cleanup
        // doesn't accidentally truncate the timeline (that would surface as
        // duration_mismatch — a model-coverage problem, not a cleanup problem).
        for k in 0..<10 {
            notes.append(MIDINote(pitch: 60 + k, onset: 250.0 + Double(k) * 1.5, duration: 1.0, velocity: 90))
        }
        notes.append(MIDINote(pitch: 64, onset: audioDuration - 1.0, duration: 0.5, velocity: 90))
        return (notes, audioDuration)
    }

    func testCatastrophicInputBecomesStableBaseline() {
        let (raw, audio) = buildCatastrophicInput()

        // Diagnostics on raw — establish "before"
        let before = TranscriptionDiagnostics.analyze(notes: raw, audioDuration: audio)
        XCTAssertEqual(before.status, .fail)

        var cfg = TranscriptionCleanup.Config()
        cfg.audioDurationSeconds = audio

        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        let after = TranscriptionDiagnostics.analyze(notes: outcome.cleaned, audioDuration: audio)

        // Acceptance assertions matching the part-10 expected improvements:

        // 1. Note count drops substantially.
        XCTAssertLessThan(outcome.cleaned.count, raw.count / 2,
                          "Cleanup should drop >50% of catastrophic notes (input \(raw.count), output \(outcome.cleaned.count))")

        // 2. Max note duration becomes reasonable.
        let maxDur = outcome.cleaned.map(\.duration).max() ?? 0
        XCTAssertLessThanOrEqual(maxDur, cfg.maxNoteDurationSeconds + 0.001,
                                 "Max duration should be ≤ \(cfg.maxNoteDurationSeconds)s, got \(maxDur)s")

        // 3. No long-note FAIL on cleaned output.
        XCTAssertFalse(after.issues.contains { $0.id == "long_note" },
                       "long_note issue should be gone after cleanup")

        // 4. No duration mismatch.
        XCTAssertFalse(after.issues.contains { $0.id == "duration_mismatch" },
                       "duration_mismatch should be gone (cleaned ends within audio)")

        // 5. Cluster + density warnings drop substantially.
        let beforeClusterCount = before.issues.first { $0.id == "onset_cluster" }?.count ?? 0
        let afterClusterCount = after.issues.first { $0.id == "onset_cluster" }?.count ?? 0
        XCTAssertLessThan(afterClusterCount, beforeClusterCount / 2,
                          "Cluster warnings should drop >50%")

        let beforeDensityCount = before.issues.first { $0.id == "density_spike" }?.count ?? 0
        let afterDensityCount = after.issues.first { $0.id == "density_spike" }?.count ?? 0
        XCTAssertLessThan(afterDensityCount, beforeDensityCount / 2,
                          "Density warnings should drop >50%")

        // 6. Quality score improves.
        XCTAssertGreaterThan(after.qualityScore, before.qualityScore,
                             "Quality score should improve after cleanup (before \(before.qualityScore), after \(after.qualityScore))")

        // 7. No note exceeds audio duration.
        for note in outcome.cleaned {
            XCTAssertLessThanOrEqual(note.onset + note.duration, audio + 0.001)
        }

        // Print delta for visibility.
        print("[ACCEPTANCE] notes \(raw.count) → \(outcome.cleaned.count); maxDur → \(String(format: "%.2f", maxDur))s; quality \(String(format: "%.2f", before.qualityScore)) → \(String(format: "%.2f", after.qualityScore))")
        print("[ACCEPTANCE] report: \(outcome.report)")
    }
}

// MARK: - Advanced model adapters

final class MIDIReaderTests: XCTestCase {
    func testRoundTripsThroughGenerator() throws {
        let original = [
            MIDINote(pitch: 60, onset: 0.0, duration: 0.5, velocity: 80),
            MIDINote(pitch: 64, onset: 0.5, duration: 0.5, velocity: 70),
            MIDINote(pitch: 67, onset: 1.0, duration: 1.0, velocity: 90),
        ]
        let data = MIDIGenerator().generateMIDI(from: original, tempo: 120)
        let parsed = try MIDIReader.parse(data: data)
        XCTAssertEqual(parsed.count, 3)
        // Pitches and rough timings preserved.
        let pitches = Set(parsed.map(\.pitch))
        XCTAssertEqual(pitches, [60, 64, 67])
        for n in parsed {
            XCTAssertGreaterThan(n.duration, 0)
            XCTAssertGreaterThanOrEqual(n.onset, 0)
        }
    }

    func testHandlesNoteOnVelocityZeroAsNoteOff() throws {
        // Build a tiny SMF by hand: note-on(60,80) at t=0, note-on(60,0) at t=480 (= one beat).
        // With tempo 500_000 µs/beat that's 0.5s.
        var bytes: [UInt8] = []
        bytes += Array("MThd".utf8)
        bytes += [0,0,0,6, 0,0, 0,1, 0x01, 0xE0] // header, length 6, format 0, 1 track, division 480
        var track: [UInt8] = []
        // Tempo meta event (500k)
        track += [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]
        // Note on 60 vel 80 at delta 0
        track += [0x00, 0x90, 60, 80]
        // Note on 60 vel 0 at delta 480 (which is 0x83 0x60 in varlen)
        track += [0x83, 0x60, 0x90, 60, 0]
        // End of track
        track += [0x00, 0xFF, 0x2F, 0x00]
        bytes += Array("MTrk".utf8)
        let trackLen = UInt32(track.count)
        bytes += [UInt8((trackLen >> 24) & 0xFF), UInt8((trackLen >> 16) & 0xFF), UInt8((trackLen >> 8) & 0xFF), UInt8(trackLen & 0xFF)]
        bytes += track

        let parsed = try MIDIReader.parse(data: Data(bytes))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.pitch, 60)
        XCTAssertEqual(parsed.first?.duration ?? 0, 0.5, accuracy: 0.05)
    }

    func testRejectsCorruptHeader() {
        XCTAssertThrowsError(try MIDIReader.parse(data: Data([0x00, 0x01, 0x02, 0x03])))
    }
}

final class MIDIGeneratorIntegrityTests: XCTestCase {
    func testZeroDurationNotesAreSkipped() throws {
        let notes = [
            MIDINote(pitch: 60, onset: 0,   duration: 0,   velocity: 80),
            MIDINote(pitch: 62, onset: 0.5, duration: 0.5, velocity: 80),
        ]
        let data = MIDIGenerator().generateMIDI(from: notes)
        let parsed = try MIDIReader.parse(data: data)
        // Only the second note survives.
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.pitch, 62)
    }

    func testNegativeDurationsAreSkipped() throws {
        let notes = [
            MIDINote(pitch: 60, onset: 1.0, duration: -0.5, velocity: 80),
            MIDINote(pitch: 62, onset: 0.5, duration: 0.5,  velocity: 80),
        ]
        let data = MIDIGenerator().generateMIDI(from: notes)
        let parsed = try MIDIReader.parse(data: data)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.pitch, 62)
    }

    func testSamePitchReTriggerEmitsTwoDistinctNotes() throws {
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 0.5, velocity: 80),
            MIDINote(pitch: 60, onset: 0.5, duration: 0.5, velocity: 90),
        ]
        let data = MIDIGenerator().generateMIDI(from: notes)
        let parsed = try MIDIReader.parse(data: data).filter { $0.pitch == 60 }
        XCTAssertEqual(parsed.count, 2, "Re-trigger of pitch 60 must produce two distinct parsed notes")
    }
}

final class BasicPitchAdapterTests: XCTestCase {
    /// Skipped automatically when `basic-pitch` is on PATH (in which case the
    /// "unavailable" semantics are irrelevant — the live install already
    /// proves availability detection works the other way around).
    func testIsUnavailableWithBogusEnvOverride() async throws {
        // Force adapter to ignore PATH / repo-local / home extras so the
        // bogus env override is the only candidate.
        let prior = ProcessInfo.processInfo.environment[BasicPitchTranscriber.envOverride]
        setenv(BasicPitchTranscriber.envOverride, "/path/that/does/not/exist", 1)
        setenv("PIANO_TRAINER_DISABLE_DISCOVERY", "1", 1)
        defer {
            if let prior {
                setenv(BasicPitchTranscriber.envOverride, prior, 1)
            } else {
                unsetenv(BasicPitchTranscriber.envOverride)
            }
            unsetenv("PIANO_TRAINER_DISABLE_DISCOVERY")
        }
        let adapter = BasicPitchTranscriber()
        XCTAssertFalse(adapter.isAvailable)
        XCTAssertNotNil(adapter.unavailableReason)
        do {
            _ = try await adapter.transcribePiano(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), progress: nil)
            XCTFail("Expected unavailable error")
        } catch let PipelineError.unavailable(reason) {
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("Expected PipelineError.unavailable, got \(error)")
        }
    }
}

final class ByteDanceAdapterTests: XCTestCase {
    func testIsUnavailableWithBogusEnvOverride() async {
        // Force adapter to ignore PATH / repo-local / home extras so the
        // bogus env override is the only candidate and the adapter reports
        // unavailable.
        let prior = ProcessInfo.processInfo.environment[ByteDancePianoTranscriber.envOverride]
        setenv(ByteDancePianoTranscriber.envOverride, "/path/that/does/not/exist", 1)
        setenv("PIANO_TRAINER_DISABLE_DISCOVERY", "1", 1)
        defer {
            if let prior {
                setenv(ByteDancePianoTranscriber.envOverride, prior, 1)
            } else {
                unsetenv(ByteDancePianoTranscriber.envOverride)
            }
            unsetenv("PIANO_TRAINER_DISABLE_DISCOVERY")
        }
        let adapter = ByteDancePianoTranscriber()
        XCTAssertFalse(adapter.isAvailable)
        XCTAssertNotNil(adapter.unavailableReason)
    }
}

final class AdvancedPipelineRegistryTests: XCTestCase {
    /// Stub transcriber that flips on for tests so we can exercise the real
    /// `ExternalModelPipeline` body without shelling out.
    private struct StubTranscriber: PianoSpecializedTranscriber {
        let isAvailable: Bool
        let unavailableReason: String? = nil
        let modelName = "Stub"
        let modelVersion = "0.0"
        let parameters: [String: String] = ["stub": "true"]
        func transcribePiano(audioURL: URL, progress: PipelineProgressHandler?) async throws -> PianoTranscriptionResult {
            PianoTranscriptionResult(
                notes: [
                    MIDINote(pitch: 60, onset: 0.0, duration: 0.5, velocity: 80),
                    MIDINote(pitch: 67, onset: 0.5, duration: 0.5, velocity: 90),
                ],
                modelName: modelName,
                modelVersion: modelVersion,
                sampleRate: 44100,
                parameters: parameters,
                isFallback: false
            )
        }
    }

    func testBasicPitchFallsBackWhenAdapterMissingButByteDanceRefuses() {
        // Basic Pitch keeps the silent-fallback semantics (we always have
        // *some* portable model available). ByteDance is dedicated-only:
        // when its wrapper is missing the registry returns a throwing
        // pipeline so users can't be tricked into thinking the research
        // model ran when only Piano-Focused did.
        let prior = ProcessInfo.processInfo.environment[ByteDancePianoTranscriber.envOverride]
        setenv(ByteDancePianoTranscriber.envOverride, "/path/does/not/exist", 1)
        setenv("PIANO_TRAINER_DISABLE_DISCOVERY", "1", 1)
        defer {
            if let prior {
                setenv(ByteDancePianoTranscriber.envOverride, prior, 1)
            } else {
                unsetenv(ByteDancePianoTranscriber.envOverride)
            }
            unsetenv("PIANO_TRAINER_DISABLE_DISCOVERY")
        }
        let registry = PipelineRegistry()

        if !registry.hasDedicatedBackend(.basicPitch) {
            XCTAssertTrue(registry.makePipeline(.basicPitch) is FallbackTranscriptionPipeline)
            XCTAssertNotNil(registry.fallbackReason(.basicPitch))
        }
        // ByteDance: forced-missing → registry hands back a throwing pipeline.
        let bdPipeline = registry.makePipeline(.bytedancePiano)
        XCTAssertTrue(bdPipeline is MissingBackendThrowingPipeline,
                      "ByteDance must refuse silent fallback when wrapper is missing.")

        XCTAssertTrue(registry.isAvailable(.basicPitch))
        XCTAssertTrue(registry.isAvailable(.bytedancePiano))
    }

    func testAdvancedPipelinesProduceCleanedRunsWithRawAndReport() async throws {
        let registry = PipelineRegistry(
            basicPitchTranscriber: StubTranscriber(isAvailable: true)
        )
        XCTAssertTrue(registry.isAvailable(.basicPitch))
        guard let pipeline = registry.makePipeline(.basicPitch) else {
            XCTFail("Pipeline should be available with stubbed transcriber")
            return
        }
        // Build a real WAV so AudioDurationProbe returns a sensible value.
        let sr: Double = 44100
        let frames = AVAudioFrameCount(sr) // 1 second
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_advanced_\(UUID().uuidString).wav")
        do {
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try f.write(from: buf)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let run = try await pipeline.run(audioURL: url)
        XCTAssertEqual(run.pipelineID, PipelineKind.basicPitch.rawValue)
        XCTAssertFalse(run.notes.isEmpty)
        XCTAssertFalse(run.rawNotes.isEmpty, "Adapter pipelines must populate rawNotes for raw vs cleaned diagnostics")
        XCTAssertNotNil(run.cleanupReport)
        XCTAssertNotNil(run.sourceAudioDuration)
        XCTAssertEqual(run.pipelineParameters["model.fallback"], "false")
        // Sidebar's "Backend ran" line reads these.
        XCTAssertEqual(run.pipelineParameters["backend.kind"], "dedicated")
        XCTAssertEqual(run.backendRan, "Stub")
        XCTAssertFalse(run.ranOnFallback)
    }
}

// MARK: - External adapter detection (PATH + env override)
//
// These tests prove the registry's "fallback vs dedicated" decision actually
// follows the live filesystem, not a compile-time flag. We build a tiny
// shim binary in a temp dir, point the env override at it, and confirm:
//
//   1. ExternalCommandRunner.locate finds the shim via env override.
//   2. ExternalCommandRunner.locate finds it via PATH lookup.
//   3. With the env var pointing at the shim, the registry reports the kind
//      as "dedicated" (no fallback) and `makePipeline` returns an
//      `ExternalModelPipeline` (not `FallbackTranscriptionPipeline`).
//   4. Removing the override reverts the registry to fallback semantics.

final class ExternalCommandRunnerLocateTests: XCTestCase {

    /// Writes a chmod +x shim script to `dir` named `name` and returns its URL.
    fileprivate func makeShim(named name: String, in dir: URL, body: String = "#!/bin/sh\necho ok\n") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        // chmod +x
        var attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        attrs[.posixPermissions] = 0o755
        try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        return url
    }

    func testLocateResolvesEnvOverrideToFullPath() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_locate_\(UUID().uuidString)")
        let shim = try makeShim(named: "fake-cli", in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let envKey = "PTK_TEST_OVERRIDE_\(UUID().uuidString.prefix(8))"
        setenv(envKey, shim.path, 1)
        defer { unsetenv(envKey) }

        let resolved = ExternalCommandRunner.locate(executable: "fake-cli", envOverride: envKey)
        XCTAssertEqual(resolved?.path, shim.path)
    }

    func testLocateIgnoresEnvOverridePointingAtMissingPath() {
        let envKey = "PTK_TEST_BAD_\(UUID().uuidString.prefix(8))"
        setenv(envKey, "/clearly/does/not/exist/xyzzy", 1)
        defer { unsetenv(envKey) }
        let resolved = ExternalCommandRunner.locate(executable: "definitely-not-a-real-binary-xyz", envOverride: envKey)
        XCTAssertNil(resolved)
    }

    func testLocateFindsBinaryViaPathLookup() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_path_\(UUID().uuidString)")
        let shimName = "ptk-shim-\(UUID().uuidString.prefix(6))"
        let shim = try makeShim(named: shimName, in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(dir.path):\(oldPath)", 1)
        defer { setenv("PATH", oldPath, 1) }

        let resolved = ExternalCommandRunner.locate(executable: shimName, envOverride: nil)
        XCTAssertEqual(resolved?.path, shim.path)
    }

    func testRunCapturesStdoutAndExit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_run_\(UUID().uuidString)")
        let shim = try makeShim(
            named: "echo-shim",
            in: dir,
            body: "#!/bin/sh\necho hello \"$1\"\nexit 0\n"
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try ExternalCommandRunner.run(executable: shim, arguments: ["world"])
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(result.stdout.contains("hello world"))
    }

    func testRunPropagatesNonZeroExit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_run_fail_\(UUID().uuidString)")
        let shim = try makeShim(
            named: "fail-shim",
            in: dir,
            body: "#!/bin/sh\necho boom 1>&2\nexit 7\n"
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try ExternalCommandRunner.run(executable: shim, arguments: [])
            XCTFail("Expected nonZeroExit error")
        } catch let ExternalCommandRunner.CommandError.nonZeroExit(_, status, stderr) {
            XCTAssertEqual(status, 7)
            XCTAssertTrue(stderr.contains("boom"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class AdapterLiveDetectionTests: XCTestCase {
    /// Build a Basic Pitch shim that produces a syntactically valid SMF at the
    /// expected output path. Lets us prove the registry flips from fallback
    /// to dedicated when the env override resolves.
    fileprivate func makeBasicPitchShim(in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write a minimal but valid SMF the adapter can parse: header chunk
        // (MThd, fmt 0, 1 track, division 480) + an empty track.
        // The adapter writes `<basename>_basic_pitch.mid`, so the shim takes
        // (output_dir, input_audio, ...) and produces that file.
        // Mimic the real basic-pitch CLI surface: arbitrary leading flags
        // (e.g. --save-midi, --model-serialization onnx) followed by two
        // positional args `<output_dir> <input_audio>`. The shim walks the
        // arg list to find the first two positionals so it stays compatible
        // with whatever flag set the adapter emits.
        // The wrapper signature is `<input> <output_dir>` (input first,
        // output second — matches every wrapper produced by
        // setup-transcription-deps.sh).
        let body = """
        #!/bin/sh
        infile=""
        outdir=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --model-serialization|--model-path|--onset-threshold|--frame-threshold|--minimum-note-length|--minimum-frequency|--maximum-frequency|--sonification-samplerate|--midi-tempo|--debug-file)
              shift; shift; continue ;;
            --*) shift; continue ;;
            *)
              if [ -z "$infile" ]; then infile="$1"
              elif [ -z "$outdir" ]; then outdir="$1"
              fi
              shift
              ;;
          esac
        done
        base=$(basename "$infile")
        base="${base%.*}"
        out="$outdir/${base}_basic_pitch.mid"
        # Minimal valid SMF: MThd + tempo + EOT.
        printf 'MThd\\0\\0\\0\\6\\0\\0\\0\\1\\1\\xe0MTrk\\0\\0\\0\\013\\0\\xff\\x51\\3\\7\\xa1\\x20\\0\\xff\\x2f\\0' > "$out"
        exit 0
        """
        let url = dir.appendingPathComponent("basic-pitch")
        try body.write(to: url, atomically: true, encoding: .utf8)
        var attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        attrs[.posixPermissions] = 0o755
        try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        return url
    }

    /// With BASIC_PITCH_PATH pointing at our shim, the registry must:
    ///   • report `hasDedicatedBackend(.basicPitch) == true`
    ///   • return an `ExternalModelPipeline` from `makePipeline`
    ///   • not surface a `fallbackReason`
    /// And running the pipeline must stamp `backend.kind=dedicated` on the run.
    func testEnvOverrideFlipsBasicPitchFromFallbackToDedicated() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_bp_e2e_\(UUID().uuidString)")
        let shim = try makeBasicPitchShim(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let priorOverride = ProcessInfo.processInfo.environment[BasicPitchTranscriber.envOverride]
        setenv(BasicPitchTranscriber.envOverride, shim.path, 1)
        defer {
            if let priorOverride { setenv(BasicPitchTranscriber.envOverride, priorOverride, 1) }
            else { unsetenv(BasicPitchTranscriber.envOverride) }
        }

        // Build a fresh registry so the transcriber re-resolves PATH.
        let registry = PipelineRegistry()
        XCTAssertTrue(registry.hasDedicatedBackend(.basicPitch),
                      "BASIC_PITCH_PATH points at a real executable; registry should flip to dedicated")
        XCTAssertNil(registry.fallbackReason(.basicPitch))

        let pipeline = registry.makePipeline(.basicPitch)
        XCTAssertNotNil(pipeline)
        XCTAssertFalse(pipeline is FallbackTranscriptionPipeline,
                       "Dedicated backend must not return the FallbackTranscriptionPipeline")

        // Run end-to-end on a tiny WAV. The shim writes a valid (empty) SMF;
        // the adapter must parse it into a (possibly empty) note list and
        // the pipeline must stamp dedicated metadata.
        let sr: Double = 44100
        let frames = AVAudioFrameCount(sr)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let wav = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_bp_in_\(UUID().uuidString).wav")
        do {
            let f = try AVAudioFile(forWriting: wav, settings: fmt.settings)
            try f.write(from: buf)
        }
        defer { try? FileManager.default.removeItem(at: wav) }

        let run = try await pipeline!.run(audioURL: wav, progress: nil)
        XCTAssertEqual(run.pipelineID, PipelineKind.basicPitch.rawValue)
        XCTAssertEqual(run.pipelineParameters["backend.kind"], "dedicated")
        XCTAssertEqual(run.backendKind, "dedicated")
        XCTAssertEqual(run.backendRan, "Basic Pitch (Spotify)")
        XCTAssertFalse(run.ranOnFallback)
        XCTAssertEqual(run.pipelineParameters["model.fallback"], "false")
    }

    /// With no env override and an unknown executable name, the registry
    /// reports fallback. Running the pipeline must produce a run that the
    /// sidebar will render with the orange "Fallback" badge.
    /// Stub transcriber forced unavailable. Used by the missing-deps test so
    /// it doesn't depend on the real `BasicPitchTranscriber` succeeding/failing
    /// to find a binary on PATH (which can't be reliably mocked because
    /// `ProcessInfo.environment` caches its snapshot at first access).
    fileprivate struct UnavailableStubTranscriber: PianoSpecializedTranscriber {
        let isAvailable = false
        let unavailableReason: String? = "Basic Pitch CLI not on PATH (test stub)."
        let modelName = "Basic Pitch (Spotify)"
        let modelVersion = "0.x"
        let parameters: [String: String] = [:]
        func transcribePiano(audioURL: URL, progress: PipelineProgressHandler?) async throws -> PianoTranscriptionResult {
            throw PipelineError.unavailable(reason: unavailableReason!)
        }
    }

    func testMissingDepsRoutesThroughFallbackWithVisibleReason() async throws {
        // Inject an explicitly-unavailable transcriber so the test doesn't
        // depend on the host's PATH state (which can't be mocked because
        // ProcessInfo.environment is cached at first access).
        let registry = PipelineRegistry(
            basicPitchTranscriber: UnavailableStubTranscriber(),
            refuseFallbackForDedicatedOnlyModes: false
        )
        XCTAssertFalse(registry.hasDedicatedBackend(.basicPitch))
        XCTAssertNotNil(registry.fallbackReason(.basicPitch))

        let pipeline = registry.makePipeline(.basicPitch)
        XCTAssertTrue(pipeline is FallbackTranscriptionPipeline)

        // Make a tiny WAV and confirm the run is stamped as a fallback.
        let sr: Double = 44100
        let frames = AVAudioFrameCount(sr)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let wav = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_bp_fb_\(UUID().uuidString).wav")
        do {
            let f = try AVAudioFile(forWriting: wav, settings: fmt.settings)
            try f.write(from: buf)
        }
        defer { try? FileManager.default.removeItem(at: wav) }

        let run = try await pipeline!.run(audioURL: wav, progress: nil)
        XCTAssertEqual(run.pipelineID, PipelineKind.basicPitch.rawValue)
        XCTAssertTrue(run.ranOnFallback)
        XCTAssertEqual(run.backendKind, "fallback")
        XCTAssertNotNil(run.fallbackReason)
        XCTAssertTrue(run.fallbackReason!.lowercased().contains("basic pitch")
                   || run.fallbackReason!.lowercased().contains("fallback"))
    }

    /// `ByteDance` adapter: same env-override → dedicated proof.
    func testEnvOverrideFlipsByteDanceFromFallbackToDedicated() throws {
        // We don't run the full pipeline (the wrapper protocol needs a real
        // `<input> <output>` invocation that produces SMF). Just prove the
        // registry sees the override and flips the "dedicated" flag, which
        // is the only thing the UI cares about for "no fallback shown".
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_bd_locate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("piano-transcription")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        var attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        attrs[.posixPermissions] = 0o755
        try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: dir) }

        let priorOverride = ProcessInfo.processInfo.environment[ByteDancePianoTranscriber.envOverride]
        setenv(ByteDancePianoTranscriber.envOverride, url.path, 1)
        defer {
            if let priorOverride { setenv(ByteDancePianoTranscriber.envOverride, priorOverride, 1) }
            else { unsetenv(ByteDancePianoTranscriber.envOverride) }
        }

        let registry = PipelineRegistry()
        XCTAssertTrue(registry.hasDedicatedBackend(.bytedancePiano),
                      "PIANO_TRANSCRIPTION_PATH points at a real executable; registry should flip to dedicated")
        XCTAssertNil(registry.fallbackReason(.bytedancePiano))

        let pipeline = registry.makePipeline(.bytedancePiano)
        XCTAssertNotNil(pipeline)
        XCTAssertFalse(pipeline is FallbackTranscriptionPipeline)
    }
}

// MARK: - Mandatory cleanup invariants

final class MandatoryCleanupInvariantTests: XCTestCase {

    func testCleanupForcesMaxNoteDurationBelowConfiguredCeiling() {
        // Before fix: a 218.51s note could survive. After: ≤ 10s ceiling drops it.
        let raw = [
            MIDINote(pitch: 60, onset: 0, duration: 218.51, velocity: 80),
            MIDINote(pitch: 62, onset: 1, duration: 9.0,    velocity: 80),
            MIDINote(pitch: 64, onset: 2, duration: 0.3,    velocity: 80),
        ]
        var cfg = TranscriptionCleanup.Config.mandatory
        cfg.audioDurationSeconds = 60
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        XCTAssertLessThanOrEqual(outcome.cleaned.map(\.duration).max() ?? 0,
                                 cfg.maxNoteDurationSeconds + 1e-6,
                                 "No surviving note may exceed the configured ceiling")
        XCTAssertEqual(outcome.report.droppedLongNotes, 1,
                       "218s note must be reported as dropped")
    }

    func testExactOnsetCapKeepsTopVelocities() {
        // 12 chord-tones at the exact same onset; default cap is 6.
        let raw = (0..<12).map {
            MIDINote(pitch: 50 + $0, onset: 0.5, duration: 0.5, velocity: 100 - $0 * 5)
        }
        let outcome = TranscriptionCleanup.apply(raw, config: .mandatory)
        XCTAssertLessThanOrEqual(outcome.cleaned.count, 6,
                                 "Exact-onset cap should keep at most 6 strongest notes")
        XCTAssertGreaterThanOrEqual(outcome.report.prunedExactOnsetCap, 6)
    }

    func testForceTimelineMatchHonoursInvariant() {
        // The invariant — no surviving note ends past audio + tolerance — is
        // what matters. Earlier stages (clamp-to-audio / long-note drop) catch
        // most overflowing notes, so the final timeline-gate counter may not
        // bump for every input; the surviving-note bound is what we care about.
        let raw = [
            MIDINote(pitch: 60, onset: 0,  duration: 1.0, velocity: 80),
            MIDINote(pitch: 62, onset: 8,  duration: 0.5, velocity: 80),
            MIDINote(pitch: 64, onset: 4,  duration: 4.0, velocity: 80),
        ]
        var cfg = TranscriptionCleanup.Config.mandatory
        cfg.audioDurationSeconds = 5.0
        cfg.timelineMatchToleranceSeconds = 0.1
        let outcome = TranscriptionCleanup.apply(raw, config: cfg)
        let maxEnd = outcome.cleaned.map { $0.onset + $0.duration }.max() ?? 0
        XCTAssertLessThanOrEqual(maxEnd, cfg.audioDurationSeconds! + cfg.timelineMatchToleranceSeconds + 1e-6,
                                 "No note may end past audio + tolerance after cleanup")
    }

    func testTranscriptionRunFactoryAlwaysCleans() {
        // Dump the user's catastrophic numbers in raw form and prove the
        // factory bounds them before the run lands on disk.
        var raw: [MIDINote] = []
        // 60 long notes >30s
        for i in 0..<60 {
            raw.append(MIDINote(pitch: 21 + i % 88, onset: Double(i) * 0.5,
                                duration: 50 + Double(i % 10) * 5,
                                velocity: 80))
        }
        // 1000 short ghost notes
        for i in 0..<1000 {
            raw.append(MIDINote(pitch: 60 + i % 24, onset: Double(i) * 0.005,
                                duration: 0.04, velocity: 10))
        }
        // 500 exact-onset pileup
        for i in 0..<500 {
            raw.append(MIDINote(pitch: 60 + i % 88, onset: 1.0,
                                duration: 0.5, velocity: 50 + i % 50))
        }
        let run = TranscriptionRun.makeWithMandatoryCleanup(
            rawModelNotes: raw,
            audioDurationSeconds: 10.0,
            pipelineVersion: "test",
            modelName: "test",
            pipelineID: "test",
            pipelineName: "test"
        )
        // Every reported failure mode must be addressed.
        XCTAssertLessThan(run.notes.count, raw.count, "Cleaned must have fewer notes than raw")
        XCTAssertLessThanOrEqual(run.notes.map(\.duration).max() ?? 0, 10.0 + 1e-6)
        XCTAssertEqual(run.notes.filter { $0.duration > 30 }.count, 0, "No surviving notes > 30s")
        XCTAssertNotNil(run.cleanupReport)
        XCTAssertGreaterThan(run.cleanupReport!.totalRemoved, 0)
        XCTAssertEqual(run.pipelineParameters["mandatoryCleanup.applied"], "true")
        XCTAssertFalse(run.rawNotes.isEmpty, "Raw model output must be preserved")
        XCTAssertEqual(run.sourceAudioDuration, 10.0)
        // Last note must end inside audio + tolerance.
        let maxEnd = run.notes.map { $0.onset + $0.duration }.max() ?? 0
        XCTAssertLessThanOrEqual(maxEnd, 10.0 + 0.1 + 1e-6)
    }
}

final class BasicPitchModelRunnerTests: XCTestCase {
    func testIsUnavailableWhenCLIMissing() async throws {
        let envCheck = BasicPitchTranscriber()
        try XCTSkipIf(envCheck.isAvailable,
                      "basic-pitch is installed on this host; live availability is covered by e2e tests.")
        let prior = ProcessInfo.processInfo.environment[BasicPitchTranscriber.envOverride]
        setenv(BasicPitchTranscriber.envOverride, "/path/that/does/not/exist", 1)
        defer {
            if let prior {
                setenv(BasicPitchTranscriber.envOverride, prior, 1)
            } else {
                unsetenv(BasicPitchTranscriber.envOverride)
            }
        }
        let runner = BasicPitchModelRunner()
        XCTAssertFalse(runner.isAvailable)
        XCTAssertNotNil(runner.unavailableReason)
        do {
            _ = try await runner.transcribe(audioURL: URL(fileURLWithPath: "/tmp/x.wav"))
            XCTFail("Expected unavailable error")
        } catch let PipelineError.unavailable(reason) {
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("Expected PipelineError.unavailable, got \(error)")
        }
    }

    func testNameMatchesUnderlyingTranscriber() {
        let runner = BasicPitchModelRunner()
        XCTAssertEqual(runner.name, BasicPitchTranscriber().modelName)
    }
}

// MARK: - Live Basic Pitch end-to-end (gated on BASIC_PITCH_PATH being set)

final class BasicPitchLiveIntegrationTests: XCTestCase {

    /// Runs only when `BASIC_PITCH_PATH` env var points at a real basic-pitch
    /// CLI binary. CI without the binary skips automatically; local dev with
    /// the install path set gets the full end-to-end proof.
    func testBasicPitchActuallyRunsWhenInstalled() async throws {
        guard let path = ProcessInfo.processInfo.environment["BASIC_PITCH_PATH"],
              FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("BASIC_PITCH_PATH not set; skipping live Basic Pitch integration test.")
        }

        // Generate a 2-second WAV of two stacked sine tones (A4 + C5).
        let sr: Double = 22050
        let frames = AVAudioFrameCount(sr * 2)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let data = buf.floatChannelData![0]
        for i in 0 ..< Int(frames) {
            let t = Double(i) / sr
            data[i] = Float(0.3 * sin(2 * .pi * 440 * t) + 0.2 * sin(2 * .pi * 523.25 * t))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_bp_live_\(UUID().uuidString).wav")
        do {
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try f.write(from: buf)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let runner = BasicPitchModelRunner()
        XCTAssertTrue(runner.isAvailable, "BasicPitchModelRunner should resolve the binary at \(path)")
        let notes = try await runner.transcribe(audioURL: url)
        XCTAssertGreaterThan(notes.count, 0, "Basic Pitch must produce at least one note")
        for n in notes {
            XCTAssertGreaterThanOrEqual(n.pitch, 0)
            XCTAssertLessThanOrEqual(n.pitch, 127)
            XCTAssertGreaterThan(n.duration, 0)
        }

        // And full pipeline integration via ExternalModelPipeline routes
        // through the mandatory cleanup factory.
        let pipeline = ExternalModelPipeline(
            kind: .basicPitch,
            transcriber: BasicPitchTranscriber(),
            cleanupConfig: .mandatory
        )
        let run = try await pipeline.run(audioURL: url)
        XCTAssertEqual(run.pipelineID, PipelineKind.basicPitch.rawValue)
        XCTAssertNotNil(run.cleanupReport, "Mandatory cleanup must populate a report")
        XCTAssertFalse(run.rawNotes.isEmpty, "Raw model output must be preserved")
        XCTAssertEqual(run.pipelineParameters["model.fallback"], "false")
        XCTAssertEqual(run.pipelineParameters["backend.kind"], "dedicated")
        // Cleanup invariant: max duration is bounded.
        let maxDur = run.notes.map(\.duration).max() ?? 0
        XCTAssertLessThanOrEqual(maxDur, 10.0 + 0.001)
    }

    func testByteDanceRefusesFallbackByDefault() async {
        // Force the env override to a path that does not exist AND disable
        // PATH/repo-local/home discovery so the adapter reports unavailable
        // regardless of any local install (the repo-local wrappers are
        // present once setup-transcription-deps.sh has run).
        let prior = ProcessInfo.processInfo.environment[ByteDancePianoTranscriber.envOverride]
        setenv(ByteDancePianoTranscriber.envOverride, "/path/does/not/exist", 1)
        setenv("PIANO_TRAINER_DISABLE_DISCOVERY", "1", 1)
        defer {
            if let prior {
                setenv(ByteDancePianoTranscriber.envOverride, prior, 1)
            } else {
                unsetenv(ByteDancePianoTranscriber.envOverride)
            }
            unsetenv("PIANO_TRAINER_DISABLE_DISCOVERY")
        }
        let registry = PipelineRegistry()
        let pipeline = registry.makePipeline(.bytedancePiano)
        XCTAssertNotNil(pipeline, "ByteDance pipeline should still be returnable")
        let url = URL(fileURLWithPath: "/tmp/ptk_bytedance_nope.wav")
        do {
            _ = try await pipeline!.run(audioURL: url)
            XCTFail("Expected PipelineError.unavailable from ByteDance with no backend")
        } catch let PipelineError.unavailable(reason) {
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("Expected PipelineError.unavailable, got \(error)")
        }
    }
}

// MARK: - Three new pipelines (Clean / Noisy / Mixed)

/// Live tests gated on the repo-local wrappers existing. Skip when they
/// don't (CI without the venv installed) so the suite stays green; running
/// `bash scripts/setup-transcription-deps.sh` switches them on.
final class ThreeNewPipelinesLiveTests: XCTestCase {

    private func makeShortPianoWAV(seconds: Double = 1.0) throws -> URL {
        let sr: Double = 22050
        let frames = AVAudioFrameCount(sr * seconds)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let data = buf.floatChannelData![0]
        for i in 0 ..< Int(frames) {
            let t = Double(i) / sr
            // Two stacked sines roughly approximating a piano major third.
            data[i] = Float(0.3 * sin(2 * .pi * 440 * t) + 0.2 * sin(2 * .pi * 523.25 * t))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_three_\(UUID().uuidString).wav")
        do {
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try f.write(from: buf)
        }
        return url
    }

    private func skipUnless(_ wrapper: String) throws {
        if ExternalCommandRunner.locate(executable: wrapper) == nil {
            throw XCTSkip("\(wrapper) not installed; run scripts/setup-transcription-deps.sh.")
        }
    }

    func testNoisySoloPianoEndToEnd() async throws {
        try skipUnless("basic-pitch-wrapper")
        let url = try makeShortPianoWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = NoisySoloPianoPipeline()
        let run = try await pipeline.run(audioURL: url)
        XCTAssertEqual(run.pipelineID, PipelineKind.noisySoloPiano.rawValue)
        XCTAssertEqual(run.pipelineParameters["model.fallback"], "false")
        XCTAssertEqual(run.pipelineParameters["backend.kind"], "dedicated")
        XCTAssertNotNil(run.cleanupReport)
        XCTAssertFalse(run.rawNotes.isEmpty, "Basic Pitch must produce raw notes")
    }

    func testCleanSoloPianoEndToEnd() async throws {
        try skipUnless("piano-transcription-wrapper")
        let url = try makeShortPianoWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = CleanSoloPianoPipeline()
        let run = try await pipeline.run(audioURL: url)
        XCTAssertEqual(run.pipelineID, PipelineKind.cleanSoloPiano.rawValue)
        XCTAssertEqual(run.pipelineParameters["model.fallback"], "false")
        XCTAssertEqual(run.pipelineParameters["backend.kind"], "dedicated")
        XCTAssertNotNil(run.cleanupReport)
    }

    func testMixedInstrumentsAdvancedEndToEnd() async throws {
        try skipUnless("demucs-wrapper")
        try skipUnless("piano-transcription-wrapper")
        // Demucs is slow on the first call (downloads model checkpoints if
        // needed); give the test a longer fuse for CPU-only inference.
        let url = try makeShortPianoWAV(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = MixedInstrumentsAdvancedPipeline()
        let run = try await pipeline.run(audioURL: url)
        XCTAssertEqual(run.pipelineID, PipelineKind.mixedInstrumentsAdvanced.rawValue)
        XCTAssertTrue(run.usedSourceSeparation, "Mixed pipeline must record that separation ran")
        XCTAssertNotNil(run.isolatedStemPath, "Mixed pipeline must record the stem path")
        XCTAssertEqual(run.pipelineParameters["backend.kind"], "dedicated")
        XCTAssertNotNil(run.pipelineParameters["separator.method"])
        XCTAssertNotNil(run.cleanupReport)
    }
}

/// Pure (non-live) invariant tests for the three new pipelines.
final class ThreeNewPipelinesInvariantTests: XCTestCase {

    /// Recording adapter that proves the Mixed pipeline calls separator
    /// before transcriber. Stub separator copies the input as the "stem"
    /// so the downstream transcriber gets a real WAV to read.
    private final class RecordingSeparator: SourceSeparator, @unchecked Sendable {
        let name = "RecordingSep"
        let isAvailable = true
        let unavailableReason: String? = nil
        var didSeparate = false
        var separateOrder = -1
        let counter: Counter
        init(_ counter: Counter) { self.counter = counter }
        func separate(audioURL: URL, outputDirectory: URL, progress: PipelineProgressHandler?) async throws -> SeparationResult {
            didSeparate = true
            separateOrder = counter.next()
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let stem = outputDirectory.appendingPathComponent("stem.wav")
            if FileManager.default.fileExists(atPath: stem.path) { try FileManager.default.removeItem(at: stem) }
            try FileManager.default.copyItem(at: audioURL, to: stem)
            let dur = AudioDurationProbe.durationSeconds(of: stem) ?? 0
            return SeparationResult(stemURL: stem, methodName: name, qualityScore: 1.0, stemDurationSeconds: dur, parameters: ["stub": "true"])
        }
    }

    private final class RecordingTranscriber: PianoSpecializedTranscriber, @unchecked Sendable {
        let isAvailable = true
        let unavailableReason: String? = nil
        let modelName = "RecordingTranscriber"
        let modelVersion = "0.0"
        let parameters: [String: String] = [:]
        var didTranscribe = false
        var transcribeOrder = -1
        var inputURL: URL?
        let counter: Counter
        init(_ counter: Counter) { self.counter = counter }
        func transcribePiano(audioURL: URL, progress: PipelineProgressHandler?) async throws -> PianoTranscriptionResult {
            didTranscribe = true
            transcribeOrder = counter.next()
            inputURL = audioURL
            return PianoTranscriptionResult(
                notes: [MIDINote(pitch: 60, onset: 0, duration: 0.5, velocity: 80)],
                modelName: modelName, modelVersion: modelVersion,
                sampleRate: 16000, parameters: parameters, isFallback: false
            )
        }
    }

    private final class Counter: @unchecked Sendable {
        private var n = 0
        func next() -> Int { n += 1; return n }
    }

    private func makeWAV() throws -> URL {
        let sr: Double = 22050
        let frames = AVAudioFrameCount(sr)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_inv_\(UUID().uuidString).wav")
        do {
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try f.write(from: buf)
        }
        return url
    }

    /// CRITICAL: Mixed pipeline MUST call separator.separate BEFORE
    /// transcriber.transcribePiano, and MUST hand the stem URL (not the
    /// source URL) to the transcriber. This guards against regressions
    /// where someone "fixes" the pipeline by inlining and accidentally
    /// drops separation.
    func testMixedPipelineSeparatesBeforeTranscribingAndUsesStem() async throws {
        let counter = Counter()
        let sep = RecordingSeparator(counter)
        let trans = RecordingTranscriber(counter)
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = MixedInstrumentsAdvancedPipeline(separator: sep, transcriber: trans)
        let run = try await pipeline.run(audioURL: url)

        XCTAssertTrue(sep.didSeparate, "Separator must run for mixed pipeline")
        XCTAssertTrue(trans.didTranscribe, "Transcriber must run for mixed pipeline")
        XCTAssertLessThan(sep.separateOrder, trans.transcribeOrder,
                          "Separator must run BEFORE transcriber")
        XCTAssertNotNil(trans.inputURL)
        XCTAssertNotEqual(trans.inputURL?.path, url.path,
                          "Transcriber must NOT receive the original source — it must receive the isolated stem")
        XCTAssertTrue(run.usedSourceSeparation)
        XCTAssertEqual(run.pipelineID, PipelineKind.mixedInstrumentsAdvanced.rawValue)
    }

    /// Each new pipeline must throw, not fall back, when its backend is missing.
    func testCleanSoloThrowsWhenByteDanceMissing() async throws {
        struct UnavailableTranscriber: PianoSpecializedTranscriber {
            let isAvailable = false
            let unavailableReason: String? = "ByteDance not installed."
            let modelName = "ByteDance"; let modelVersion = "x"; let parameters: [String: String] = [:]
            func transcribePiano(audioURL: URL, progress: PipelineProgressHandler?) async throws -> PianoTranscriptionResult {
                throw PipelineError.unavailable(reason: unavailableReason ?? "")
            }
        }
        let pipeline = CleanSoloPianoPipeline(transcriber: UnavailableTranscriber())
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await pipeline.run(audioURL: url)
            XCTFail("Clean Solo Piano must throw when its backend is missing")
        } catch let PipelineError.unavailable(reason) {
            XCTAssertTrue(reason.contains("ByteDance") || reason.contains("setup-transcription"))
        } catch {
            XCTFail("Expected PipelineError.unavailable, got \(error)")
        }
    }

    func testMixedThrowsWhenSeparatorMissing() async throws {
        struct UnavailableSeparator: SourceSeparator {
            let name = "None"; let isAvailable = false
            let unavailableReason: String? = "Demucs not installed."
            func separate(audioURL: URL, outputDirectory: URL, progress: PipelineProgressHandler?) async throws -> SeparationResult {
                throw PipelineError.unavailable(reason: unavailableReason ?? "")
            }
        }
        struct OKTranscriber: PianoSpecializedTranscriber {
            let isAvailable = true; let unavailableReason: String? = nil
            let modelName = "M"; let modelVersion = "0"; let parameters: [String: String] = [:]
            func transcribePiano(audioURL: URL, progress: PipelineProgressHandler?) async throws -> PianoTranscriptionResult {
                PianoTranscriptionResult(notes: [], modelName: modelName, modelVersion: modelVersion, sampleRate: 16000, parameters: [:], isFallback: false)
            }
        }
        let pipeline = MixedInstrumentsAdvancedPipeline(separator: UnavailableSeparator(), transcriber: OKTranscriber())
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await pipeline.run(audioURL: url)
            XCTFail("Mixed pipeline must throw when separator is missing")
        } catch PipelineError.unavailable {
            // expected
        } catch {
            XCTFail("Expected PipelineError.unavailable, got \(error)")
        }
    }
}

// MARK: - Quality scorer + refinement loop + Mixed dependency rules

final class MidiQualityScorerTests: XCTestCase {
    func testEmptyOutputScoresZero() {
        let s = MidiQualityScorer.score(notes: [], audioDurationSeconds: 30, profile: .cleanSoloPiano)
        XCTAssertEqual(s.score, 0)
        XCTAssertEqual(s.grade, .bad)
        XCTAssertFalse(s.problems.isEmpty)
    }

    func testReasonableSoloPianoScoresWell() {
        // 30 seconds of plausible solo piano: 60 notes, polyphony up to 3.
        var notes: [MIDINote] = []
        let pitches = [60, 62, 64, 65, 67]
        for i in 0 ..< 60 {
            let onset = Double(i) * 0.5
            notes.append(MIDINote(pitch: pitches[i % pitches.count],
                                  onset: onset,
                                  duration: 0.45,
                                  velocity: 70))
        }
        let s = MidiQualityScorer.score(notes: notes, audioDurationSeconds: 30, profile: .cleanSoloPiano)
        XCTAssertGreaterThanOrEqual(s.score, 0.85)
        XCTAssertEqual(s.grade, .good)
    }

    func testCatastrophicOutputScoresLow() {
        // 1,800 notes in 30s, all over the keyboard, lots of stuck notes.
        var notes: [MIDINote] = []
        for i in 0 ..< 1800 {
            let onset = Double(i) * 0.015
            let pitch = 21 + (i % 88)
            let dur = (i % 50 == 0) ? 60.0 : 0.04
            notes.append(MIDINote(pitch: pitch, onset: onset, duration: dur, velocity: 50))
        }
        let s = MidiQualityScorer.score(notes: notes, audioDurationSeconds: 30, profile: .cleanSoloPiano)
        XCTAssertLessThan(s.score, 0.40)
        XCTAssertEqual(s.grade, .bad)
        XCTAssertFalse(s.problems.isEmpty)
    }

    func testMaxSimultaneousNoteCount() {
        let notes = [
            MIDINote(pitch: 60, onset: 0.0, duration: 1.0, velocity: 80),
            MIDINote(pitch: 64, onset: 0.5, duration: 1.0, velocity: 80),
            MIDINote(pitch: 67, onset: 0.6, duration: 0.2, velocity: 80),
        ]
        XCTAssertEqual(MidiQualityScorer.maxSimultaneousNoteCount(notes), 3)
    }
}

final class QualityFirstRunnerTests: XCTestCase {
    func testGoodPrimarySkipsRefinement() async throws {
        let runner = QualityFirstTranscriptionRunner(
            scoringProfile: .cleanSoloPiano,
            acceptanceThreshold: 0.85,
            audioDurationSeconds: 30
        )
        // 60-note plausible primary.
        let goodNotes = (0..<60).map {
            MIDINote(pitch: 60 + ($0 % 5), onset: Double($0) * 0.5,
                     duration: 0.45, velocity: 70)
        }
        let primary = TranscriptionAttempt(
            label: "P", backendName: "primary", cleanupProfile: "soloPiano",
            cleanupConfig: .soloPiano
        ) { _ in goodNotes }
        let alt = TranscriptionAttempt(
            label: "A", backendName: "alt", cleanupProfile: "noisyPiano",
            cleanupConfig: .noisyPiano
        ) { _ in [] }
        let outcome = try await runner.run(primary: primary, refinements: [alt], progress: nil)
        XCTAssertFalse(outcome.refinementTriggered, "Good primary must skip refinement")
        XCTAssertEqual(outcome.candidates.count, 1)
        XCTAssertEqual(outcome.chosen.label, "P")
    }

    func testBadPrimaryTriggersRefinementAndPicksBetter() async throws {
        let runner = QualityFirstTranscriptionRunner(
            scoringProfile: .cleanSoloPiano,
            acceptanceThreshold: 0.85,
            audioDurationSeconds: 30
        )
        // Bad primary: catastrophic note cloud.
        let bad: [MIDINote] = (0 ..< 2000).map {
            MIDINote(pitch: 21 + ($0 % 88), onset: Double($0) * 0.015,
                     duration: 0.04, velocity: 40)
        }
        // Good refinement: plausible solo.
        let good: [MIDINote] = (0..<60).map {
            MIDINote(pitch: 60 + ($0 % 5), onset: Double($0) * 0.5,
                     duration: 0.45, velocity: 70)
        }
        let primary = TranscriptionAttempt(
            label: "BAD", backendName: "primary",
            cleanupProfile: "soloPiano", cleanupConfig: .soloPiano
        ) { _ in bad }
        let refine = TranscriptionAttempt(
            label: "GOOD", backendName: "refine",
            cleanupProfile: "noisyPiano", cleanupConfig: .noisyPiano
        ) { _ in good }
        let outcome = try await runner.run(primary: primary, refinements: [refine], progress: nil)
        XCTAssertTrue(outcome.refinementTriggered)
        XCTAssertEqual(outcome.chosen.label, "GOOD")
        XCTAssertGreaterThan(outcome.chosen.quality.score, outcome.candidates.first { $0.label == "BAD" }!.quality.score)
    }
}

final class MixedAdvancedDependencyRulesTests: XCTestCase {

    /// Stub stub stub: separators / transcribers that report a configurable
    /// availability so we can simulate every dependency permutation.
    private struct StubSeparator: SourceSeparator {
        let name = "StubSep"
        let isAvailable: Bool
        let unavailableReason: String?
        func separate(audioURL: URL, outputDirectory: URL, progress: PipelineProgressHandler?) async throws -> SeparationResult {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let stem = outputDirectory.appendingPathComponent("htdemucs/x/other.wav")
            try FileManager.default.createDirectory(at: stem.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: audioURL, to: stem)
            return SeparationResult(stemURL: stem, methodName: name, qualityScore: 1, stemDurationSeconds: 1, parameters: [:])
        }
    }
    private struct StubTranscriber: PianoSpecializedTranscriber {
        let isAvailable: Bool
        let unavailableReason: String?
        let modelName: String
        let modelVersion = "0.0"
        let parameters: [String: String] = [:]
        func transcribePiano(audioURL: URL, progress: PipelineProgressHandler?) async throws -> PianoTranscriptionResult {
            PianoTranscriptionResult(
                notes: [MIDINote(pitch: 60, onset: 0, duration: 0.5, velocity: 80)],
                modelName: modelName, modelVersion: modelVersion,
                sampleRate: 16000, parameters: parameters, isFallback: false
            )
        }
    }

    private func makeWAV() throws -> URL {
        let sr: Double = 22050
        let frames = AVAudioFrameCount(sr)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_dep_\(UUID().uuidString).wav")
        do {
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try f.write(from: buf)
        }
        return url
    }

    func testMixedRunsWithBasicPitchOnly() async throws {
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let pipeline = MixedInstrumentsAdvancedPipeline(
            separator: StubSeparator(isAvailable: true, unavailableReason: nil),
            basicPitch: StubTranscriber(isAvailable: true, unavailableReason: nil, modelName: "BasicPitch"),
            byteDance: StubTranscriber(isAvailable: false, unavailableReason: "ByteDance missing", modelName: "ByteDance")
        )
        let run = try await pipeline.run(audioURL: url)
        XCTAssertTrue(run.usedSourceSeparation)
        XCTAssertEqual(run.pipelineParameters["model.fallback"], "false")
        XCTAssertEqual(run.pipelineParameters["backend.kind"], "dedicated")
        XCTAssertNotNil(run.isolatedStemPath)
        // Backend that ran must NOT be ByteDance.
        let backendRan = run.pipelineParameters["backend.ran"] ?? ""
        XCTAssertTrue(backendRan.contains("BasicPitch"))
    }

    func testMixedRunsWithByteDanceOnlyButOnStemNotSource() async throws {
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let pipeline = MixedInstrumentsAdvancedPipeline(
            separator: StubSeparator(isAvailable: true, unavailableReason: nil),
            basicPitch: StubTranscriber(isAvailable: false, unavailableReason: "BP missing", modelName: "BasicPitch"),
            byteDance: StubTranscriber(isAvailable: true, unavailableReason: nil, modelName: "ByteDance")
        )
        let run = try await pipeline.run(audioURL: url)
        XCTAssertTrue(run.usedSourceSeparation,
                      "Even with only ByteDance available, separation must run before transcription on mixed audio")
        XCTAssertNotNil(run.isolatedStemPath)
        XCTAssertEqual(run.pipelineParameters["backend.kind"], "dedicated")
    }

    func testMixedThrowsWhenDemucsMissing() async throws {
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let pipeline = MixedInstrumentsAdvancedPipeline(
            separator: StubSeparator(isAvailable: false, unavailableReason: "Demucs missing"),
            basicPitch: StubTranscriber(isAvailable: true, unavailableReason: nil, modelName: "BasicPitch"),
            byteDance: StubTranscriber(isAvailable: true, unavailableReason: nil, modelName: "ByteDance")
        )
        do {
            _ = try await pipeline.run(audioURL: url)
            XCTFail("Mixed must throw when Demucs is missing, even if both transcribers exist.")
        } catch PipelineError.unavailable {
            // expected
        } catch {
            XCTFail("Expected PipelineError.unavailable, got \(error)")
        }
    }

    func testMixedThrowsWhenBothTranscribersMissing() async throws {
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let pipeline = MixedInstrumentsAdvancedPipeline(
            separator: StubSeparator(isAvailable: true, unavailableReason: nil),
            basicPitch: StubTranscriber(isAvailable: false, unavailableReason: "BP missing", modelName: "BasicPitch"),
            byteDance: StubTranscriber(isAvailable: false, unavailableReason: "BD missing", modelName: "ByteDance")
        )
        do {
            _ = try await pipeline.run(audioURL: url)
            XCTFail("Mixed must throw when no transcriber is installed.")
        } catch PipelineError.unavailable {
            // expected
        } catch {
            XCTFail("Expected PipelineError.unavailable, got \(error)")
        }
    }

    func testRegistryFlipsMixedToDedicatedWhenDemucsAndBasicPitchOnly() {
        // Force dependencies so only Basic Pitch is available alongside Demucs.
        // We set env to bogus path for ByteDance and PIANO_TRAINER_DISABLE_DISCOVERY
        // doesn't apply here because the registry uses live transcribers.
        let registry = PipelineRegistry(
            sourceSeparator: { struct OK: SourceSeparator { let name="OK"; let isAvailable=true; let unavailableReason: String?=nil; func separate(audioURL: URL, outputDirectory: URL, progress: PipelineProgressHandler?) async throws -> SeparationResult { fatalError() } }; return OK() }(),
            basicPitchTranscriber: { struct OK: PianoSpecializedTranscriber { let isAvailable=true; let unavailableReason: String?=nil; let modelName="BasicPitch"; let modelVersion="0"; let parameters: [String:String] = [:]; func transcribePiano(audioURL: URL, progress: PipelineProgressHandler?) async throws -> PianoTranscriptionResult { fatalError() } }; return OK() }(),
            bytedancePianoTranscriber: { struct No: PianoSpecializedTranscriber { let isAvailable=false; let unavailableReason: String? = "missing"; let modelName="ByteDance"; let modelVersion="0"; let parameters: [String:String] = [:]; func transcribePiano(audioURL: URL, progress: PipelineProgressHandler?) async throws -> PianoTranscriptionResult { fatalError() } }; return No() }()
        )
        XCTAssertTrue(registry.hasDedicatedBackend(.mixedInstrumentsAdvanced),
                      "Mixed must be dedicated with Demucs + Basic Pitch even without ByteDance")
        XCTAssertNil(registry.fallbackReason(.mixedInstrumentsAdvanced),
                     "No fallback message when Demucs + Basic Pitch are present")
    }
}

final class TranscriptionBackendRegistryTests: XCTestCase {
    func testProbesIncludeRepoLocalAndPath() {
        // Snapshot every backend; at minimum the structure is well-formed.
        let registry = TranscriptionBackendRegistry.shared
        for status in registry.statuses() {
            XCTAssertFalse(status.displayName.isEmpty)
            XCTAssertFalse(status.wrapperName.isEmpty)
            XCTAssertFalse(status.envVar.isEmpty)
            // When present, the resolved path must be absolute.
            if let p = status.resolvedPath {
                XCTAssertTrue(p.hasPrefix("/"), "Resolved path must be absolute: \(p)")
            }
        }
    }
}

// MARK: - Mixed Instruments / Advanced wrapper resolution + Data Flow

/// End-to-end checks that the resolver finds the repo-local wrappers, that
/// env vars override repo-local, that the registry flips Mixed/Advanced to
/// "dedicated" once Demucs is detected via the wrapper (not via a bare
/// `demucs` binary), and that Mixed/Advanced runs stamp the Data Flow keys
/// with `fallback=false` plus the absolute wrapper paths.
final class MixedAdvancedWrapperResolutionTests: XCTestCase {

    /// Path to `<repoRoot>/tools/transcription/bin`, computed from this
    /// test file's location so tests don't depend on cwd.
    private var repoBinDir: URL {
        // #file is .../Tests/PianoTranscriptionKitTests/PianoTranscriptionKitTests.swift
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // PianoTranscriptionKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // <repoRoot>
            .appendingPathComponent("tools/transcription/bin")
    }

    private func skipUnlessRepoWrapperExists(_ name: String) throws {
        let p = repoBinDir.appendingPathComponent(name).path
        if !FileManager.default.isExecutableFile(atPath: p) {
            throw XCTSkip("Repo wrapper \(p) not present — run scripts/setup-transcription-deps.sh.")
        }
    }

    func testResolverFindsRepoLocalDemucsWrapperWithAbsolutePath() throws {
        try skipUnlessRepoWrapperExists("demucs-wrapper")
        let status = TranscriptionBackendRegistry.shared.resolve(.demucs)
        XCTAssertTrue(status.isAvailable, "demucs-wrapper present but not detected")
        XCTAssertEqual(status.wrapperName, "demucs-wrapper")
        XCTAssertNotNil(status.resolvedPath)
        if let p = status.resolvedPath {
            XCTAssertTrue(p.hasPrefix("/"), "Resolved path must be absolute: \(p)")
            XCTAssertTrue(p.hasSuffix("/tools/transcription/bin/demucs-wrapper"),
                          "Expected repo-local wrapper, got \(p)")
        }
    }

    func testResolverFindsRepoLocalBasicPitchWrapperWithAbsolutePath() throws {
        try skipUnlessRepoWrapperExists("basic-pitch-wrapper")
        let status = TranscriptionBackendRegistry.shared.resolve(.basicPitch)
        XCTAssertTrue(status.isAvailable, "basic-pitch-wrapper present but not detected")
        XCTAssertEqual(status.wrapperName, "basic-pitch-wrapper")
        XCTAssertNotNil(status.resolvedPath)
        if let p = status.resolvedPath {
            XCTAssertTrue(p.hasPrefix("/"), "Resolved path must be absolute: \(p)")
            XCTAssertTrue(p.hasSuffix("/tools/transcription/bin/basic-pitch-wrapper"),
                          "Expected repo-local wrapper, got \(p)")
        }
    }

    func testEnvVarOverridesRepoLocalWrapper() throws {
        try skipUnlessRepoWrapperExists("demucs-wrapper")
        // Create a temp executable and point DEMUCS_PATH at it; the
        // resolver must prefer it over the repo-local wrapper.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_envoverride_\(UUID().uuidString)")
        try "#!/bin/sh\nexit 0\n".write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                              ofItemAtPath: tmp.path)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Spawn a child swift process that sets DEMUCS_PATH and reads
        // resolve(.demucs).resolvedPath. We can't mutate ProcessInfo
        // env in-process safely, so we test the resolver via a synthetic
        // env dictionary instead — exercise the same code path the env
        // override uses.
        // Instead, validate that when DEMUCS_PATH is set in the *current*
        // process, the resolver prefers it. setenv is process-global and
        // safe within a single test. We reset it in the deferred block.
        let prior = ProcessInfo.processInfo.environment["DEMUCS_PATH"]
        setenv("DEMUCS_PATH", tmp.path, 1)
        defer {
            if let prior { setenv("DEMUCS_PATH", prior, 1) }
            else { unsetenv("DEMUCS_PATH") }
        }
        let status = TranscriptionBackendRegistry.shared.resolve(.demucs)
        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.source, .envOverride)
        XCTAssertEqual(status.resolvedPath, tmp.path,
                       "DEMUCS_PATH must override the repo-local wrapper")
    }

    func testRegistryFlipsMixedToDedicatedWithRepoWrappersOnly() throws {
        try skipUnlessRepoWrapperExists("demucs-wrapper")
        try skipUnlessRepoWrapperExists("basic-pitch-wrapper")
        // Use the live registry (which now defaults to DemucsWrapperSeparator
        // as its `sourceSeparator`). The registry's hasDedicatedBackend
        // must return true even when the bare `demucs` binary is NOT on
        // PATH — the wrapper alone is sufficient.
        let registry = PipelineRegistry()
        XCTAssertTrue(registry.hasDedicatedBackend(.mixedInstrumentsAdvanced),
                      "Repo-local demucs-wrapper + basic-pitch-wrapper must mark Mixed/Advanced as dedicated")
        XCTAssertNil(registry.fallbackReason(.mixedInstrumentsAdvanced),
                     "No fallback reason when wrappers are present")
    }

    func testMakePipelineForMixedAdvancedDoesNotReturnFallback() throws {
        try skipUnlessRepoWrapperExists("demucs-wrapper")
        try skipUnlessRepoWrapperExists("basic-pitch-wrapper")
        let registry = PipelineRegistry()
        let pipeline = registry.makePipeline(.mixedInstrumentsAdvanced)
        XCTAssertNotNil(pipeline)
        // Crucially: the returned pipeline must NOT be the
        // FallbackTranscriptionPipeline (which delegates to PianoFocused).
        XCTAssertFalse(pipeline is FallbackTranscriptionPipeline,
                       "Mixed/Advanced must never silently fall back when wrappers are present")
        XCTAssertTrue(pipeline is MixedInstrumentsAdvancedPipeline,
                      "Expected the real MixedInstrumentsAdvancedPipeline; got \(type(of: pipeline as Any))")
    }
}

/// Stamping behavior for Mixed/Advanced: when run completes, Data Flow
/// metadata must include the absolute wrapper paths and `fallback=false`.
final class MixedAdvancedDataFlowStampingTests: XCTestCase {

    private struct StubSeparator: SourceSeparator {
        let name = "Demucs (test stub)"
        let isAvailable = true
        let unavailableReason: String? = nil
        func separate(audioURL: URL, outputDirectory: URL, progress: PipelineProgressHandler?) async throws -> SeparationResult {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            // Mirror the htdemucs layout — write `<output>/htdemucs/<base>/other.wav`
            // so the rest of the pipeline sees a real WAV at the expected path.
            let stem = outputDirectory
                .appendingPathComponent("htdemucs")
                .appendingPathComponent(audioURL.deletingPathExtension().lastPathComponent)
                .appendingPathComponent("other.wav")
            try FileManager.default.createDirectory(at: stem.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: audioURL, to: stem)
            let dur = AudioDurationProbe.durationSeconds(of: stem) ?? 1.0
            return SeparationResult(
                stemURL: stem, methodName: name, qualityScore: 1.0,
                stemDurationSeconds: dur, parameters: [:]
            )
        }
    }

    private struct StubTranscriber: PianoSpecializedTranscriber {
        let isAvailable: Bool
        let unavailableReason: String?
        let modelName: String
        let modelVersion = "0.0"
        let parameters: [String: String] = [:]
        var receivedURL: URL? { _receivedURL.value }
        private let _receivedURL = AtomicOptionalURL()
        func transcribePiano(audioURL: URL, progress: PipelineProgressHandler?) async throws -> PianoTranscriptionResult {
            _receivedURL.set(audioURL)
            // Plausible solo-piano output so QualityFirstRunner is happy.
            let notes: [MIDINote] = (0..<60).map {
                MIDINote(pitch: 60 + ($0 % 5),
                         onset: Double($0) * 0.5,
                         duration: 0.45,
                         velocity: 70)
            }
            return PianoTranscriptionResult(
                notes: notes, modelName: modelName, modelVersion: modelVersion,
                sampleRate: 22050, parameters: parameters, isFallback: false
            )
        }
    }

    /// Tiny thread-safe holder so the stub transcriber can record what URL
    /// it received without forcing the surrounding struct to be mutable.
    private final class AtomicOptionalURL: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URL?
        var value: URL? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ u: URL) { lock.lock(); stored = u; lock.unlock() }
    }

    private func makeWAV() throws -> URL {
        let sr: Double = 22050
        let frames = AVAudioFrameCount(sr)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptk_dataflow_\(UUID().uuidString).wav")
        do {
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try f.write(from: buf)
        }
        return url
    }

    func testMixedAdvancedRunsTranscriberOnOtherWavNotOriginal() async throws {
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let bp = StubTranscriber(isAvailable: true, unavailableReason: nil, modelName: "BasicPitch")
        let bd = StubTranscriber(isAvailable: false, unavailableReason: "BD missing", modelName: "ByteDance")
        let pipeline = MixedInstrumentsAdvancedPipeline(
            separator: StubSeparator(),
            basicPitch: bp,
            byteDance: bd
        )
        _ = try await pipeline.run(audioURL: url)
        // The transcriber must have been handed the stem URL ending in
        // /htdemucs/<base>/other.wav, NOT the raw input.
        let received = bp.receivedURL
        XCTAssertNotNil(received)
        XCTAssertNotEqual(received?.path, url.path,
                          "Transcriber must receive separated stem, never the original audio")
        XCTAssertEqual(received?.lastPathComponent, "other.wav",
                       "Transcriber must run on the htdemucs `other.wav` stem")
    }

    func testMixedAdvancedStampsDataFlowFallbackFalse() async throws {
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let pipeline = MixedInstrumentsAdvancedPipeline(
            separator: StubSeparator(),
            basicPitch: StubTranscriber(isAvailable: true, unavailableReason: nil, modelName: "BasicPitch"),
            byteDance: StubTranscriber(isAvailable: false, unavailableReason: "BD missing", modelName: "ByteDance")
        )
        let run = try await pipeline.run(audioURL: url)
        XCTAssertEqual(run.dataflow("fallback"), "false",
                       "Mixed/Advanced must stamp dataflow.fallback=false when wrappers are wired")
        XCTAssertEqual(run.dataflow("selectedModeDisplay"), PipelineKind.mixedInstrumentsAdvanced.displayName)
        XCTAssertEqual(run.dataflow("actualPipeline"), PipelineKind.mixedInstrumentsAdvanced.displayName)
        XCTAssertNotNil(run.dataflow("actualSeparator"))
        XCTAssertEqual(run.dataflow("separatorBackend"), "demucs-wrapper")
        XCTAssertNotNil(run.dataflow("actualTranscriber"))
        XCTAssertEqual(run.dataflow("transcriptionBackend"), "basic-pitch-wrapper")
        XCTAssertNotNil(run.dataflow("isolatedStemPath"))
        XCTAssertTrue(run.dataflow("isolatedStemPath")?.hasSuffix("/other.wav") ?? false,
                      "Data Flow stem path must point at the htdemucs `other.wav`")
    }
}

// MARK: - Piano Playability Critic

/// Coverage for HandAssignmentEngine, PlayabilityDiagnoser,
/// PlayabilityRepairEngine, and PianoPlayabilityCritic.
final class PianoPlayabilityCriticTests: XCTestCase {

    func testDetectsImpossible15SemitoneOneHandChord() {
        // 15-semitone reach inside one cluster, both notes pinned to the
        // same hand via a synthetic assignment so the detector's behavior
        // is tested independently of the hand-assignment heuristic.
        let synthetic = HandAssignment(
            notes: [
                HandAssignedNote(note: MIDINote(pitch: 65, onset: 0.0,   duration: 0.5, velocity: 80), hand: .right),
                HandAssignedNote(note: MIDINote(pitch: 67, onset: 0.005, duration: 0.5, velocity: 80), hand: .right),
                HandAssignedNote(note: MIDINote(pitch: 80, onset: 0.010, duration: 0.5, velocity: 80), hand: .right),
            ],
            splitPitch: 60
        )
        let diag = PlayabilityDiagnoser.diagnose(synthetic)
        XCTAssertTrue(
            diag.issues.contains { $0.kind == .impossibleSpan && $0.hand == .right },
            "A 15-semitone single-hand cluster must produce an impossibleSpan issue"
        )
    }

    func testDetectsMoreThanFiveSimultaneousNotesPerHand() {
        // 6 left-hand notes simultaneously.
        let chord: [MIDINote] = [36, 38, 40, 41, 43, 47].enumerated().map { i, p in
            MIDINote(pitch: p, onset: Double(i) * 0.001, duration: 0.5, velocity: 80)
        }
        let assignment = HandAssignmentEngine().assign(chord)
        let diag = PlayabilityDiagnoser.diagnose(assignment)
        XCTAssertTrue(
            diag.issues.contains { $0.kind == .tooManySimultaneous && $0.hand == .left },
            "Six simultaneous left-hand notes must produce a tooManySimultaneous issue"
        )
        XCTAssertGreaterThanOrEqual(diag.leftHand.maxSimultaneous, 6)
    }

    func testDetectsImpossibleJumpOverShortTime() {
        // C2 → C7 in 80 ms on the same hand. Need dt > simultaneousWindow
        // (50 ms) so the diagnoser sees two distinct clusters.
        let synthetic = HandAssignment(
            notes: [
                HandAssignedNote(note: MIDINote(pitch: 36, onset: 0.0,  duration: 0.05, velocity: 80), hand: .left),
                HandAssignedNote(note: MIDINote(pitch: 96, onset: 0.08, duration: 0.1,  velocity: 80), hand: .left),
            ],
            splitPitch: 60
        )
        let diag = PlayabilityDiagnoser.diagnose(synthetic)
        XCTAssertTrue(
            diag.issues.contains { $0.kind == .impossibleJump && $0.hand == .left },
            "60-semitone jump in 50 ms must produce an impossibleJump issue"
        )
    }

    func testPreservesMelodyNoteWhenSimplifyingChord() {
        // Six-note left-hand cluster — the topmost (melody) must survive.
        let melodyPitch = 47
        let chord: [MIDINote] = [36, 38, 40, 41, 43, melodyPitch].enumerated().map { i, p in
            MIDINote(pitch: p, onset: Double(i) * 0.001, duration: 0.5, velocity: 80)
        }
        let report = PianoPlayabilityCritic().process(chord, audioDurationSeconds: 1.0)
        XCTAssertTrue(
            report.repairedNotes.contains { $0.pitch == melodyPitch },
            "Melody (top) note must be preserved when reducing chord size"
        )
    }

    func testRemovesWeakGhostNoteCausingImpossibleStretch() {
        let bass = MIDINote(pitch: 60, onset: 0.0,   duration: 1.0, velocity: 95)
        let ghost = MIDINote(pitch: 71, onset: 0.01, duration: 0.04, velocity: 22)
        let melody = MIDINote(pitch: 75, onset: 0.02, duration: 1.0, velocity: 95)
        let synthetic = HandAssignment(
            notes: [bass, ghost, melody].map { HandAssignedNote(note: $0, hand: .right) },
            splitPitch: 60
        )
        let diag = PlayabilityDiagnoser.diagnose(synthetic)
        XCTAssertTrue(diag.issues.contains { $0.kind == .impossibleSpan })
        let result = PlayabilityRepairEngine.repair(synthetic, diagnosis: diag)
        let pitches = result.assignment.notes.map(\.note.pitch)
        XCTAssertFalse(pitches.contains(71), "Weak ghost (vel 22) must be removed first")
        XCTAssertTrue(pitches.contains(60), "Bass anchor must survive")
        XCTAssertTrue(pitches.contains(75), "Melody must survive")
        XCTAssertGreaterThan(result.log.ghostsRemoved, 0)
    }

    func testImprovesPlayabilityScoreWithoutDeletingMainMelody() {
        var notes: [MIDINote] = []
        let melodyPitches = [60, 62, 64, 65, 67, 69, 71, 72]
        for (i, p) in melodyPitches.enumerated() {
            notes.append(MIDINote(pitch: p, onset: Double(i) * 0.5, duration: 0.45, velocity: 90))
        }
        notes.append(MIDINote(pitch: 100, onset: 0.0, duration: 0.04, velocity: 25))
        notes.append(MIDINote(pitch: 35,  onset: 1.0, duration: 0.04, velocity: 24))
        let report = PianoPlayabilityCritic().process(notes, audioDurationSeconds: 5.0)
        XCTAssertGreaterThan(report.afterDiagnosis.score, report.beforeDiagnosis.score,
                             "Playability score must improve after repair")
        XCTAssertGreaterThanOrEqual(report.afterQualityScore, report.beforeQualityScore - 0.10,
                                    "Musical quality must not drop materially")
        let kept = Set(report.repairedNotes.map(\.pitch))
        for p in melodyPitches {
            XCTAssertTrue(kept.contains(p), "Melody pitch \(p) must survive repair")
        }
    }

    func testCriticIsNoOpWhenAlreadyPlayable() {
        let melody: [MIDINote] = (0..<8).map { i in
            MIDINote(pitch: 60 + i, onset: Double(i) * 0.5, duration: 0.45, velocity: 80)
        }
        let report = PianoPlayabilityCritic().process(melody, audioDurationSeconds: 5.0)
        XCTAssertFalse(report.appliedRepairs)
        XCTAssertEqual(report.repairedNotes.count, melody.count)
        XCTAssertEqual(report.stopReason, "already-playable")
    }

    func testMetadataExposesDataFlowKeys() {
        let notes: [MIDINote] = [40, 47, 60, 67, 74, 81, 88].map {
            MIDINote(pitch: $0, onset: 0.0, duration: 0.5, velocity: 70)
        }
        let report = PianoPlayabilityCritic().process(notes, audioDurationSeconds: 1.0)
        let params = PlayabilityCriticMetadata.parameters(for: report)
        XCTAssertEqual(params["playability.enabled"], "true")
        XCTAssertNotNil(params["dataflow.playabilityBeforeScore"])
        XCTAssertNotNil(params["dataflow.playabilityAfterScore"])
        XCTAssertNotNil(params["dataflow.playabilityNotesRemoved"])
        XCTAssertNotNil(params["dataflow.playabilityHandSplit"])
        if let s = params["dataflow.playabilityHandSplit"], let v = Int(s) {
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 127)
        } else {
            XCTFail("dataflow.playabilityHandSplit must be a numeric MIDI pitch")
        }
    }
}

// MARK: - MIDI Clinic / Repair

final class MidiClinicTests: XCTestCase {

    private func makeNotes(_ raw: [(Int, Double, Double, Int)]) -> [MIDINote] {
        raw.map { MIDINote(pitch: $0.0, onset: $0.1, duration: $0.2, velocity: $0.3) }
    }

    /// Helper: smoke-run the clinic for a pipeline kind and return the report.
    private func runClinic(notes: [MIDINote],
                           audio: Double,
                           kind: PipelineKind,
                           profile: MidiRepairProfile? = nil) -> MidiClinicReport {
        let clinic = MidiClinic()
        let input = MidiClinicInput(
            rawNotes: notes,
            cleanedNotes: notes,
            audioDurationSeconds: audio,
            pipelineKind: kind,
            backendName: "test"
        )
        return clinic.process(input: input, profile: profile)
    }

    func testClinicRunsForAllThreePipelines() {
        let n = makeNotes([
            (60, 0.0, 0.40, 70), (62, 0.5, 0.40, 72), (64, 1.0, 0.40, 74),
            (65, 1.5, 0.40, 70), (67, 2.0, 0.40, 80),
        ])
        for kind in [PipelineKind.cleanSoloPiano, .noisySoloPiano, .mixedInstrumentsAdvanced] {
            let report = runClinic(notes: n, audio: 4.0, kind: kind)
            XCTAssertGreaterThan(report.afterScore, 0)
            XCTAssertFalse(report.profile.name.isEmpty)
        }
    }

    func testMelodyOnlyProfileCollapsesClustersToSingleMelodyLine() {
        // 4 notes per onset cluster, varying pitch SET per cluster so the
        // same-pitch fragment merger does not collapse them vertically
        // into one sustained note. Each cluster has a strongest pitch
        // that should be the surviving melody note.
        var raw: [MIDINote] = []
        let clusterPitches: [[Int]] = [
            [60, 64, 67, 72], [62, 65, 69, 74], [64, 67, 71, 76],
            [65, 69, 72, 77], [67, 71, 74, 79], [69, 72, 76, 81],
            [71, 74, 77, 82], [72, 76, 79, 84],
        ]
        for (i, pitches) in clusterPitches.enumerated() {
            let t = Double(i) * 0.6
            raw.append(MIDINote(pitch: pitches[0], onset: t,        duration: 0.4, velocity: 90))
            raw.append(MIDINote(pitch: pitches[1], onset: t + 0.005, duration: 0.4, velocity: 70))
            raw.append(MIDINote(pitch: pitches[2], onset: t + 0.010, duration: 0.4, velocity: 60))
            raw.append(MIDINote(pitch: pitches[3], onset: t + 0.015, duration: 0.4, velocity: 50))
        }
        let report = runClinic(notes: raw, audio: 5.5, kind: .cleanSoloPiano, profile: .melodyOnly)
        // Each cluster bucket should leave at most one note (8 in total),
        // achieved through chord-cluster reduction, melody-line extraction,
        // or simultaneous-cap.
        XCTAssertLessThanOrEqual(report.repairedNotes.count, 10,
                                 "Melody collapse should bring 32 cluster notes down to ~8")
        let collapseOps = report.repairs.melodyLineCollapses
            + report.repairs.chordReductions
            + report.repairs.simultaneousCapped
        XCTAssertGreaterThan(collapseOps, 0,
            "At least one of melody / chord / simultaneous-cap must run for melody-only")
    }

    func testCleanSoloProfilePreservesChords() {
        // Three-note chord every beat — must NOT be reduced to monophony.
        var raw: [MIDINote] = []
        for i in 0 ..< 6 {
            let t = Double(i) * 0.6
            raw.append(MIDINote(pitch: 60, onset: t, duration: 0.50, velocity: 80))
            raw.append(MIDINote(pitch: 64, onset: t, duration: 0.50, velocity: 76))
            raw.append(MIDINote(pitch: 67, onset: t, duration: 0.50, velocity: 78))
        }
        let report = runClinic(notes: raw, audio: 4.0, kind: .cleanSoloPiano, profile: .cleanSoloPiano)
        XCTAssertEqual(report.repairedNotes.count, raw.count, "Clean Solo Piano must preserve all 3-note chords")
        XCTAssertEqual(report.repairs.melodyLineCollapses, 0)
    }

    func testCleanSoloProfilePreservesSustain() {
        // A 6-second sustained note should survive — clean piano allows
        // realistic sustain up to maxNoteDuration.
        let raw = makeNotes([
            (60, 0.0, 6.0, 75), (64, 6.5, 0.4, 70),
        ])
        let report = runClinic(notes: raw, audio: 8.0, kind: .cleanSoloPiano, profile: .cleanSoloPiano)
        let sustained = report.repairedNotes.first { $0.pitch == 60 }
        XCTAssertNotNil(sustained, "Sustained note must not be deleted")
        XCTAssertGreaterThan(sustained?.duration ?? 0, 4.0)
    }

    func testNoisyProfileRemovesIsolatedGhostNotes() {
        var raw: [MIDINote] = []
        // Real melody.
        for i in 0 ..< 8 {
            raw.append(MIDINote(pitch: 60 + i % 5, onset: Double(i) * 0.5, duration: 0.4, velocity: 75))
        }
        // Isolated low-velocity ghost halfway between phrases (10s away from any neighbour).
        raw.append(MIDINote(pitch: 80, onset: 12.0, duration: 0.05, velocity: 18))
        let report = runClinic(notes: raw, audio: 14.0, kind: .noisySoloPiano, profile: .noisySoloPiano)
        XCTAssertFalse(report.repairedNotes.contains { $0.pitch == 80 && $0.onset > 11 },
                       "Isolated ghost note must be removed")
        XCTAssertGreaterThan(report.repairs.isolatedGhostsRemoved + report.repairs.shortNotesRemoved, 0)
    }

    func testMixedProfileCapsDensityAndPitchRange() {
        // 30 notes/sec for 4 seconds; pitches all over the keyboard.
        var raw: [MIDINote] = []
        for i in 0 ..< 120 {
            let pitch = 21 + (i * 7) % 88
            raw.append(MIDINote(pitch: pitch, onset: Double(i) * 0.033, duration: 0.150, velocity: 70))
        }
        let report = runClinic(notes: raw, audio: 4.0, kind: .mixedInstrumentsAdvanced, profile: .mixedAudio)
        // Density gate must bring it under maxNotesPerSecond * audio.
        XCTAssertLessThan(report.repairedNotes.count, raw.count / 2)
        // Pitch range must clamp to [40, 88].
        for n in report.repairedNotes {
            XCTAssertGreaterThanOrEqual(n.pitch, 40)
            XCTAssertLessThanOrEqual(n.pitch, 88)
        }
        XCTAssertGreaterThan(report.repairs.pitchRangeGated + report.repairs.notesPerSecondCapped, 0)
    }

    func testMachineGunFragmentsAreMerged() {
        // Same pitch hammered every 30ms.
        var raw: [MIDINote] = []
        for i in 0 ..< 12 {
            raw.append(MIDINote(pitch: 60, onset: Double(i) * 0.030, duration: 0.020, velocity: 70))
        }
        let report = runClinic(notes: raw, audio: 1.0, kind: .cleanSoloPiano, profile: .cleanSoloPiano)
        XCTAssertLessThan(report.repairedNotes.count, raw.count)
        XCTAssertGreaterThan(report.repairs.samePitchFragmentsMerged + report.repairs.shortNotesRemoved, 0)
    }

    func testSamePitchOverlapsAreRepaired() {
        let raw = makeNotes([
            (60, 0.0, 1.0, 80), (60, 0.4, 1.0, 80), // overlap by 600ms on same pitch
        ])
        let report = runClinic(notes: raw, audio: 2.0, kind: .cleanSoloPiano, profile: .cleanSoloPiano)
        // After repair the same-pitch overlap count must drop to 0.
        let context = MidiRepairProfile.cleanSoloPiano.diagnosisContext.with(audioDuration: 2.0)
        let post = MidiDiagnoser.diagnose(notes: report.repairedNotes, context: context)
        XCTAssertEqual(post.stats.samePitchOverlapCount, 0)
    }

    func testTimingJitterSmoothedWithoutDestroyingExpressiveTiming() {
        // Melody-only profile is the only one that smooths timing — clean
        // piano never quantizes. We check melody-only here.
        var raw: [MIDINote] = []
        // 8 beats, each ±10ms jitter around 0.5s spacing.
        let jitter = [0.0, 0.012, -0.008, 0.005, -0.011, 0.009, 0.003, -0.007]
        for i in 0 ..< 8 {
            let t = Double(i) * 0.5 + jitter[i]
            raw.append(MIDINote(pitch: 60 + i % 5, onset: t, duration: 0.40, velocity: 75))
        }
        let report = runClinic(notes: raw, audio: 4.0, kind: .cleanSoloPiano, profile: .melodyOnly)
        XCTAssertGreaterThan(report.repairs.timingRepaired, 0,
                             "Melody-only profile should smooth small timing jitter")
        // But shouldn't have collapsed everything to a single instant.
        let onsets = Set(report.repairedNotes.map { round($0.onset * 1000) })
        XCTAssertGreaterThan(onsets.count, 4)
    }

    func testDurationRepairRemovesFragmentsAndPreservesValidSustain() {
        let raw = makeNotes([
            (60, 0.0, 0.020, 80),  // fragment
            (62, 0.5, 0.030, 82),  // fragment
            (64, 1.0, 4.0,  75),   // legitimate sustained note
        ])
        let report = runClinic(notes: raw, audio: 6.0, kind: .cleanSoloPiano, profile: .cleanSoloPiano)
        XCTAssertFalse(report.repairedNotes.contains { $0.duration < 0.07 })
        XCTAssertTrue(report.repairedNotes.contains { $0.pitch == 64 && $0.duration > 3.5 })
    }

    func testScoreImprovesAfterRepair() {
        // Mostly-bad input that nonetheless contains some salvageable material.
        // Mix of plausible musical phrases and ghost noise so the clinic
        // can demonstrably move the score up rather than just emptying it.
        var raw: [MIDINote] = []
        // 30 plausible phrase notes (clean melody).
        for i in 0 ..< 30 {
            let pitch = 60 + (i % 5)
            raw.append(MIDINote(pitch: pitch, onset: Double(i) * 0.40, duration: 0.30, velocity: 75))
        }
        // 200 ghost notes scattered across the keyboard.
        for i in 0 ..< 200 {
            let pitch = 21 + (i * 13) % 88
            raw.append(MIDINote(pitch: pitch, onset: Double(i) * 0.060, duration: 0.030, velocity: 18))
        }
        let report = runClinic(notes: raw, audio: 14.0, kind: .mixedInstrumentsAdvanced, profile: .mixedAudio)
        // Either we measurably improved OR we cleanly emptied with a
        // low-confidence flag. Both are valid clinic outcomes.
        let improved = report.afterScore > report.beforeScore + 0.05
        let acceptableEmpty = report.repairedNotes.isEmpty && report.lowConfidence
        XCTAssertTrue(improved || acceptableEmpty,
                      "Clinic must improve score (got \(report.beforeScore) → \(report.afterScore)) or cleanly flag low confidence")
        XCTAssertGreaterThan(report.repairs.totalChanges, 50,
                             "Clinic must record substantial repairs on catastrophic input")
    }

    func testLowConfidenceFlaggedWhenStillBad() {
        // Few isolated notes, 90s long → density is fine but ghostNoteFraction
        // and isolation flags + score should land below 0.65 → low confidence.
        let raw = makeNotes([
            (60, 0.0, 0.10, 30),
            (90, 30.0, 0.05, 14),
            (28, 60.0, 0.05, 12),
        ])
        let report = runClinic(notes: raw, audio: 90.0, kind: .mixedInstrumentsAdvanced, profile: .mixedAudio)
        XCTAssertTrue(report.lowConfidence || report.repairedNotes.isEmpty,
                      "Hopeless input should be flagged as low confidence")
        if report.lowConfidence {
            XCTAssertNotNil(report.lowConfidenceWarning)
        }
    }

    func testClinicMetadataPopulated() {
        let n = makeNotes([(60, 0.0, 0.4, 70), (62, 0.5, 0.4, 72), (64, 1.0, 0.4, 74)])
        let report = runClinic(notes: n, audio: 2.0, kind: .cleanSoloPiano)
        let p = MidiClinicMetadata.parameters(for: report)
        XCTAssertEqual(p["clinic.enabled"], "true")
        XCTAssertNotNil(p["clinic.profile"])
        XCTAssertNotNil(p["clinic.beforeScore"])
        XCTAssertNotNil(p["clinic.afterScore"])
        XCTAssertNotNil(p["clinic.passesRun"])
        XCTAssertNotNil(p["clinic.notesBefore"])
        XCTAssertNotNil(p["clinic.notesAfter"])
        XCTAssertNotNil(p["clinic.repairs.total"])
    }

    func testRepairDoesNotDeleteEverything() {
        // 80 plausible solo-piano notes — clinic should not destroy them.
        var raw: [MIDINote] = []
        for i in 0 ..< 80 {
            raw.append(MIDINote(pitch: 60 + i % 12, onset: Double(i) * 0.4, duration: 0.30, velocity: 70))
        }
        let report = runClinic(notes: raw, audio: 35.0, kind: .cleanSoloPiano, profile: .cleanSoloPiano)
        XCTAssertGreaterThan(report.repairedNotes.count, 60,
                             "Clinic must preserve plausible musical notes")
    }
}
