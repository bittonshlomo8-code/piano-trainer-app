import Foundation

/// Generates a Standard MIDI File (SMF) byte stream from an array of MIDINote.
public final class MIDIGenerator {
    public init() {}

    public func generateMIDI(from notes: [MIDINote], tempo: Double = 120) -> Data {
        let microsPerBeat = UInt32(60_000_000 / tempo)
        let ticksPerBeat: UInt16 = 480

        var trackData = Data()

        // Tempo event
        trackData += midiEvent(delta: 0, event: [0xFF, 0x51, 0x03] + uint24Bytes(microsPerBeat))

        // Build events sorted by time
        var events: [(tick: Int, data: [UInt8])] = []

        for note in notes {
            let onTick = Int(note.onset * Double(ticksPerBeat) * tempo / 60.0)
            let offTick = Int((note.onset + note.duration) * Double(ticksPerBeat) * tempo / 60.0)
            let vel = UInt8(max(1, min(127, note.velocity)))
            let pitch = UInt8(max(0, min(127, note.pitch)))

            events.append((onTick,  [0x90, pitch, vel]))   // note on
            events.append((offTick, [0x80, pitch, 0x00]))  // note off
        }

        events.sort { $0.tick < $1.tick }

        var prevTick = 0
        for evt in events {
            let delta = max(0, evt.tick - prevTick)
            prevTick = evt.tick
            trackData += midiEvent(delta: delta, event: evt.data)
        }

        // End-of-track
        trackData += [0x00, 0xFF, 0x2F, 0x00]

        var midi = Data()
        // Header chunk
        midi += "MThd".data(using: .ascii)!
        midi += uint32Bytes(6)                   // header length
        midi += uint16Bytes(0)                   // format 0 (single track)
        midi += uint16Bytes(1)                   // 1 track
        midi += uint16Bytes(ticksPerBeat)        // resolution

        // Track chunk
        midi += "MTrk".data(using: .ascii)!
        midi += uint32Bytes(UInt32(trackData.count))
        midi += trackData

        return midi
    }

    // MARK: - Helpers

    private func midiEvent(delta: Int, event: [UInt8]) -> Data {
        var d = Data(varLenBytes(delta))
        d += event
        return d
    }

    private func varLenBytes(_ value: Int) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = []
        bytes.append(UInt8(v & 0x7F))
        v >>= 7
        while v > 0 {
            bytes.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        return bytes.reversed()
    }

    private func uint32Bytes(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private func uint24Bytes(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private func uint16Bytes(_ v: UInt16) -> [UInt8] {
        [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
}
