import Foundation

/// Pure logic for scheduling note on/off events relative to a start time.
///
/// The scheduler is intentionally side-effect-free so it can be unit-tested.
/// The view model wraps it and turns each event into an `AVAudioUnitSampler`
/// call on a `Task.sleep` delay.
public struct MIDIScheduler {
    public struct Event: Equatable {
        public enum Kind: Equatable { case on, off }
        public let kind: Kind
        public let pitch: Int
        public let velocity: Int
        /// Seconds from "now" (the value of `startTime` passed in) until the event fires.
        public let delay: Double

        public init(kind: Kind, pitch: Int, velocity: Int, delay: Double) {
            self.kind = kind
            self.pitch = pitch
            self.velocity = velocity
            self.delay = delay
        }
    }

    public init() {}

    /// Builds the on/off events that should fire when playback resumes from
    /// `startTime`. Notes that have already finished are skipped. Notes that
    /// are mid-flight when `startTime` falls inside them fire their note-on
    /// immediately and a note-off at the remaining time.
    public func events(for notes: [MIDINote], from startTime: Double) -> [Event] {
        var out: [Event] = []
        out.reserveCapacity(notes.count * 2)
        for note in notes {
            let end = note.onset + note.duration
            guard end > startTime else { continue }
            let onDelay = max(0, note.onset - startTime)
            let offDelay = max(onDelay, end - startTime)
            out.append(Event(kind: .on, pitch: note.pitch, velocity: note.velocity, delay: onDelay))
            out.append(Event(kind: .off, pitch: note.pitch, velocity: note.velocity, delay: offDelay))
        }
        return out
    }

    /// Returns the set of pitches that are sounding at exactly `time` (note-on
    /// has fired, note-off has not). Used by tests to verify that toggling
    /// playback modes does not leave a sampler with duplicated active pitches.
    public func activePitches(in notes: [MIDINote], at time: Double) -> Set<Int> {
        var active = Set<Int>()
        for note in notes where note.onset <= time && time < note.onset + note.duration {
            active.insert(note.pitch)
        }
        return active
    }
}
