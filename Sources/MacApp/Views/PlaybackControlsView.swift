import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var vm: PlaybackViewModel

    private let skipSeconds: Double = 5

    var body: some View {
        HStack(spacing: 12) {
            Picker("", selection: $vm.mode) {
                ForEach(PlaybackMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .help("Switch between original audio and MIDI synthesis")

            Button { vm.seek(to: 0) } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.borderless)
            .help("Restart")

            Button { vm.seek(to: max(0, vm.currentTime - skipSeconds)) } label: {
                Image(systemName: "gobackward.5")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Back 5s (←)")

            Button { vm.isPlaying ? vm.pause() : vm.play() } label: {
                Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(" ", modifiers: [])
            .help(vm.isPlaying ? "Pause (Space)" : "Play (Space)")

            Button { vm.seek(to: min(vm.duration, vm.currentTime + skipSeconds)) } label: {
                Image(systemName: "goforward.5")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Forward 5s (→)")

            Button { vm.stop() } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!vm.isPlaying && vm.currentTime == 0)
            .help("Stop")

            Text(formatTime(vm.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { vm.currentTime },
                    set: { vm.seek(to: $0) }
                ),
                in: 0...max(1, vm.duration)
            )

            Text(formatTime(vm.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let m = Int(total) / 60
        let s = Int(total) % 60
        let ms = Int((total - Double(Int(total))) * 10)
        return String(format: "%d:%02d.%01d", m, s, ms)
    }
}
