import Foundation

/// View-only filter applied to a transcription run before it is rendered.
/// Underlying notes are never mutated — this is purely a presentation layer.
public struct NoteDisplayFilter: Equatable {
    /// Hide notes whose velocity (used as a confidence proxy by `BasicPianoModelRunner`)
    /// is below this value. Range 0…127.
    public var minVelocity: Int
    /// Hide notes whose duration is shorter than this (seconds).
    public var minDuration: Double
    /// When true, also drop notes shorter than `veryShortThreshold` regardless of
    /// `minDuration` — useful for collapsing percussive flicker.
    public var hideVeryShort: Bool
    /// Velocity scaling factor applied to the rendered note (1.0 = unchanged).
    public var velocityScale: Double
    /// When true, all notes are rendered untouched. Use for debugging the raw
    /// pipeline output.
    public var showRaw: Bool

    public static let veryShortThreshold: Double = 0.06

    /// Reasonable defaults for first-time view of a run.
    public static let defaults = NoteDisplayFilter(
        minVelocity: 24,
        minDuration: 0.10,
        hideVeryShort: true,
        velocityScale: 1.0,
        showRaw: false
    )

    public init(minVelocity: Int = 24,
                minDuration: Double = 0.10,
                hideVeryShort: Bool = true,
                velocityScale: Double = 1.0,
                showRaw: Bool = false) {
        self.minVelocity = minVelocity
        self.minDuration = minDuration
        self.hideVeryShort = hideVeryShort
        self.velocityScale = velocityScale
        self.showRaw = showRaw
    }

    public func apply(to notes: [MIDINote]) -> [MIDINote] {
        if showRaw { return notes.map(scaleVelocity) }
        return notes.compactMap { note in
            if note.velocity < minVelocity { return nil }
            if note.duration < minDuration { return nil }
            if hideVeryShort && note.duration < Self.veryShortThreshold { return nil }
            return scaleVelocity(note)
        }
    }

    private func scaleVelocity(_ note: MIDINote) -> MIDINote {
        guard velocityScale != 1.0 else { return note }
        let scaled = max(1, min(127, Int(Double(note.velocity) * velocityScale)))
        return MIDINote(id: note.id,
                        pitch: note.pitch,
                        onset: note.onset,
                        duration: note.duration,
                        velocity: scaled)
    }
}
