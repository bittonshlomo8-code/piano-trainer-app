import Foundation
import SwiftUI
import AppKit
import PianoTranscriptionKit

@MainActor
final class ProjectViewModel: ObservableObject {
    @Published var project: Project
    @Published var selectedRunID: UUID?
    @Published var isRunning = false
    @Published var runError: String?
    @Published var compareRunID: UUID?
    @Published var modelSelection: ModelSelection = .basic

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

    func runTranscription() async {
        guard !isRunning else { return }
        isRunning = true
        runError = nil
        runStartedAt = Date()
        runDurationSeconds = nil

        let selection = modelSelection
        let pipeline = DefaultPipeline(runner: selection.makeRunner())
        let start = Date()

        do {
            let run = try await pipeline.run(audioURL: project.audioFileURL)
            runDurationSeconds = Date().timeIntervalSince(start)
            project.runs.append(run)
            selectedRunID = run.id
            try store.save(project)
            onProjectUpdated(project)
        } catch {
            runDurationSeconds = Date().timeIntervalSince(start)
            runError = error.localizedDescription
        }

        isRunning = false
    }

    func exportMIDI(run: TranscriptionRun, to url: URL) throws {
        try exporter.export(run: run, to: url)
        lastMIDIExportURL = url
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
        let runner = modelSelection.makeRunner()
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

// MARK: - Model selection

extension ProjectViewModel {
    enum ModelSelection: String, CaseIterable, Identifiable {
        case basic = "Real"
        case mock  = "Mock"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .basic: return "waveform"
            case .mock:  return "die.face.3"
            }
        }

        func makeRunner() -> any ModelRunner {
            switch self {
            case .basic: return BasicPianoModelRunner()
            case .mock:  return MockModelRunner()
            }
        }
    }
}
