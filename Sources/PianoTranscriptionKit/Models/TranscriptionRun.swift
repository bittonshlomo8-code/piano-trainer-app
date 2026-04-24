import Foundation

public struct TranscriptionRun: Codable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let pipelineVersion: String
    public let modelName: String
    public var notes: [MIDINote]
    public var label: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        pipelineVersion: String,
        modelName: String,
        notes: [MIDINote],
        label: String = ""
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pipelineVersion = pipelineVersion
        self.modelName = modelName
        self.notes = notes
        self.label = label.isEmpty ? DateFormatter.localizedString(from: createdAt, dateStyle: .short, timeStyle: .medium) : label
    }

    public var duration: Double {
        notes.map { $0.onset + $0.duration }.max() ?? 0
    }

    public var noteCount: Int { notes.count }

    public var pitchRange: ClosedRange<Int>? {
        guard !notes.isEmpty else { return nil }
        let pitches = notes.map(\.pitch)
        return pitches.min()!...pitches.max()!
    }
}
