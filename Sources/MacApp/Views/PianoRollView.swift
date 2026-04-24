import SwiftUI
import PianoTranscriptionKit

struct PianoRollView: View {
    let runs: [AnnotatedRun]
    let duration: Double
    let playheadTime: Double
    var onSeek: ((Double) -> Void)?

    // Layout constants
    private let keyWidth: CGFloat = 28
    private let minPitch = 21   // A0
    private let maxPitch = 108  // C8
    private let rowHeight: CGFloat = 8
    private var pitchCount: Int { maxPitch - minPitch + 1 }

    struct AnnotatedRun: Identifiable {
        let id: UUID
        let notes: [MIDINote]
        let color: Color
        let label: String
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    let totalHeight = CGFloat(pitchCount) * rowHeight
                    let pxPerSec: CGFloat = duration > 0 ? (geo.size.width - keyWidth) / CGFloat(duration) : 50

                    // Pitch grid
                    Canvas { ctx, size in
                        drawGrid(ctx: ctx, size: size, pxPerSec: pxPerSec)
                    }
                    .frame(width: keyWidth + CGFloat(duration) * pxPerSec, height: totalHeight)

                    // Notes for each run
                    ForEach(runs) { run in
                        Canvas { ctx, size in
                            drawNotes(ctx: ctx, run: run, pxPerSec: pxPerSec, totalHeight: totalHeight)
                        }
                        .frame(width: keyWidth + CGFloat(duration) * pxPerSec, height: totalHeight)
                    }

                    // Playhead
                    if duration > 0 {
                        let x = keyWidth + CGFloat(playheadTime) * pxPerSec
                        Rectangle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 2, height: totalHeight)
                            .offset(x: x - 1)
                            .allowsHitTesting(false)
                    }

                    // Piano keys overlay (left)
                    PianoKeysView(minPitch: minPitch, maxPitch: maxPitch, rowHeight: rowHeight)
                        .frame(width: keyWidth, height: totalHeight)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            let pxPerSec: CGFloat = (geo.size.width - keyWidth) / CGFloat(duration)
                            let t = Double(value.location.x - keyWidth) / Double(pxPerSec)
                            onSeek?(max(0, min(t, duration)))
                        }
                )
            }
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.12))
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize, pxPerSec: CGFloat) {
        let totalHeight = CGFloat(pitchCount) * rowHeight

        for i in 0..<pitchCount {
            let pitch = maxPitch - i
            let y = CGFloat(i) * rowHeight
            let isBlack = [1, 3, 6, 8, 10].contains(pitch % 12)
            let bg = isBlack ? Color(white: 0.11) : Color(white: 0.15)
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)), with: .color(bg))
        }

        // C lines
        for i in 0..<pitchCount {
            let pitch = maxPitch - i
            if pitch % 12 == 0 {
                let y = CGFloat(i) * rowHeight
                var p = Path()
                p.move(to: CGPoint(x: keyWidth, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            }
        }

        // Beat lines every ~1 second
        if duration > 0 {
            var t: CGFloat = 0
            while t <= CGFloat(duration) {
                let x = keyWidth + t * pxPerSec
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: totalHeight))
                ctx.stroke(p, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
                t += 1
            }
        }
    }

    private func drawNotes(ctx: GraphicsContext, run: AnnotatedRun, pxPerSec: CGFloat, totalHeight: CGFloat) {
        for note in run.notes {
            guard note.pitch >= minPitch && note.pitch <= maxPitch else { continue }
            let row = maxPitch - note.pitch
            let x = keyWidth + CGFloat(note.onset) * pxPerSec
            let w = max(2, CGFloat(note.duration) * pxPerSec - 1)
            let y = CGFloat(row) * rowHeight + 1
            let h = rowHeight - 2

            let alpha = Double(note.velocity) / 127.0 * 0.6 + 0.4
            let rect = CGRect(x: x, y: y, width: w, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(run.color.opacity(alpha)))
        }
    }
}

private struct PianoKeysView: View {
    let minPitch: Int
    let maxPitch: Int
    let rowHeight: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let pitchCount = maxPitch - minPitch + 1
            for i in 0..<pitchCount {
                let pitch = maxPitch - i
                let y = CGFloat(i) * rowHeight
                let isBlack = [1, 3, 6, 8, 10].contains(pitch % 12)
                let fill = isBlack ? Color.black : Color.white
                ctx.fill(
                    Path(CGRect(x: 0, y: y + 0.5, width: size.width - 1, height: rowHeight - 1)),
                    with: .color(fill)
                )
            }
        }
    }
}

extension PianoRollView.AnnotatedRun {
    static let runColors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan]

    static func fromRuns(_ runs: [TranscriptionRun], selected: UUID?, compare: UUID?) -> [PianoRollView.AnnotatedRun] {
        var result: [PianoRollView.AnnotatedRun] = []
        var idx = 0
        for run in runs {
            guard run.id == selected || run.id == compare else { continue }
            let color = runColors[idx % runColors.count]
            result.append(PianoRollView.AnnotatedRun(id: run.id, notes: run.notes, color: color, label: run.label))
            idx += 1
        }
        return result
    }
}
