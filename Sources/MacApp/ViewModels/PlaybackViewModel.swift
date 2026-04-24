import Foundation
import AVFoundation
import PianoTranscriptionKit

@MainActor
final class PlaybackViewModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    @Published var audioEnabled: Bool = true {
        didSet { audioEnabledChanged(from: oldValue) }
    }
    @Published var midiEnabled: Bool = true {
        didSet { midiEnabledChanged(from: oldValue) }
    }

    private var audioPlayer: AVAudioPlayer?
    private var midiEngine: AVAudioEngine?
    private var midiSampler: AVAudioUnitSampler?
    private var midiNotes: [MIDINote] = []
    private var playbackTimer: Timer?
    private var midiTasks: [Task<Void, Never>] = []

    // MARK: - Loading

    func loadAudio(url: URL) {
        stop()
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            duration = max(duration, audioPlayer?.duration ?? 0)
        } catch {
            print("Audio load error: \(error)")
        }
    }

    func loadMIDI(notes: [MIDINote]) {
        midiNotes = notes
        setupMIDIEngine()
        let midiDuration = notes.map { $0.onset + $0.duration }.max() ?? 0
        duration = max(duration, midiDuration)
    }

    private func setupMIDIEngine() {
        if midiEngine == nil {
            midiEngine = AVAudioEngine()
            midiSampler = AVAudioUnitSampler()
            if let engine = midiEngine, let sampler = midiSampler {
                engine.attach(sampler)
                engine.connect(sampler, to: engine.mainMixerNode, format: nil)
                try? engine.start()
            }
        }
    }

    // MARK: - Playback control

    func play() {
        guard !isPlaying else { return }
        guard audioEnabled || midiEnabled else { return }
        isPlaying = true

        if audioEnabled {
            audioPlayer?.currentTime = currentTime
            audioPlayer?.play()
        }
        if midiEnabled {
            playMIDINotes(from: currentTime)
        }

        startTimer()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        currentTime = audioPlayer?.currentTime ?? currentTime
        audioPlayer?.pause()
        cancelMIDITasks()
        stopTimer()
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
        let target = max(0, min(time, duration))
        currentTime = target
        audioPlayer?.currentTime = target
        if isPlaying {
            if midiEnabled {
                playMIDINotes(from: target)
            } else {
                cancelMIDITasks()
            }
        }
    }

    // MARK: - Toggle side effects

    private func audioEnabledChanged(from oldValue: Bool) {
        guard oldValue != audioEnabled else { return }
        if isPlaying {
            if audioEnabled {
                audioPlayer?.currentTime = currentTime
                audioPlayer?.play()
            } else {
                audioPlayer?.pause()
            }
        }
        if !audioEnabled && !midiEnabled && isPlaying {
            pause()
        }
    }

    private func midiEnabledChanged(from oldValue: Bool) {
        guard oldValue != midiEnabled else { return }
        if isPlaying {
            if midiEnabled {
                playMIDINotes(from: currentTime)
            } else {
                cancelMIDITasks()
            }
        }
        if !audioEnabled && !midiEnabled && isPlaying {
            pause()
        }
    }

    // MARK: - MIDI scheduling

    private func playMIDINotes(from startTime: Double) {
        guard let sampler = midiSampler else { return }

        cancelMIDITasks()

        let upcoming = midiNotes.filter { $0.onset + $0.duration >= startTime }
        for note in upcoming {
            let delay = max(0, note.onset - startTime)
            let remaining = min(note.duration, note.onset + note.duration - startTime)
            let task = Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                sampler.startNote(UInt8(note.pitch), withVelocity: UInt8(note.velocity), onChannel: 0)
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else {
                    sampler.stopNote(UInt8(note.pitch), onChannel: 0)
                    return
                }
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
                if self.audioEnabled, let player = self.audioPlayer, player.isPlaying {
                    self.currentTime = player.currentTime
                } else {
                    self.currentTime += 0.05
                }
                if self.currentTime >= self.duration { self.stop() }
            }
        }
    }

    private func stopTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}
