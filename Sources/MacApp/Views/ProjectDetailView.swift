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
            headerBar

            Divider()

            WaveformView(
                audioURL: vm.project.audioFileURL,
                playheadTime: playback.currentTime,
                duration: playback.duration
            ) { t in playback.seek(to: t) }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            pianoRollArea
                .frame(maxHeight: .infinity)

            Divider()

            RunStatusPanelView(vm: vm)

            Divider()

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

    // MARK: - Header

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

    // MARK: - Piano roll / state switching

    @ViewBuilder
    private var pianoRollArea: some View {
        if vm.isRunning {
            runningState
        } else if vm.project.runs.isEmpty, let error = vm.runError {
            errorState(message: error)
        } else if vm.project.runs.isEmpty {
            emptyState
        } else if let run = vm.selectedRun, run.noteCount == 0 {
            noNotesState(run: run)
        } else {
            pianoRollContent
        }
    }

    private var pianoRollContent: some View {
        let annotated = PianoRollView.AnnotatedRun.fromRuns(
            vm.project.runs,
            selected: vm.selectedRunID,
            compare: vm.compareRunID
        )
        return PianoRollView(
            runs: annotated,
            duration: max(playback.duration, vm.selectedRun?.duration ?? 0),
            playheadTime: playback.currentTime
        ) { t in playback.seek(to: t) }
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

    private var runningState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.1)
            Text("Running \(vm.modelSelection.rawValue) pipeline…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(vm.project.audioFileURL.lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            Text("Transcription failed")
                .font(.title3)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 32)
            HStack(spacing: 8) {
                Button {
                    Task { await vm.runTranscription() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await vm.runDiagnostics() }
                } label: {
                    Label("Run Diagnostics", systemImage: "stethoscope")
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noNotesState(run: TranscriptionRun) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No notes detected")
                .font(.title3)
            Text("The \(run.modelName) pipeline finished but didn't detect any notes. Try a different model or check the audio in the status panel below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 8) {
                Button {
                    Task { await vm.runTranscription() }
                } label: {
                    Label("Run Again", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await vm.runDiagnostics() }
                } label: {
                    Label("Run Diagnostics", systemImage: "stethoscope")
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
