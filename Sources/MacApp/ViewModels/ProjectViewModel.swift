import Foundation
import SwiftUI
import PianoTranscriptionKit

@MainActor
final class ProjectViewModel: ObservableObject {
    @Published var project: Project
    @Published var selectedRunID: UUID?
    @Published var isRunning = false
    @Published var runError: String?
    @Published var compareRunID: UUID?
    @Published var modelSelection: ModelSelection = .basic

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

        let pipeline = DefaultPipeline(runner: modelSelection.makeRunner())

        do {
            let run = try await pipeline.run(audioURL: project.audioFileURL)
            project.runs.append(run)
            selectedRunID = run.id
            try store.save(project)
            onProjectUpdated(project)
        } catch {
            runError = error.localizedDescription
        }

        isRunning = false
    }

    func exportMIDI(run: TranscriptionRun, to url: URL) throws {
        try exporter.export(run: run, to: url)
    }

    func deleteRun(_ run: TranscriptionRun) {
        project.runs.removeAll { $0.id == run.id }
        if selectedRunID == run.id { selectedRunID = project.latestRun?.id }
        if compareRunID == run.id { compareRunID = nil }
        try? store.save(project)
        onProjectUpdated(project)
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
