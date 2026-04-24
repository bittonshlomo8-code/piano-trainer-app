import Foundation

public struct Project: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public let sourceMediaURL: URL
    public let audioFileURL: URL
    public var runs: [TranscriptionRun]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        sourceMediaURL: URL,
        audioFileURL: URL,
        runs: [TranscriptionRun] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sourceMediaURL = sourceMediaURL
        self.audioFileURL = audioFileURL
        self.runs = runs
        self.createdAt = createdAt
    }

    public var latestRun: TranscriptionRun? {
        runs.sorted { $0.createdAt > $1.createdAt }.first
    }
}
