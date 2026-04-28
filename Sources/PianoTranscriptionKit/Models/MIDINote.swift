import Foundation

public struct MIDINote: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let pitch: Int       // 0–127
    public let onset: Double    // seconds
    public let duration: Double // seconds
    public let velocity: Int    // 0–127

    public init(id: UUID = UUID(), pitch: Int, onset: Double, duration: Double, velocity: Int) {
        self.id = id
        self.pitch = pitch
        self.onset = onset
        self.duration = duration
        self.velocity = velocity
    }

    public var noteName: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (pitch / 12) - 1
        return "\(names[pitch % 12])\(octave)"
    }

    public var isBlackKey: Bool {
        [1, 3, 6, 8, 10].contains(pitch % 12)
    }

    // Equality and hashing are based on musical content, not the randomly-assigned
    // `id`. Two notes with the same pitch/onset/duration/velocity represent the same
    // musical event — callers that care about identity can compare `id` explicitly.
    public static func == (lhs: MIDINote, rhs: MIDINote) -> Bool {
        lhs.pitch    == rhs.pitch    &&
        lhs.onset    == rhs.onset    &&
        lhs.duration == rhs.duration &&
        lhs.velocity == rhs.velocity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pitch)
        hasher.combine(onset)
        hasher.combine(duration)
        hasher.combine(velocity)
    }
}
