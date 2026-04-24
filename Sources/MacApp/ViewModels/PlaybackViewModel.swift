import Foundation
import AVFoundation
import PianoTranscriptionKit

enum PlaybackMode: String, CaseIterable {
    case audio = "Audio"
    case midi  = "MIDI"
}

@MainActor
final class PlaybackViewModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var mode: PlaybackMode = .audio

    private var audioPlayer: AVAudioPlayer?
    private var midiEngine: AVAudioEngine?
    private var midiSampler: AVAudioUnitSampler?
    private var midiNotes: [MIDINote] = []
    private var playbackTimer: Timer?
    private var midiTasks: [Task<Void, Never>] = []

    // MARK: - Audio

    func loadAudio(url: URL) {
        stop()
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            duration = audioPlayer?.duration ?? 0
        } catch {
            print("Audio load error: \(error)")
        }
    }

    func loadMIDI(notes: [MIDINote]) {
        midiNotes = notes
        setupMIDIEngine()
    }

    private func setupMIDIEngine() {
        midiEngine = AVAudioEngine()
        guard let engine = midiEngine else { return }

        midiSampler = AVAudioUnitSampler()
        guard let sampler = midiSampler else { return }

        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)

        try? engine.start()
    }

    // MARK: - Playback control

    func play() {
        guard !isPlaying else { return }
        isPlaying = true

        switch mode {
        case .audio:
            audioPlayer?.currentTime = currentTime
            audioPlayer?.play()
        case .midi:
            playMIDINotes(from: currentTime)
        }

        startTimer()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        audioPlayer?.pause()
        cancelMIDITasks()
        stopTimer()
        currentTime = audioPlayer?.currentTime ?? currentTime
    }

    func stop() {
        isPlaying = false
        currentTime = 0
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        cancelMIDITasks()
        stopTimer()
    }

    func seek(to time: Double) {
        currentTime = max(0, min(time, duration))
        if isPlaying {
            audioPlayer?.currentTime = currentTime
        }
    }

    // MARK: - MIDI scheduling

    private func playMIDINotes(from startTime: Double) {
        guard let sampler = midiSampler else { return }

        cancelMIDITasks()

        let upcoming = midiNotes.filter { $0.onset >= startTime }
        for note in upcoming {
            let delay = note.onset - startTime
            let task = Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                sampler.startNote(UInt8(note.pitch), withVelocity: UInt8(note.velocity), onChannel: 0)
                try? await Task.sleep(nanoseconds: UInt64(note.duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                sampler.stopNote(UInt8(note.pitch), onChannel: 0)
            }
            midiTasks.append(task)
        }
    }

    private func cancelMIDITasks() {
        midiTasks.forEach { $0.cancel() }
        midiTasks.removeAll()
        if let sampler = midiSampler {
            for pitch in 0..<128 { sampler.stopNote(UInt8(pitch), onChannel: 0) }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                if self.mode == .audio, let player = self.audioPlayer {
                    self.currentTime = player.currentTime
                    if !player.isPlaying { self.stop() }
                } else {
                    self.currentTime += 0.05
                    if self.currentTime >= self.duration { self.stop() }
                }
            }
        }
    }

    private func stopTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}
