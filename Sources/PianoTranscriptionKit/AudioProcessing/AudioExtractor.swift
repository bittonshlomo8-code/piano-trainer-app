import Foundation
import AVFoundation

public enum AudioExtractionError: Error, LocalizedError {
    case noAudioTracks
    case exportFailed(String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTracks:         return "No audio tracks found in media file"
        case .exportFailed(let m):   return "Export failed: \(m)"
        case .conversionFailed(let m): return "Conversion failed: \(m)"
        }
    }
}

public final class AudioExtractor {
    public init() {}

    /// Extract audio from any AVFoundation-readable media to a 44.1kHz mono WAV.
    public func extractAudio(from sourceURL: URL, outputDirectory: URL) async throws -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = outputDirectory.appendingPathComponent("\(baseName)_audio.wav")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        let ext = sourceURL.pathExtension.lowercased()
        if ext == "wav" {
            return try await convertWAV(from: sourceURL, to: outputURL)
        }

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioExtractionError.noAudioTracks }

        // Export to a temp m4a, then convert to WAV
        let tempURL = outputDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExtractionError.exportFailed("Cannot create export session")
        }
        session.outputURL = tempURL
        session.outputFileType = .m4a
        await session.export()

        if let err = session.error {
            throw AudioExtractionError.exportFailed(err.localizedDescription)
        }

        return try await convertWAV(from: tempURL, to: outputURL)
    }

    private func convertWAV(from inputURL: URL, to outputURL: URL) async throws -> URL {
        let inputFile = try AVAudioFile(forReading: inputURL)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: targetFormat) else {
            throw AudioExtractionError.conversionFailed("Cannot create AVAudioConverter")
        }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: targetFormat.settings)

        let chunkSize: AVAudioFrameCount = 8192
        var error: NSError?

        while true {
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: chunkSize)!
            do { try inputFile.read(into: inputBuffer) } catch { break }
            guard inputBuffer.frameLength > 0 else { break }

            let ratio = targetFormat.sampleRate / inputFile.processingFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity)!

            var consumedInput = false
            converter.convert(to: outputBuffer, error: &error) { _, statusPtr in
                if consumedInput {
                    statusPtr.pointee = .noDataNow
                    return nil
                }
                consumedInput = true
                statusPtr.pointee = .haveData
                return inputBuffer
            }
            if let e = error { throw AudioExtractionError.conversionFailed(e.localizedDescription) }
            if outputBuffer.frameLength > 0 { try outputFile.write(from: outputBuffer) }
        }

        return outputURL
    }
}
