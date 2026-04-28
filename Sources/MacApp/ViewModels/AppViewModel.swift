import Foundation
import SwiftUI
import PianoTranscriptionKit

@MainActor
final class AppViewModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var selectedProjectID: UUID?
    @Published var error: AppError?
    /// Project IDs that are currently running a pipeline. Used by sidebar rows
    /// to show a live "processing" indicator without taking a dependency on
    /// per-project view models.
    @Published var runningProjectIDs: Set<UUID> = []
    /// Per-project last-error message (cleared on successful re-run).
    @Published var projectErrors: [UUID: String] = [:]

    /// Project waiting for the user to pick a pipeline (set right after
    /// import). When non-nil, the UI presents the pipeline-picker sheet.
    @Published var pendingPipelineSelectionForProjectID: UUID?

    /// When the picker confirms a choice, the requested pipeline kind lands
    /// here keyed by project ID. The detail view observes this and triggers
    /// the run, then clears the entry.
    @Published var queuedPipelineRun: [UUID: PipelineKind] = [:]

    /// Last-selected pipeline. Persisted to UserDefaults so each new import
    /// pre-selects the user's previous choice.
    @Published var lastSelectedPipelineKind: PipelineKind {
        didSet { Self.persist(lastSelectedPipelineKind) }
    }

    private let store = ProjectStore()
    private let extractor = AudioExtractor()
    private static let lastPipelineDefaultsKey = "ptk.lastSelectedPipelineKind"

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    init() {
        self.lastSelectedPipelineKind = Self.loadPersistedKind()
    }

    func loadProjects() {
        do {
            projects = try store.loadAll()
        } catch {
            self.error = AppError(message: "Failed to load projects: \(error.localizedDescription)")
        }
    }

    func importMedia(url: URL) async {
        let name = url.deletingPathExtension().lastPathComponent

        // Create a temp project placeholder to get the audio directory
        let placeholder = Project(
            name: name,
            sourceMediaURL: url,
            audioFileURL: url  // temporary
        )

        let audioDir = store.audioDirectory(for: placeholder)

        do {
            let audioURL = try await extractor.extractAudio(from: url, outputDirectory: audioDir)
            let project = Project(
                id: placeholder.id,
                name: name,
                sourceMediaURL: url,
                audioFileURL: audioURL,
                createdAt: placeholder.createdAt
            )
            try store.save(project)
            projects.insert(project, at: 0)
            selectedProjectID = project.id
            // Defer pipeline choice to the user — the picker sheet drives the
            // first transcription run.
            pendingPipelineSelectionForProjectID = project.id
        } catch {
            self.error = AppError(message: "Import failed: \(error.localizedDescription)")
        }
    }

    func setRunning(_ running: Bool, for id: UUID) {
        if running { runningProjectIDs.insert(id) } else { runningProjectIDs.remove(id) }
    }

    func setProjectError(_ message: String?, for id: UUID) {
        if let message { projectErrors[id] = message } else { projectErrors.removeValue(forKey: id) }
    }

    func delete(_ project: Project) {
        do {
            try store.delete(project)
            projects.removeAll { $0.id == project.id }
            if selectedProjectID == project.id { selectedProjectID = projects.first?.id }
        } catch {
            self.error = AppError(message: "Delete failed: \(error.localizedDescription)")
        }
    }

    func updateProject(_ project: Project) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        }
        try? store.save(project)
    }

    /// Queues a pipeline run for whichever project is currently selected. The
    /// detail view observes `queuedPipelineRun` and starts the actual run
    /// against its own `ProjectViewModel`.
    func queuePipelineRunForCurrentProject(kind: PipelineKind) {
        guard let id = selectedProjectID else { return }
        queuedPipelineRun[id] = kind
    }

    /// Pop the queued pipeline kind for a project. Called by the detail view
    /// after it kicks off the run so the entry doesn't fire twice.
    func consumeQueuedPipelineRun(for id: UUID) -> PipelineKind? {
        queuedPipelineRun.removeValue(forKey: id)
    }

    // MARK: - Pipeline preference persistence

    private static func loadPersistedKind() -> PipelineKind {
        if let raw = UserDefaults.standard.string(forKey: lastPipelineDefaultsKey),
           let kind = PipelineKind(rawValue: raw),
           PipelineKind.userVisibleCases.contains(kind) {
            return kind
        }
        return PipelineKind.defaultKind
    }

    private static func persist(_ kind: PipelineKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: lastPipelineDefaultsKey)
    }
}

struct AppError: Identifiable {
    let id = UUID()
    let message: String
}
