import SwiftUI
import AppKit
import PianoTranscriptionKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appVM: AppViewModel

    var body: some View {
        NavigationSplitView {
            ProjectListView(appVM: appVM)
                .navigationTitle("Piano Trainer")
                .frame(minWidth: 200, idealWidth: 240)
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
