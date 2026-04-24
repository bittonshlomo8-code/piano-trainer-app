import SwiftUI
import PianoTranscriptionKit

struct ProjectDetailView: View {
    let projectInput: Project
    let store: ProjectStore
    let onProjectUpdated: (Project) -> Void

    @StateObject private var vm: ProjectViewModel
    @StateObject private var playback = PlaybackViewModel()

    init(project: Project, store: ProjectStore, onProjectUpdated: @escaping (Project) -> Void) {
        self.projectInput = project
        self.store = store
        self.onProjectUpdated = onProjectUpdated
        _vm = StateObject(wrappedValue: ProjectViewModel(project: project, store: store, onProjectUpdated: onProjectUpdated))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar

            Divider()

            // Waveform
            WaveformView(
                audioURL: vm.project.audioFileURL,
                playheadTime: playback.currentTime,
                duration: playback.duration
            ) { t in playback.seek(to: t) }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Piano roll
            Group {
                if vm.project.runs.isEmpty {
                    emptyState
                } else {
                    let annotated = PianoRollView.AnnotatedRun.fromRuns(
                        vm.project.runs,
                        selected: vm.selectedRunID,
                        compare: vm.compareRunID
                    )
                    PianoRollView(
                        runs: annotated,
                        duration: max(playback.duration, vm.selectedRun?.duration ?? 0),
                        playheadTime: playback.currentTime
                    ) { t in playback.seek(to: t) }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Playback controls
            PlaybackControlsView(vm: playback)
        }
        .onAppear {
            playback.loadAudio(url: vm.project.audioFileURL)
            if let run = vm.selectedRun { playback.loadMIDI(notes: run.notes) }
        }
        .onChange(of: vm.selectedRunID) { _ in
            if let run = vm.selectedRun { playback.loadMIDI(notes: run.notes) }
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.project.name)
                    .font(.title3.bold())
                HStack(spacing: 6) {
                    Text(vm.project.audioFileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let run = vm.selectedRun {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Circle().fill(.blue).frame(width: 6, height: 6)
                        Text(run.label)
                            .font(.caption)
                            .foregroundStyle(.blue)
                        if let compareRun = vm.compareRun {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text(compareRun.label)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            Spacer()
            if vm.isRunning {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.trailing, 4)
                Text("Running \(vm.modelSelection.rawValue)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Model picker
                Picker("Model", selection: $vm.modelSelection) {
                    ForEach(ProjectViewModel.ModelSelection.allCases) { sel in
                        Label(sel.rawValue, systemImage: sel.systemImage).tag(sel)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 90)
                .help("Select transcription model")

                Button {
                    Task { await vm.runTranscription() }
                } label: {
                    Label("Run Transcription", systemImage: "waveform.badge.magnifyingglass")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No transcription runs yet")
                .font(.title3)
            Text("Press ⌘R or click \"Run Transcription\" to analyze this audio.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
