import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PianoTranscriptionKit

struct ProjectListView: View {
    @ObservedObject var appVM: AppViewModel
    @State private var isImporting = false

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                isImporting = true
            } label: {
                Label("Import Media…", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut("o", modifiers: .command)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if appVM.projects.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "square.and.arrow.down")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No songs yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Import audio or video to start.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
            } else {
                projectsList
            }

            buildStamp
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

    private var buildStamp: some View {
        HStack(spacing: 4) {
            Text("v\(appVersion)")
                .font(.caption2.monospacedDigit())
            Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("build \(appBuild)")
                .font(.caption2.monospacedDigit())
                .textSelection(.enabled)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.bar)
        .help("App version and build. Share the build number so we know we're looking at the same binary.")
    }

    private var projectsList: some View {
        List(selection: $appVM.selectedProjectID) {
            Section(header: sectionHeader) {
                ForEach(appVM.projects) { project in
                    ProjectRowView(
                        project: project,
                        isRunning: appVM.runningProjectIDs.contains(project.id),
                        lastError: appVM.projectErrors[project.id]
                    )
                    .tag(project.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { appVM.delete(project) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var sectionHeader: some View {
        HStack {
            Text("Songs · \(appVM.projects.count)")
            Spacer()
            if !appVM.runningProjectIDs.isEmpty {
                Label("\(appVM.runningProjectIDs.count) running", systemImage: "gearshape.2.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.blue)
            }
        }
        .font(.caption)
    }
}

private struct ProjectRowView: View {
    let project: Project
    let isRunning: Bool
    let lastError: String?

    private enum Status {
        case processing, processed, pending, failed

        var color: Color {
            switch self {
            case .processing: return .blue
            case .processed:  return .green
            case .pending:    return .secondary
            case .failed:     return .red
            }
        }

        var systemImage: String {
            switch self {
            case .processing: return "gearshape.2.fill"
            case .processed:  return "checkmark.circle.fill"
            case .pending:    return "circle.dotted"
            case .failed:     return "exclamationmark.triangle.fill"
            }
        }

        var label: String {
            switch self {
            case .processing: return "Processing"
            case .processed:  return "Processed"
            case .pending:    return "Not processed"
            case .failed:     return "Failed"
            }
        }
    }

    private var status: Status {
        if isRunning { return .processing }
        if lastError != nil { return .failed }
        return project.runs.isEmpty ? .pending : .processed
    }

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(status.label)
                        .foregroundStyle(status.color)
                    Text("·")
                    Text("\(project.runs.count) run\(project.runs.count == 1 ? "" : "s")")
                    Spacer()
                    Text(project.createdAt, style: .date)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .help(lastError ?? status.label)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isRunning {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.color)
                .font(.caption)
        }
    }
}
