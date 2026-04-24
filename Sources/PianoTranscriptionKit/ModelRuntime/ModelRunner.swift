import Foundation

public protocol ModelRunner: Sendable {
    var name: String { get }
    func transcribe(audioURL: URL, progress: PipelineProgressHandler?) async throws -> [MIDINote]
}

public extension ModelRunner {
    func transcribe(audioURL: URL) async throws -> [MIDINote] {
        try await transcribe(audioURL: audioURL, progress: nil)
    }
}
