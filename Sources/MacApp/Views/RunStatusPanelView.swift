import SwiftUI
import PianoTranscriptionKit

struct RunStatusPanelView: View {
    @ObservedObject var vm: ProjectViewModel
    @State private var isExpanded = true

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                filesSection
                Divider()
                runSection
                Divider()
                diagnosticsSection
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
        } label: {
            labelView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Header label

    private var labelView: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Status & Diagnostics")
                .font(.subheadline.weight(.medium))
            Spacer()
            if vm.isRunning {
                ProgressView().scaleEffect(0.55)
                Text("Running…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if vm.runError != nil {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .labelStyle(.titleAndIcon)
            } else if let duration = vm.runDurationSeconds {
                Text("\(String(format: "%.2f", duration))s · \(vm.selectedRun?.noteCount ?? 0) notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Files")
            fileRow(label: "Source media",
                    url: vm.project.sourceMediaURL,
                    placeholder: "not imported")
            fileRow(label: "Extracted WAV",
                    url: vm.project.audioFileURL,
                    placeholder: "not extracted")
            fileRow(label: "MIDI export",
                    url: vm.lastMIDIExportURL,
                    placeholder: "not exported yet")
            HStack(spacing: 6) {
                Text("Project folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(vm.projectFolder.lastPathComponent)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    vm.revealInFinder(vm.projectFolder)
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reveal project folder in Finder")
            }
        }
    }

    // MARK: - Run

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Last Run")
            infoRow(label: "Pipeline", value: pipelineLabel)
            infoRow(label: "Model", value: modelLabel)
            if let startedAt = vm.runStartedAt {
                infoRow(label: "Started", value: Self.timeFormatter.string(from: startedAt))
            } else {
                infoRow(label: "Started", value: "—")
            }
            if let duration = vm.runDurationSeconds {
                infoRow(label: "Duration", value: String(format: "%.2f s", duration))
            } else if vm.isRunning {
                infoRow(label: "Duration", value: "in progress…")
            } else {
                infoRow(label: "Duration", value: "—")
            }
            if let run = vm.selectedRun {
                infoRow(label: "Notes detected", value: "\(run.noteCount)")
                if run.usedSourceSeparation {
                    infoRow(label: "Source separation", value: "yes")
                }
            } else {
                infoRow(label: "Notes detected", value: "—")
            }
            if let error = vm.runError {
                HStack(alignment: .top, spacing: 6) {
                    Text("Error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                }
            }
        }
    }

    /// Pipeline label for the most recently produced run when one exists,
    /// otherwise the currently-selected pipeline kind.
    private var pipelineLabel: String {
        if let run = vm.selectedRun, !run.pipelineName.isEmpty {
            return run.pipelineName
        }
        return vm.pipelineKind.displayName
    }

    private var modelLabel: String {
        if let run = vm.selectedRun {
            if let v = run.modelVersion, !v.isEmpty {
                return "\(run.modelName) (\(v))"
            }
            return run.modelName
        }
        return "—"
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("Diagnostics")
                Spacer()
                Button {
                    Task { await vm.runDiagnostics() }
                } label: {
                    Label("Run Diagnostics", systemImage: "stethoscope")
                        .font(.caption)
                }
                .disabled(vm.isDiagnosticsRunning)
            }

            if vm.isDiagnosticsRunning {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.55)
                    Text("Running diagnostics…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let report = vm.diagnosticsReport {
                ForEach(report.checks) { check in
                    HStack(spacing: 6) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.passed ? .green : .red)
                            .font(.caption)
                        Text(check.name)
                            .font(.caption)
                            .frame(width: 200, alignment: .leading)
                        Text(check.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
                HStack {
                    Text(report.summary)
                        .font(.caption2)
                        .foregroundStyle(report.allPassed ? .green : .red)
                    Text("· \(String(format: "%.2f", report.durationSeconds))s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 2)
            } else {
                Text("Run diagnostics to verify project JSON, WAV access, MIDI generation, and the selected model runner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Building blocks

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    private func fileRow(label: String, url: URL?, placeholder: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            if let url {
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    vm.revealInFinder(url)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reveal \(label) in Finder")
            } else {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
