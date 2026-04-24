import Foundation

public final class ProjectStore {
    private let rootDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(rootDirectory: URL? = nil) {
        if let dir = rootDirectory {
            self.rootDirectory = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootDirectory = appSupport.appendingPathComponent("PianoTrainer/Projects")
        }
        try? FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public var projectsDirectory: URL { rootDirectory }

    public func audioDirectory(for project: Project) -> URL {
        let dir = rootDirectory.appendingPathComponent(project.id.uuidString).appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func midiDirectory(for project: Project) -> URL {
        let dir = rootDirectory.appendingPathComponent(project.id.uuidString).appendingPathComponent("midi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func save(_ project: Project) throws {
        let dir = rootDirectory.appendingPathComponent(project.id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("project.json")
        let data = try encoder.encode(project)
        try data.write(to: url, options: .atomic)
    }

    public func loadAll() throws -> [Project] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        return contents.compactMap { dir -> Project? in
            let projectFile = dir.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: projectFile) else { return nil }
            return try? decoder.decode(Project.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ project: Project) throws {
        let dir = rootDirectory.appendingPathComponent(project.id.uuidString)
        try FileManager.default.removeItem(at: dir)
    }
}
