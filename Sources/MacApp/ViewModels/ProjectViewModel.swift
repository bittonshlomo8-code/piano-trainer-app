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

    private let pipeline: any TranscriptionPipeline
    private let exporter = MIDIExporter()
    private let store: ProjectStore
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
        self.pipeline = DefaultPipeline(runner: MockModelRunner())
        self.onProjectUpdated = onProjectUpdated
        self.selectedRunID = project.latestRun?.id
    }

    func runTranscription() async {
        guard !isRunning else { return }
        isRunning = true
        runError = nil

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
