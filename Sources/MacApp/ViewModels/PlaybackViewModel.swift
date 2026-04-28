import Foundation
import AVFoundation
import AudioToolbox
import PianoTranscriptionKit

@MainActor
final class PlaybackViewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case audio        // Original audio only
        case midi         // Generated MIDI only
        case both         // Audio + MIDI

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .audio: return "Original Audio"
            case .midi:  return "Generated MIDI"
            case .both:  return "Audio + MIDI"
            }
        }
        var systemImage: String {
            switch self {
            case .audio: return "waveform"
            case .midi:  return "pianokeys"
            case .both:  return "speaker.wave.2"
            }
        }
        var audioActive: Bool { self == .audio || self == .both }
        var midiActive: Bool  { self == .midi  || self == .both }
    }

    // MARK: - Published state

    @Published var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    /// Single source of truth for which streams are active.
    @Published var mode: Mode = .both {
        didSet { if oldValue != mode { modeChanged(from: oldValue) } }
    }

    @Published private(set) var audioDuration: Double = 0
    @Published private(set) var midiDuration: Double = 0
    @Published private(set) var audioSampleRate: Double = 0
    @Published private(set) var loadedAudioURL: URL?

    /// Human-readable label of the current MIDI playback instrument. Surfaced
    /// in the inspector's Data Flow panel so the user can see whether the
    /// bundled SoundFont loaded or playback fell back to the AU default.
    @Published private(set) var playbackInstrumentName: String = "AU default (sine)"
    /// Resolved on first `ensureMIDIEngine`; stays nil until the bundled
    /// SoundFont URL has been resolved. Used as the source of truth so the
    /// label survives sampler reinitialization.
    @Published private(set) var playbackSoundFontURL: URL?

    // Convenience bindings used by some legacy controls.
    var audioEnabled: Bool {
        get { mode.audioActive }
        set { mode = newValue ? (mode.midiActive ? .both : .audio)
                              : (mode.midiActive ? .midi : .audio) }
    }
    var midiEnabled: Bool {
        get { mode.midiActive }
        set { mode = newValue ? (mode.audioActive ? .both : .midi)
                              : (mode.audioActive ? .audio : .midi) }
    }

    // MARK: - Private playback infrastructure

    private var audioPlayer: AVAudioPlayer?
    private var midiEngine: AVAudioEngine?
    private var midiSampler: AVAudioUnitSampler?
    private var midiNotes: [MIDINote] = []

    /// Master clock anchor when MIDI is the only source: wall-clock at last
    /// resume minus playback time at last resume.
    private var midiAnchor: Date?
    private var midiAnchorTime: Double = 0

    private var playbackTimer: Timer?
    private var midiTasks: [Task<Void, Never>] = []
    private let scheduler = MIDIScheduler()

    deinit {
        // Defensive: ensure no stray timers or sampler activity outlives the view.
        // We can't await main-actor functions from deinit; the timer/tasks will
        // be torn down by ARC + Task cancellation when the references die.
    }

    // MARK: - Loading

    /// Replaces the audio file. Stops any in-flight playback and resets the timeline.
    func loadAudio(url: URL) {
        stop()
        loadedAudioURL = url
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            audioPlayer = player
            audioDuration = player.duration
            // Pull a sample-rate hint from the file for the diagnostics panel.
            if let file = try? AVAudioFile(forReading: url) {
                audioSampleRate = file.processingFormat.sampleRate
            }
        } catch {
            audioPlayer = nil
            audioDuration = 0
            audioSampleRate = 0
            print("Audio load error: \(error)")
        }
        recomputeDuration()
    }

    /// Replaces the MIDI note set. Stops any in-flight playback and resets the timeline.
    func loadMIDI(notes: [MIDINote]) {
        stop()
        midiNotes = notes
        midiDuration = notes.map { $0.onset + $0.duration }.max() ?? 0
        ensureMIDIEngine()
        recomputeDuration()
    }

    private func recomputeDuration() {
        duration = max(audioDuration, midiDuration)
        if currentTime > duration { currentTime = 0 }
    }

    private func ensureMIDIEngine() {
        if midiEngine != nil { return }
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        loadPianoSoundFont(into: sampler)
        do {
            try engine.start()
            midiEngine = engine
            midiSampler = sampler
        } catch {
            print("MIDI engine start failed: \(error)")
        }
    }

    /// Looks up the bundled piano `.sf2` and loads General-MIDI program 0
    /// (Acoustic Grand Piano) into the sampler. Falls back to the AU default
    /// tone if the file is missing or fails to load — playback still works
    /// either way, only the timbre changes.
    private func loadPianoSoundFont(into sampler: AVAudioUnitSampler) {
        guard let url = Self.bundledPianoSoundFontURL() else {
            playbackInstrumentName = "AU default (no .sf2 bundled)"
            playbackSoundFontURL = nil
            return
        }
        playbackSoundFontURL = url
        do {
            try sampler.loadSoundBankInstrument(
                at: url,
                program: 0,                                          // GM 0 = Acoustic Grand Piano
                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB)
            )
            playbackInstrumentName = "\(url.lastPathComponent) · GM 0 (Acoustic Grand Piano)"
        } catch {
            playbackInstrumentName = "AU default (load failed: \(error.localizedDescription))"
        }
    }

    private static func bundledPianoSoundFontURL() -> URL? {
        // Look in the running app's Resources first (release / .app bundle),
        // then fall back to the SwiftPM-generated module bundle (`swift run`).
        if let url = Bundle.main.url(forResource: "PianoSoundFont", withExtension: "sf2") {
            return url
        }
        return Bundle.module.url(forResource: "PianoSoundFont", withExtension: "sf2")
    }

    // MARK: - Transport

    func play() {
        guard !isPlaying else { return }
        guard duration > 0 else { return }
        if currentTime >= duration { currentTime = 0 }

        isPlaying = true

        if mode.audioActive, let player = audioPlayer {
            player.currentTime = currentTime
            player.play()
        }
        if mode.midiActive {
            startMIDIClock(at: currentTime)
            scheduleMIDINotes(from: currentTime)
        }
        startTimer()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        // Snapshot current time *before* tearing anything down.
        let now = currentTime
        audioPlayer?.pause()
        cancelMIDITasks()
        midiAnchor = nil
        currentTime = now
        stopTimer()
    }

    func stop() {
        isPlaying = false
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        cancelMIDITasks()
        midiAnchor = nil
        currentTime = 0
        stopTimer()
    }

    func seek(to time: Double) {
        let target = max(0, min(time, duration))
        let wasPlaying = isPlaying
        // Cancel everything, then re-arm at the new position.
        audioPlayer?.pause()
        cancelMIDITasks()
        currentTime = target
        if wasPlaying {
            if mode.audioActive, let player = audioPlayer {
                player.currentTime = target
                player.play()
            }
            if mode.midiActive {
                startMIDIClock(at: target)
                scheduleMIDINotes(from: target)
            }
        } else {
            audioPlayer?.currentTime = target
        }
    }

    // MARK: - Mode switching

    private func modeChanged(from old: Mode) {
        // Always cancel anything that should no longer be sounding before
        // starting anything new — guarantees no duplicate active players.
        let wasPlaying = isPlaying
        let now = currentTime

        if old.audioActive && !mode.audioActive {
            audioPlayer?.pause()
        }
        if old.midiActive && !mode.midiActive {
            cancelMIDITasks()
            midiAnchor = nil
        }

        guard wasPlaying else { return }

        if !old.audioActive && mode.audioActive, let player = audioPlayer {
            player.currentTime = now
            player.play()
        }
        if !old.midiActive && mode.midiActive {
            startMIDIClock(at: now)
            scheduleMIDINotes(from: now)
        }
    }

    // MARK: - MIDI scheduling

    private func startMIDIClock(at time: Double) {
        midiAnchor = Date()
        midiAnchorTime = time
    }

    private func scheduleMIDINotes(from startTime: Double) {
        guard let sampler = midiSampler else { return }
        cancelMIDITasks()
        let events = scheduler.events(for: midiNotes, from: startTime)
        for event in events {
            let task = Task { @MainActor in
                let nanos = UInt64(max(0, event.delay) * 1_000_000_000)
                if nanos > 0 {
                    try? await Task.sleep(nanoseconds: nanos)
                }
                if Task.isCancelled { return }
                switch event.kind {
                case .on:
                    sampler.startNote(UInt8(clamping: event.pitch),
                                      withVelocity: UInt8(clamping: event.velocity),
                                      onChannel: 0)
                case .off:
                    sampler.stopNote(UInt8(clamping: event.pitch), onChannel: 0)
                }
            }
            midiTasks.append(task)
        }
    }

    private func cancelMIDITasks() {
        for task in midiTasks { task.cancel() }
        midiTasks.removeAll(keepingCapacity: true)
        if let sampler = midiSampler {
            for pitch in 0..<128 {
                sampler.stopNote(UInt8(pitch), onChannel: 0)
            }
        }
    }

    // MARK: - Master clock

    private func startTimer() {
        stopTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        playbackTimer = timer
    }

    private func stopTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        // Prefer the audio player as master clock when audio is active and playing.
        if mode.audioActive, let player = audioPlayer, player.isPlaying {
            currentTime = player.currentTime
        } else if let anchor = midiAnchor {
            currentTime = midiAnchorTime + Date().timeIntervalSince(anchor)
        } else {
            currentTime += 0.05
        }
        if currentTime >= duration {
            currentTime = duration
            stop()
        }
    }
}
