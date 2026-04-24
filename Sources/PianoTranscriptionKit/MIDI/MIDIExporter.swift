import Foundation

public final class MIDIExporter {
    private let generator = MIDIGenerator()

    public init() {}

    public func export(run: TranscriptionRun, to url: URL) throws {
        let data = generator.generateMIDI(from: run.notes)
        try data.write(to: url, options: .atomic)
    }

    public func midiData(for run: TranscriptionRun) -> Data {
        generator.generateMIDI(from: run.notes)
    }
}
