# Piano Trainer

A native macOS transcription workbench for piano audio.

**Import → Run → Visualize → Compare → Export**

## Architecture

```
Sources/
├── PianoTranscriptionKit/   Swift Package library
│   ├── Models/              MIDINote, TranscriptionRun, Project
│   ├── AudioProcessing/     AudioExtractor (AVFoundation)
│   ├── Pipeline/            TranscriptionPipeline protocol + DefaultPipeline
│   ├── ModelRuntime/        ModelRunner protocol + MockModelRunner
│   ├── MIDI/                MIDIGenerator + MIDIExporter
│   └── Storage/             ProjectStore (JSON / file-based)
└── MacApp/                  SwiftUI macOS app
    ├── Views/
    └── ViewModels/
```

## Requirements

- macOS 13+
- Xcode 15+ (or `swift build`)

## Running

```bash
swift run MacApp
```

Or open `Package.swift` in Xcode and run the `MacApp` scheme.

## v1 Status

- [x] Project system — import audio/video, persist projects
- [x] Audio extraction — AVFoundation-based, mono 44.1kHz WAV
- [x] Waveform view — PCM downsampled rendering
- [x] Piano roll — scrollable, multi-run overlay
- [x] Mock transcription — deterministic plausible output
- [x] Playback — audio + basic MIDI via AVAudioEngine
- [x] MIDI export — SMF Type 0
- [x] Run history — multiple runs per project, compare two at once

## Plugging in a real model

Implement `ModelRunner` and pass it to `DefaultPipeline`:

```swift
public protocol ModelRunner: Sendable {
    var name: String { get }
    func transcribe(audioURL: URL) async throws -> [MIDINote]
}
```
