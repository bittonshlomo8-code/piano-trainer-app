import SwiftUI
import AppKit
import PianoTranscriptionKit
import UniformTypeIdentifiers

struct RunListView: View {
    @ObservedObject var vm: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Runs")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if vm.project.runs.isEmpty {
                Text("No runs yet.\nClick \"Run Transcription\" to start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                List(vm.project.runs) { run in
                    RunRowView(
                        run: run,
                        isSelected: vm.selectedRunID == run.id,
                        isCompare: vm.compareRunID == run.id
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { vm.selectedRunID = run.id }
                    .contextMenu {
                        Button("Set as Primary") { vm.selectedRunID = run.id }
                        Button("Compare with Primary") {
                            if vm.compareRunID == run.id {
                                vm.compareRunID = nil
                            } else {
                                vm.compareRunID = run.id
                            }
                        }
                        Divider()
                        Button("Export MIDI…") { exportMIDI(run: run) }
                        Divider()
                        Button("Delete", role: .destructive) { vm.deleteRun(run) }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func exportMIDI(run: TranscriptionRun) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data]
        panel.nameFieldStringValue = "\(vm.project.name)_\(run.label).mid"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? vm.exportMIDI(run: run, to: url)
        }
    }
}

private struct RunRowView: View {
    let run: TranscriptionRun
    let isSelected: Bool
    let isCompare: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isSelected {
                        Circle().fill(.blue).frame(width: 6, height: 6)
                    } else if isCompare {
                        Circle().fill(.green).frame(width: 6, height: 6)
                    } else {
                        Circle().fill(.clear).frame(width: 6, height: 6)
                    }
                    Text(run.label)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                HStack {
                    Text("\(run.noteCount) notes")
                    Text("·")
                    Text(run.modelName)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.1) : .clear)
    }
}
