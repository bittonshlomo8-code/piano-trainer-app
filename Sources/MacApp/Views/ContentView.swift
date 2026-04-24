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
                    onProjectUpdated: { updated in appVM.updateProject(updated) }
                )
                .id(project.id)
            } else {
                WelcomeView()
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
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "pianokeys.inverse")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Piano Trainer")
                .font(.largeTitle.bold())
            Text("Import an audio or video file to begin.")
                .foregroundStyle(.secondary)
            Text("Use the + button in the sidebar to import media.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
