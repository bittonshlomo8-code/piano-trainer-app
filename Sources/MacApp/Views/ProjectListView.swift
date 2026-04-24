import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PianoTranscriptionKit

struct ProjectListView: View {
    @ObservedObject var appVM: AppViewModel
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $appVM.selectedProjectID) {
                ForEach(appVM.projects) { project in
                    ProjectRowView(project: project)
                        .tag(project.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { appVM.delete(project) }
                        }
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button {
                isImporting = true
            } label: {
                Label("Import Media…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
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

private struct ProjectRowView: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
            HStack {
                Text("\(project.runs.count) run\(project.runs.count == 1 ? "" : "s")")
                Spacer()
                Text(project.createdAt, style: .date)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
