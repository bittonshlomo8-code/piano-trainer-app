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

    private let store = ProjectStore()
    private let extractor = AudioExtractor()

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
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
}

struct AppError: Identifiable {
    let id = UUID()
    let message: String
}
