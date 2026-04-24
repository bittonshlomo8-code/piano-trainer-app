import Foundation

public struct MIDINote: Codable, Identifiable, Equatable, Hashable {
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
}
