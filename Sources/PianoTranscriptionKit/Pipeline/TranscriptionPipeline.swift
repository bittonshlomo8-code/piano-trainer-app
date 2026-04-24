import Foundation

public protocol TranscriptionPipeline: Sendable {
    var version: String { get }
    func run(audioURL: URL) async throws -> TranscriptionRun
}
