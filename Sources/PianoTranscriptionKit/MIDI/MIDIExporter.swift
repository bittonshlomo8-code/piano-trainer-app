import Foundation

public final class MIDIExporter {
    private let generator = MIDIGenerator()

    public init() {}

    public func export(run: TranscriptionRun, to url: URL) throws {
        let data = generator.generateMIDI(from: run.notes)
        try data.write(to: url, options: .atomic)
        TranscriptionRunLog.export.info(
            "export run=\(run.id.uuidString, privacy: .public) pipeline=\(run.pipelineName, privacy: .public) cleanedNotes=\(run.notes.count) rawNotes=\(run.rawNotes.count) bytes=\(data.count) path=\(url.path, privacy: .public)"
        )
    }

    public func midiData(for run: TranscriptionRun) -> Data {
        generator.generateMIDI(from: run.notes)
    }
}
