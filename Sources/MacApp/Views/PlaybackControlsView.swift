import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var vm: PlaybackViewModel

    var body: some View {
        HStack(spacing: 16) {
            // Mode picker
            Picker("", selection: $vm.mode) {
                ForEach(PlaybackMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)

            // Transport
            Button(action: vm.stop) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!vm.isPlaying && vm.currentTime == 0)

            Button(action: { vm.isPlaying ? vm.pause() : vm.play() }) {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(" ", modifiers: [])

            // Scrubber
            Slider(
                value: Binding(
                    get: { vm.currentTime },
                    set: { vm.seek(to: $0) }
                ),
                in: 0...max(1, vm.duration)
            )

            // Time display
            Text(formatTime(vm.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 10)
        return String(format: "%d:%02d.%01d", m, s, ms)
    }
}
