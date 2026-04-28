import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PianoTranscriptionKit

@MainActor
final class ProjectViewModel: ObservableObject {
    @Published var project: Project
    @Published var selectedRunID: UUID?
    @Published var isRunning = false
    @Published var runError: String?
    @Published var compareRunID: UUID?
    @Published var pipelineKind: PipelineKind = .defaultKind

    // Live progress (published during an active pipeline run)
    @Published var progress: PipelineProgress?

    // Run status tracking (populated by the most recent pipeline run)
    @Published var runStartedAt: Date?
    @Published var runDurationSeconds: Double?
    @Published var lastMIDIExportURL: URL?

    // Diagnostics
    @Published var diagnosticsReport: DiagnosticsReport?
    @Published var isDiagnosticsRunning = false

    private let exporter = MIDIExporter()
    let store: ProjectStore
    private let onProjectUpdated: (Project) -> Void
    var onRunningChanged: ((UUID, Bool) -> Void)?
    var onRunError: ((UUID, String?) -> Void)?

    var selectedRun: TranscriptionRun? {
        guard let id = selectedRunID else { return nil }
        return project.runs.first { $0.id == id }
    }

    var compareRun: TranscriptionRun? {
        guard let id = compareRunID else { return nil }
        return project.runs.first { $0.id == id }
    }

    var projectFolder: URL {
        store.projectsDirectory.appendingPathComponent(project.id.uuidString)
    }

    init(project: Project, store: ProjectStore, onProjectUpdated: @escaping (Project) -> Void) {
        self.project = project
        self.store = store
        self.onProjectUpdated = onProjectUpdated
        self.selectedRunID = project.latestRun?.id
    }

    func runTranscription(using kind: PipelineKind? = nil) async {
        guard !isRunning else { return }
        let chosen = kind ?? pipelineKind
        if let kind { pipelineKind = kind }
        guard let pipeline = PipelineRegistry.shared.makePipeline(chosen) else {
            let reason = PipelineRegistry.shared.unavailableReason(chosen)
                ?? "\(chosen.displayName) is not yet available. Pick another pipeline."
            runError = reason
            onRunError?(project.id, reason)
            return
        }

        isRunning = true
        onRunningChanged?(project.id, true)
        runError = nil
        onRunError?(project.id, nil)
        progress = PipelineProgress(stage: .loading, fraction: 0.0)
        runStartedAt = Date()
        runDurationSeconds = nil

        let start = Date()
        let audioURL = project.audioFileURL

        // Forward progress from the background pipeline to this view model's @Published
        // property by bridging through an AsyncStream — avoids Sendable capture issues.
        let (stream, continuation) = AsyncStream.makeStream(of: PipelineProgress.self)
        let progressHandler: PipelineProgressHandler = { continuation.yield($0) }
        let forwarding = Task { @MainActor [weak self] in
            for await update in stream { self?.progress = update }
        }

        do {
            let run = try await pipeline.run(audioURL: audioURL, progress: progressHandler)
            runDurationSeconds = Date().timeIntervalSince(start)
            project.runs.append(run)
            selectedRunID = run.id
            try store.save(project)
            onProjectUpdated(project)
        } catch {
            runDurationSeconds = Date().timeIntervalSince(start)
            runError = error.localizedDescription
            onRunError?(project.id, error.localizedDescription)
        }

        continuation.finish()
        await forwarding.value

        progress = nil
        isRunning = false
        onRunningChanged?(project.id, false)
    }

    func exportMIDI(run: TranscriptionRun, to url: URL) throws {
        try exporter.export(run: run, to: url)
        lastMIDIExportURL = url
    }

    /// Prompts the user for a save location and writes the selected run's MIDI file.
    /// Returns the URL that was written, or nil if the user cancelled.
    @discardableResult
    func promptExportMIDI(for run: TranscriptionRun) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data]
        panel.nameFieldStringValue = "\(project.name)_\(run.label).mid"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try exportMIDI(run: run, to: url)
            return url
        } catch {
            runError = "MIDI export failed: \(error.localizedDescription)"
            return nil
        }
    }

    func deleteRun(_ run: TranscriptionRun) {
        project.runs.removeAll { $0.id == run.id }
        if selectedRunID == run.id { selectedRunID = project.latestRun?.id }
        if compareRunID == run.id { compareRunID = nil }
        try? store.save(project)
        onProjectUpdated(project)
    }

    // MARK: - Diagnostics

    func runDiagnostics() async {
        guard !isDiagnosticsRunning else { return }
        isDiagnosticsRunning = true
        let snapshot = project
        let runner = PipelineRegistry.shared.makeRunner(pipelineKind) ?? BasicPianoModelRunner()
        let report = await PipelineDiagnostics.run(project: snapshot, store: store, runner: runner)
        diagnosticsReport = report
        isDiagnosticsRunning = false
    }

    // MARK: - Finder

    func revealInFinder(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Fallback: open the containing directory if it exists
            let parent = url.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }
}
