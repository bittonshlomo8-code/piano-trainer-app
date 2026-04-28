import SwiftUI
import PianoTranscriptionKit

/// Synthesia-style falling-note visualizer driven by the final repaired MIDI
/// notes from a `TranscriptionRun`. Vertical bars descend toward a horizontal
/// piano keyboard; the bottom of each bar reaches the keyboard exactly at the
/// note's onset time, and the corresponding key lights up while the note is
/// sounding.
///
/// The view renders entirely on the main thread via `Canvas` so it scales
/// cleanly with playback updates. Notes are filtered to the visible time
/// window per frame to keep redraw cost bounded regardless of run length.
struct FallingNoteView: View {
    let notes: [MIDINote]
    let playheadTime: Double
    /// How far ahead in time the top of the falling area peeks. Larger values
    /// mean smaller (slower-feeling) bars; smaller values mean closer to the
    /// keyboard and faster-feeling bars.
    var lookaheadSeconds: Double = 4.0
    var onSeek: ((Double) -> Void)? = nil

    private let minPitch = 21    // A0
    private let maxPitch = 108   // C8

    var body: some View {
        GeometryReader { geo in
            let keyboardHeight: CGFloat = 92
            VStack(spacing: 0) {
                FallingArea(
                    notes: notes,
                    playheadTime: playheadTime,
                    lookaheadSeconds: lookaheadSeconds,
                    minPitch: minPitch,
                    maxPitch: maxPitch
                )
                .frame(height: max(0, geo.size.height - keyboardHeight))

                Rectangle()
                    .fill(Color.white.opacity(0.45))
                    .frame(height: 1)

                FallingKeyboardView(
                    notes: notes,
                    playheadTime: playheadTime,
                    minPitch: minPitch,
                    maxPitch: maxPitch
                )
                .frame(height: keyboardHeight)
            }
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.10))
    }
}

// MARK: - Falling area

private struct FallingArea: View {
    let notes: [MIDINote]
    let playheadTime: Double
    let lookaheadSeconds: Double
    let minPitch: Int
    let maxPitch: Int

    var body: some View {
        Canvas { ctx, size in
            guard size.height > 0, size.width > 0 else { return }
            let totalWhites = PianoKeyGeometry.whiteKeyCount(in: minPitch...maxPitch)
            guard totalWhites > 0 else { return }
            let pxPerSec = size.height / CGFloat(lookaheadSeconds)
            let keyboardTopY = size.height

            // Background lane separators (subtle).
            for i in 1..<totalWhites {
                let x = CGFloat(i) * size.width / CGFloat(totalWhites)
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.04)), lineWidth: 0.5)
            }

            // Time gridlines every second.
            let firstSec = Int(floor(playheadTime))
            let lastSec = Int(ceil(playheadTime + lookaheadSeconds))
            for s in firstSec...lastSec {
                let y = keyboardTopY - CGFloat(Double(s) - playheadTime) * pxPerSec
                guard y >= 0, y <= size.height else { continue }
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
            }

            // Falling bars. Skip notes outside the visible time window.
            for note in notes {
                guard note.pitch >= minPitch, note.pitch <= maxPitch else { continue }
                let timeUntilEnd = (note.onset + note.duration) - playheadTime
                let timeUntilOnset = note.onset - playheadTime
                guard timeUntilEnd > 0 else { continue }                  // already finished
                guard timeUntilOnset < lookaheadSeconds + 0.5 else { continue } // too far in future

                let yBottomRaw = keyboardTopY - CGFloat(timeUntilOnset) * pxPerSec
                let yTopRaw    = keyboardTopY - CGFloat(timeUntilEnd) * pxPerSec
                // Clamp the bar's bottom to the keyboard so the note appears
                // to "press" the key while it sounds. The top continues to
                // descend until the duration is consumed.
                let yBottom = min(yBottomRaw, keyboardTopY)
                let yTop    = yTopRaw
                let height  = yBottom - yTop
                guard height > 0.5 else { continue }

                let geom = PianoKeyGeometry.barRect(
                    forPitch: note.pitch,
                    minPitch: minPitch,
                    maxPitch: maxPitch,
                    canvasWidth: size.width
                )

                let color = barColor(for: note)
                let rect = CGRect(x: geom.x + 1, y: yTop, width: max(2, geom.width - 2), height: height)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
                // Subtle highlight along the leading (bottom) edge so the
                // moment of impact reads clearly.
                let edge = CGRect(x: geom.x + 1, y: yBottom - 2, width: max(2, geom.width - 2), height: 2)
                ctx.fill(Path(roundedRect: edge, cornerRadius: 1), with: .color(.white.opacity(0.55)))
            }
        }
    }

    private func barColor(for note: MIDINote) -> Color {
        // Hue by octave so chords read at a glance; saturation by velocity.
        let octave = Double((note.pitch - 12) / 12)
        let hue = (octave / 8.0).truncatingRemainder(dividingBy: 1.0)
        let alpha = max(0.45, min(1.0, Double(note.velocity) / 127.0 + 0.25))
        return Color(hue: hue, saturation: 0.7, brightness: 0.95).opacity(alpha)
    }
}

// MARK: - Keyboard with active highlights

private struct FallingKeyboardView: View {
    let notes: [MIDINote]
    let playheadTime: Double
    let minPitch: Int
    let maxPitch: Int

    var body: some View {
        Canvas { ctx, size in
            let totalWhites = PianoKeyGeometry.whiteKeyCount(in: minPitch...maxPitch)
            guard totalWhites > 0, size.width > 0 else { return }
            let active = activePitches()

            // White keys first.
            for pitch in minPitch...maxPitch where PianoKeyGeometry.isWhiteKey(pitch) {
                let geom = PianoKeyGeometry.barRect(
                    forPitch: pitch,
                    minPitch: minPitch,
                    maxPitch: maxPitch,
                    canvasWidth: size.width
                )
                let rect = CGRect(x: geom.x, y: 0, width: geom.width, height: size.height)
                let isActive = active.contains(pitch)
                let fill: Color = isActive ? Color(hue: 0.55, saturation: 0.8, brightness: 1.0) : .white
                ctx.fill(Path(rect), with: .color(fill))
                ctx.stroke(Path(rect), with: .color(.black.opacity(0.6)), lineWidth: 0.5)
            }

            // Then black keys on top so they overlap whites correctly.
            let blackHeight = size.height * 0.62
            for pitch in minPitch...maxPitch where !PianoKeyGeometry.isWhiteKey(pitch) {
                let geom = PianoKeyGeometry.barRect(
                    forPitch: pitch,
                    minPitch: minPitch,
                    maxPitch: maxPitch,
                    canvasWidth: size.width
                )
                let rect = CGRect(x: geom.x, y: 0, width: geom.width, height: blackHeight)
                let isActive = active.contains(pitch)
                let fill: Color = isActive ? Color(hue: 0.55, saturation: 0.9, brightness: 0.85) : .black
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(fill))
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            }
        }
    }

    private func activePitches() -> Set<Int> {
        var s = Set<Int>()
        for n in notes where n.onset <= playheadTime && playheadTime < n.onset + n.duration {
            s.insert(n.pitch)
        }
        return s
    }
}

// MARK: - Geometry

/// Pure-function helpers for laying out an 88-key piano horizontally inside an
/// arbitrary canvas width. Kept namespace-style so both the keyboard and the
/// falling-bar canvas use the exact same coordinates.
enum PianoKeyGeometry {
    /// Pitch classes (0=C..11=B) that are white keys.
    private static let whiteKeyDegrees: Set<Int> = [0, 2, 4, 5, 7, 9, 11]

    static func isWhiteKey(_ pitch: Int) -> Bool {
        whiteKeyDegrees.contains(((pitch % 12) + 12) % 12)
    }

    static func whiteKeyCount(in range: ClosedRange<Int>) -> Int {
        var n = 0
        for p in range where isWhiteKey(p) { n += 1 }
        return n
    }

    /// Returns the (x, width) of the bar/key column for the given pitch in a
    /// canvas of `canvasWidth`. White-key columns get the full slot width;
    /// black-key columns sit centered between their two adjacent whites and
    /// are narrower.
    static func barRect(forPitch pitch: Int, minPitch: Int, maxPitch: Int, canvasWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let totalWhites = whiteKeyCount(in: minPitch...maxPitch)
        let whiteWidth = canvasWidth / CGFloat(max(1, totalWhites))
        if isWhiteKey(pitch) {
            let idx = whiteKeyIndex(forPitch: pitch, minPitch: minPitch)
            return (CGFloat(idx) * whiteWidth, whiteWidth)
        } else {
            // Black-key center sits exactly on the boundary between the white
            // immediately below it and the next white above. So its center x
            // is (idx_of_left_white + 1) * whiteWidth.
            let leftWhite = whiteKeyIndex(forPitch: pitch - 1, minPitch: minPitch)
            let center = (CGFloat(leftWhite) + 1.0) * whiteWidth
            let blackWidth = whiteWidth * 0.62
            return (center - blackWidth / 2, blackWidth)
        }
    }

    /// 0-based index of the white key at or before `pitch`, counting from
    /// `minPitch`. Used by the geometry above and the keyboard renderer.
    static func whiteKeyIndex(forPitch pitch: Int, minPitch: Int) -> Int {
        var idx = -1
        for p in minPitch...pitch {
            if isWhiteKey(p) { idx += 1 }
        }
        return max(0, idx)
    }
}
