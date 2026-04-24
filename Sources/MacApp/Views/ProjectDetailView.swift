import SwiftUI
import PianoTranscriptionKit

struct ProjectDetailView: View {
    let projectInput: Project
    let store: ProjectStore
    let onProjectUpdated: (Project) -> Void
    @ObservedObject var appVM: AppViewModel

    @StateObject private var vm: ProjectViewModel
    @StateObject private var playback = PlaybackViewModel()

    init(project: Project,
         store: ProjectStore,
         appVM: AppViewModel,
         onProjectUpdated: @escaping (Project) -> Void) {
        self.projectInput = project
        self.store = store
        self.appVM = appVM
        self.onProjectUpdated = onProjectUpdated
        _vm = StateObject(wrappedValue: ProjectViewModel(project: project, store: store, onProjectUpdated: onProjectUpdated))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if vm.isRunning {
                progressBanner
            }

            if !vm.project.runs.isEmpty {
                runsStrip
            }

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
            vm.onRunningChanged = { [weak appVM] id, running in
                appVM?.setRunning(running, for: id)
            }
            vm.onRunError = { [weak appVM] id, message in
                appVM?.setProjectError(message, for: id)
            }
        }
        .onChange(of: vm.selectedRunID) { _ in
            if let run = vm.selectedRun { playback.loadMIDI(notes: run.notes) }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.project.name)
                    .font(.title3.bold())
                HStack(spacing: 6) {
                    Text(vm.project.audioFileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let run = vm.selectedRun {
                        Text("·").foregroundStyle(.secondary)
                        Circle().fill(.blue).frame(width: 6, height: 6)
                        Text(run.label)
                            .font(.caption)
                            .foregroundStyle(.blue)
                        if let compareRun = vm.compareRun {
                            Text("·").foregroundStyle(.secondary)
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text(compareRun.label)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            Spacer()

            pipelinePicker

            Button {
                Task { await vm.runTranscription() }
            } label: {
                Label(vm.project.runs.isEmpty ? "Run Transcription" : "Run Again",
                      systemImage: "waveform.badge.magnifyingglass")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(vm.isRunning || !vm.pipelineKind.isAvailable)
            .help(vm.pipelineKind.isAvailable ? "Run the selected pipeline (⌘R)" : vm.pipelineKind.summary)

            Button {
                if let run = vm.selectedRun { _ = vm.promptExportMIDI(for: run) }
            } label: {
                Label("Download MIDI", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(vm.selectedRun == nil || vm.isRunning)
            .help(vm.selectedRun == nil
                  ? "Finish a transcription run to enable MIDI download"
                  : "Save the selected run's MIDI file (⌘E)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var pipelinePicker: some View {
        Picker("Pipeline", selection: $vm.pipelineKind) {
            ForEach(PipelineKind.allCases) { kind in
                HStack {
                    Image(systemName: kind.systemImage)
                    Text(kind.displayName + (kind.isAvailable ? "" : " (coming soon)"))
                }
                .tag(kind)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 200)
        .help(vm.pipelineKind.summary)
        .disabled(vm.isRunning)
    }

    // MARK: - Runs strip

    private var runsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Runs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                ForEach(vm.project.runs.reversed()) { run in
                    runPill(run: run)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func runPill(run: TranscriptionRun) -> some View {
        let isSelected = vm.selectedRunID == run.id
        let isCompare = vm.compareRunID == run.id
        HStack(spacing: 6) {
            Circle()
                .fill(isSelected ? Color.blue : (isCompare ? Color.green : Color.clear))
                .frame(width: 6, height: 6)
            Text(run.label)
                .font(.caption)
            Text("· \(run.noteCount)n")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.blue.opacity(0.15) :
                      isCompare ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.blue.opacity(0.6) :
                        isCompare ? Color.green.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { vm.selectedRunID = run.id }
        .contextMenu {
            Button("Set as Primary") { vm.selectedRunID = run.id }
            Button(vm.compareRunID == run.id ? "Stop Comparing" : "Compare with Primary") {
                vm.compareRunID = (vm.compareRunID == run.id) ? nil : run.id
            }
            Divider()
            Button("Download MIDI…") { _ = vm.promptExportMIDI(for: run) }
            Divider()
            Button("Delete Run", role: .destructive) { vm.deleteRun(run) }
        }
        .help("\(run.modelName) · \(run.noteCount) notes · right-click for actions")
    }

    // MARK: - Progress

    private var progressBanner: some View {
        let frac = vm.progress?.fraction ?? 0
        let stage = vm.progress?.stage.rawValue ?? "Starting"
        let detail = vm.progress?.detail
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text(stage)
                    .font(.caption.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text("· \(detail)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("\(Int(frac * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: frac)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    // MARK: - Piano roll / state switching

    @ViewBuilder
    private var pianoRollArea: some View {
        if vm.isRunning && vm.project.runs.isEmpty {
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
            Text("Running \(vm.pipelineKind.displayName)…")
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
            Text("The \(run.modelName) pipeline finished but didn't detect any notes. Try a different pipeline or check the audio in the status panel below.")
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
