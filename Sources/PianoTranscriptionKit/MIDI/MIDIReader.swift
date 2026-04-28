import Foundation

/// Minimal Standard MIDI File parser used by external-tool adapters
/// (Basic Pitch, ByteDance) to convert their on-disk `.mid` outputs into
/// `MIDINote` arrays. Handles Type 0 and Type 1 SMF, multiple tempo events,
/// running status, and note-on-with-velocity-zero as note-off.
///
/// Scope is intentionally narrow: only note events + tempo are interpreted.
/// Everything else (controllers, program changes, sysex, meta names) is
/// skipped without raising. The goal is "give me back the notes the model
/// emitted with seconds-accurate onsets/durations" — not full SMF fidelity.
public enum MIDIReader {

    public enum ReadError: Error, LocalizedError {
        case fileUnreadable(String)
        case invalidHeader
        case truncated

        public var errorDescription: String? {
            switch self {
            case .fileUnreadable(let m): return "MIDI file unreadable: \(m)"
            case .invalidHeader: return "MIDI file is missing a valid MThd header"
            case .truncated: return "MIDI file ended unexpectedly"
            }
        }
    }

    public static func read(url: URL) throws -> [MIDINote] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReadError.fileUnreadable(error.localizedDescription)
        }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> [MIDINote] {
        let bytes = [UInt8](data)
        guard bytes.count >= 14 else { throw ReadError.invalidHeader }
        guard bytes[0] == 0x4D, bytes[1] == 0x54, bytes[2] == 0x68, bytes[3] == 0x64 else {
            throw ReadError.invalidHeader
        }
        let division = (Int(bytes[12]) << 8) | Int(bytes[13])
        // SMPTE division (top bit set) — ticks per frame * frames per second.
        // We don't support SMPTE since neither Basic Pitch nor ByteDance emit it.
        guard division & 0x8000 == 0 else { return [] }
        let ticksPerBeat = max(1, division)

        // Walk all MTrk chunks. Each track has its own running status and tempo
        // map; for SMF Type 1 the first track typically owns tempos and the
        // rest own notes. Tracking tempo per-track is sufficient for what we
        // need because we always combine to absolute seconds.
        var notes: [MIDINote] = []
        var i = 14
        while i + 8 <= bytes.count {
            // Look for MTrk
            guard bytes[i] == 0x4D, bytes[i+1] == 0x54, bytes[i+2] == 0x72, bytes[i+3] == 0x6B else {
                // Some files (rare) pad with bytes between chunks — skip until we find one.
                i += 1
                continue
            }
            let len =
                (Int(bytes[i+4]) << 24) |
                (Int(bytes[i+5]) << 16) |
                (Int(bytes[i+6]) << 8)  |
                 Int(bytes[i+7])
            let trackStart = i + 8
            let trackEnd = min(bytes.count, trackStart + len)
            try notes.append(contentsOf: parseTrack(bytes: bytes,
                                                   start: trackStart,
                                                   end: trackEnd,
                                                   ticksPerBeat: ticksPerBeat))
            i = trackEnd
        }
        // Sort for downstream stability.
        notes.sort { $0.onset < $1.onset }
        return notes
    }

    private static func parseTrack(bytes: [UInt8], start: Int, end: Int, ticksPerBeat: Int) throws -> [MIDINote] {
        var i = start
        var absTick = 0
        // Default 120 BPM = 500_000 µs per beat.
        var microsPerBeat: Int = 500_000
        // Tempo map: piecewise-constant tempo segments measured in absolute ticks.
        // Each entry is (atTick, microsPerBeat). Used to convert ticks → seconds.
        var tempoMap: [(tick: Int, micros: Int)] = [(0, microsPerBeat)]
        var runningStatus: UInt8 = 0
        // Active note-ons keyed by (channel, pitch).
        var pending: [Int: (tick: Int, velocity: Int)] = [:]
        var notes: [MIDINote] = []

        while i < end {
            // Variable-length delta time
            var delta = 0
            while i < end {
                let b = bytes[i]; i += 1
                delta = (delta << 7) | Int(b & 0x7F)
                if b & 0x80 == 0 { break }
                if delta > (1 << 28) { throw ReadError.truncated }
            }
            absTick += delta
            guard i < end else { break }

            var status = bytes[i]
            if status < 0x80 {
                // Running status — reuse last status, byte we read is data.
                status = runningStatus
            } else {
                i += 1
                runningStatus = status
            }

            if status == 0xFF {
                // Meta event
                guard i < end else { break }
                let type = bytes[i]; i += 1
                var len = 0
                while i < end {
                    let b = bytes[i]; i += 1
                    len = (len << 7) | Int(b & 0x7F)
                    if b & 0x80 == 0 { break }
                }
                if i + len > end { throw ReadError.truncated }
                if type == 0x51 && len == 3 {
                    let m = (Int(bytes[i]) << 16) | (Int(bytes[i+1]) << 8) | Int(bytes[i+2])
                    if m > 0 {
                        microsPerBeat = m
                        tempoMap.append((absTick, microsPerBeat))
                    }
                }
                i += len
                if type == 0x2F { break } // End of track
            } else if status == 0xF0 || status == 0xF7 {
                // SysEx — read varlen length then skip
                var len = 0
                while i < end {
                    let b = bytes[i]; i += 1
                    len = (len << 7) | Int(b & 0x7F)
                    if b & 0x80 == 0 { break }
                }
                i += len
            } else {
                let high = status & 0xF0
                switch high {
                case 0x90, 0x80:
                    guard i + 1 < end else { return notes }
                    let pitch = Int(bytes[i]); i += 1
                    let vel = Int(bytes[i]); i += 1
                    let isOn = (high == 0x90 && vel > 0)
                    let key = (Int(status & 0x0F) << 8) | pitch
                    if isOn {
                        pending[key] = (absTick, vel)
                    } else {
                        if let on = pending.removeValue(forKey: key) {
                            let onset = ticksToSeconds(on.tick, tempoMap: tempoMap, ticksPerBeat: ticksPerBeat)
                            let endSec = ticksToSeconds(absTick, tempoMap: tempoMap, ticksPerBeat: ticksPerBeat)
                            let dur = max(0.001, endSec - onset)
                            notes.append(MIDINote(
                                pitch: pitch,
                                onset: onset,
                                duration: dur,
                                velocity: max(1, min(127, on.velocity))
                            ))
                        }
                    }
                case 0xA0, 0xB0, 0xE0:
                    // 2-byte data
                    i += 2
                case 0xC0, 0xD0:
                    // 1-byte data
                    i += 1
                default:
                    // Unknown — bail to avoid running off the end
                    return notes
                }
            }
        }

        // Any note-ons without matching offs end at the last seen tick.
        if !pending.isEmpty {
            let lastSec = ticksToSeconds(absTick, tempoMap: tempoMap, ticksPerBeat: ticksPerBeat)
            for (key, on) in pending {
                let pitch = key & 0xFF
                let onset = ticksToSeconds(on.tick, tempoMap: tempoMap, ticksPerBeat: ticksPerBeat)
                let dur = max(0.001, lastSec - onset)
                notes.append(MIDINote(
                    pitch: pitch,
                    onset: onset,
                    duration: dur,
                    velocity: max(1, min(127, on.velocity))
                ))
            }
        }
        return notes
    }

    /// Convert an absolute tick to absolute seconds using a piecewise tempo map.
    private static func ticksToSeconds(_ tick: Int, tempoMap: [(tick: Int, micros: Int)], ticksPerBeat: Int) -> Double {
        var seconds: Double = 0
        var lastTick = 0
        var lastMicros = tempoMap.first?.micros ?? 500_000
        for entry in tempoMap {
            if entry.tick >= tick { break }
            let span = entry.tick - lastTick
            seconds += Double(span) * Double(lastMicros) / 1_000_000.0 / Double(ticksPerBeat)
            lastTick = entry.tick
            lastMicros = entry.micros
        }
        let span = tick - lastTick
        seconds += Double(span) * Double(lastMicros) / 1_000_000.0 / Double(ticksPerBeat)
        return seconds
    }
}
