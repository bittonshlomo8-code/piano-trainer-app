import SwiftUI
import AVFoundation

struct WaveformView: View {
    let audioURL: URL
    let playheadTime: Double
    let duration: Double
    var onSeek: ((Double) -> Void)?

    @State private var samples: [Float] = []
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(Color(.darkGray).opacity(0.3))
                    .cornerRadius(4)

                if isLoading {
                    ProgressView("Loading waveform…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Waveform
                    Canvas { ctx, size in
                        let w = size.width
                        let h = size.height
                        let mid = h / 2
                        let count = samples.count
                        guard count > 0 else { return }

                        var path = Path()
                        let step = w / Double(count)

                        for (i, amp) in samples.enumerated() {
                            let x = Double(i) * step
                            let barH = Double(amp) * mid * 0.9
                            path.addRect(CGRect(x: x, y: mid - barH, width: max(1, step - 0.5), height: barH * 2))
                        }

                        ctx.fill(path, with: .color(.accentColor.opacity(0.75)))
                    }

                    // Playhead
                    if duration > 0 {
                        let x = (playheadTime / duration) * geo.size.width
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2)
                            .offset(x: x - 1)
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let t = (value.location.x / geo.size.width) * duration
                        onSeek?(max(0, min(t, duration)))
                    }
            )
        }
        .frame(height: 80)
        .task(id: audioURL) { await loadSamples() }
    }

    private func loadSamples() async {
        isLoading = true
        let url = audioURL
        let result = await Task.detached(priority: .userInitiated) {
            downsample(url: url, targetCount: 512)
        }.value
        samples = result
        isLoading = false
    }
}

private func downsample(url: URL, targetCount: Int) -> [Float] {
    guard let file = try? AVAudioFile(forReading: url) else { return [] }
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { return [] }
    guard (try? file.read(into: buffer)) != nil else { return [] }
    guard let channelData = buffer.floatChannelData?[0] else { return [] }

    let total = Int(buffer.frameLength)
    let chunkSize = max(1, total / targetCount)
    var result: [Float] = []

    for i in 0..<targetCount {
        let start = i * chunkSize
        let end = min(start + chunkSize, total)
        guard start < end else { break }
        var peak: Float = 0
        for j in start..<end { peak = max(peak, abs(channelData[j])) }
        result.append(peak)
    }

    return result
}
