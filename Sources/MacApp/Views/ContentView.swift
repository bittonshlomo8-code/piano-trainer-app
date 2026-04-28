import SwiftUI
import AppKit
import PianoTranscriptionKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appVM: AppViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pickerSelection: PipelineKind = .basicFast

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectListView(appVM: appVM)
                .navigationTitle("Piano Trainer")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let project = appVM.selectedProject {
                ProjectDetailView(
                    project: project,
                    store: ProjectStore(),
                    appVM: appVM,
                    onProjectUpdated: { updated in appVM.updateProject(updated) }
                )
                .id(project.id)
            } else {
                WelcomeView(appVM: appVM)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { appVM.error != nil },
            set: { if !$0 { appVM.error = nil } }
        )) {
            Button("OK") { appVM.error = nil }
        } message: {
            Text(appVM.error?.message ?? "")
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: pendingPipelineBinding, onDismiss: nil) {
            if let pendingProject = pendingProject {
                PipelinePickerSheet(
                    projectName: pendingProject.name,
                    selection: $pickerSelection,
                    title: "Choose Transcription Pipeline",
                    confirmLabel: "Run Transcription",
                    onConfirm: { kind in
                        appVM.lastSelectedPipelineKind = kind
                        appVM.pendingPipelineSelectionForProjectID = nil
                        // ProjectDetailView observes this and kicks off the run
                        // via its own ProjectViewModel. Stash the requested kind
                        // on the app-level VM so the detail view can pick it up.
                        appVM.queuePipelineRunForCurrentProject(kind: kind)
                    },
                    onCancel: {
                        appVM.pendingPipelineSelectionForProjectID = nil
                    }
                )
            }
        }
        .onChange(of: appVM.pendingPipelineSelectionForProjectID) { newValue in
            if newValue != nil {
                pickerSelection = appVM.lastSelectedPipelineKind
            }
        }
    }

    private var pendingPipelineBinding: Binding<Bool> {
        Binding(
            get: { appVM.pendingPipelineSelectionForProjectID != nil },
            set: { presented in
                if !presented {
                    appVM.pendingPipelineSelectionForProjectID = nil
                }
            }
        )
    }

    private var pendingProject: Project? {
        guard let id = appVM.pendingPipelineSelectionForProjectID else { return nil }
        return appVM.projects.first { $0.id == id }
    }
}

private struct WelcomeView: View {
    @ObservedObject var appVM: AppViewModel
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "pianokeys.inverse")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Piano Trainer")
                .font(.largeTitle.bold())
            Text("Import an audio or video file to begin.")
                .foregroundStyle(.secondary)
            Button {
                isImporting = true
            } label: {
                Label("Import Media…", systemImage: "square.and.arrow.down.on.square")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            if !appVM.projects.isEmpty {
                Text("Or select a project from the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .movie, .mpeg4Movie, .wav, .mp3],
            allowsMultipleSelection: false
        ) { result in
            guard let url = try? result.get().first else { return }
            Task { await appVM.importMedia(url: url) }
        }
    }
}
