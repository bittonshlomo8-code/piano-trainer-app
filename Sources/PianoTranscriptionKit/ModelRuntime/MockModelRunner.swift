import Foundation
import AVFoundation

/// Generates plausible-sounding random piano notes for pipeline testing.
public final class MockModelRunner: ModelRunner, @unchecked Sendable {
    public let name = "MockModelRunner v1"

    private let seed: UInt64

    public init(seed: UInt64 = 42) {
        self.seed = seed
    }

    public func transcribe(audioURL: URL) async throws -> [MIDINote] {
        let duration = audioDuration(url: audioURL)

        // Simulate processing time
        try await Task.sleep(nanoseconds: 500_000_000)

        return generateNotes(audioDuration: duration)
    }

    private func audioDuration(url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 30
    }

    private func generateNotes(audioDuration: Double) -> [MIDINote] {
        var rng = SeededRNG(seed: seed)
        var notes: [MIDINote] = []

        // Generate a mock musical phrase
        let tempos: [Double] = [80, 100, 120]
        let bpm = tempos[Int(rng.next() % 3)]
        let beatDuration = 60.0 / bpm

        // Common piano scales: C major, A minor
        let cMajorPitches = [60, 62, 64, 65, 67, 69, 71, 72, 74, 76, 77, 79, 81, 83, 84]
        let chords: [[Int]] = [
            [60, 64, 67],  // C major
            [62, 65, 69],  // D minor
            [64, 67, 71],  // E minor
            [65, 69, 72],  // F major
            [67, 71, 74],  // G major
            [69, 72, 76],  // A minor
        ]

        var time = 0.5
        while time < audioDuration - 1.0 {
            let noteType = rng.next() % 4

            if noteType == 0 {
                // Chord
                let chord = chords[Int(rng.next() % UInt64(chords.count))]
                let chordDuration = beatDuration * Double(1 + rng.next() % 2)
                let velocity = 50 + Int(rng.next() % 40)
                for pitch in chord {
                    notes.append(MIDINote(
                        pitch: pitch,
                        onset: time,
                        duration: chordDuration * 0.9,
                        velocity: velocity
                    ))
                }
                time += chordDuration
            } else {
                // Melody note
                let pitchIdx = Int(rng.next() % UInt64(cMajorPitches.count))
                let pitch = cMajorPitches[pitchIdx]
                let duration = beatDuration * [0.25, 0.5, 1.0, 0.75][Int(rng.next() % 4)]
                let velocity = 60 + Int(rng.next() % 30)
                notes.append(MIDINote(
                    pitch: pitch,
                    onset: time,
                    duration: duration * 0.85,
                    velocity: velocity
                ))
                time += duration
            }
        }

        return notes
    }
}

// Simple LCG for reproducible mock output
private struct SeededRNG {
    var state: UInt64

    init(seed: UInt64) { state = seed ^ 0x6C62272E07BB0142 }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 32
    }
}
