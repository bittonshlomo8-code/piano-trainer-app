import Foundation

public protocol ModelRunner: Sendable {
    var name: String { get }
    func transcribe(audioURL: URL) async throws -> [MIDINote]
}
