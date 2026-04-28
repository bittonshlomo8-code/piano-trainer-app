import Foundation
import AVFoundation

/// Normalizes any AVFoundation-readable input into a deterministic WAV used
/// by the precision pipeline (mono, float32, 44.1 kHz). The output preserves
/// the original timeline — the first sample of the source ends up at sample
/// 0 of the normalized file — so downstream stages can line onsets up
/// directly with the original recording.
public final class AudioNormalizer: @unchecked Sendable {
    public let targetSampleRate: Double
    public let targetChannels: AVAudioChannelCount

    public init(targetSampleRate: Double = 44100, targetChannels: AVAudioChannelCount = 1) {
        self.targetSampleRate = targetSampleRate
        self.targetChannels = targetChannels
    }

    public struct NormalizedAudio: Sendable, Equatable {
        public let url: URL
        public let durationSeconds: Double
        public let sampleRate: Double
        public let channelCount: Int

        public init(url: URL, durationSeconds: Double, sampleRate: Double, channelCount: Int) {
            self.url = url
            self.durationSeconds = durationSeconds
            self.sampleRate = sampleRate
            self.channelCount = channelCount
        }
    }

    /// Convert `sourceURL` to a deterministic WAV at `<outputDirectory>/<baseName>_normalized.wav`.
    /// If the source already matches the target format, the file is copied
    /// verbatim so downstream tools see the same bytes both times.
    public func normalize(sourceURL: URL, outputDirectory: URL) throws -> NormalizedAudio {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outURL = outputDirectory.appendingPathComponent("\(baseName)_normalized.wav")

        let srcFile = try AVAudioFile(forReading: sourceURL)
        let srcFmt = srcFile.processingFormat
        let totalFrames = AVAudioFrameCount(srcFile.length)
        guard totalFrames > 0 else {
            throw ModelRunnerError.audioLoadFailed("Source has zero frames: \(sourceURL.lastPathComponent)")
        }

        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: totalFrames) else {
            throw ModelRunnerError.audioLoadFailed("Cannot allocate read buffer")
        }
        try srcFile.read(into: srcBuf)

        guard let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: targetSampleRate,
                                         channels: targetChannels,
                                         interleaved: false) else {
            throw ModelRunnerError.audioLoadFailed("Cannot create target format")
        }

        // Fast path — already normalized.
        if srcFmt.commonFormat == .pcmFormatFloat32,
           srcFmt.channelCount == targetChannels,
           abs(srcFmt.sampleRate - targetSampleRate) < 1 {
            // Write a fresh WAV (rather than file-copy) so the output is
            // always a valid PCM-WAV irrespective of input container.
            try writeBuffer(srcBuf, to: outURL, format: dstFmt)
            let duration = Double(srcBuf.frameLength) / targetSampleRate
            return NormalizedAudio(
                url: outURL,
                durationSeconds: duration,
                sampleRate: targetSampleRate,
                channelCount: Int(targetChannels)
            )
        }

        guard let conv = AVAudioConverter(from: srcFmt, to: dstFmt) else {
            throw ModelRunnerError.audioLoadFailed("Cannot create AVAudioConverter")
        }
        let dstCapacity = AVAudioFrameCount(Double(srcBuf.frameLength) * targetSampleRate / srcFmt.sampleRate) + 1024
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: dstCapacity) else {
            throw ModelRunnerError.audioLoadFailed("Cannot allocate conversion buffer")
        }

        var convErr: NSError?
        var fed = false
        conv.convert(to: dstBuf, error: &convErr) { _, statusPtr in
            guard !fed else { statusPtr.pointee = .noDataNow; return nil }
            fed = true
            statusPtr.pointee = .haveData
            return srcBuf
        }
        if let e = convErr {
            throw ModelRunnerError.audioLoadFailed(e.localizedDescription)
        }

        try writeBuffer(dstBuf, to: outURL, format: dstFmt)
        let duration = Double(dstBuf.frameLength) / targetSampleRate
        return NormalizedAudio(
            url: outURL,
            durationSeconds: duration,
            sampleRate: targetSampleRate,
            channelCount: Int(targetChannels)
        )
    }

    private func writeBuffer(_ buffer: AVAudioPCMBuffer, to url: URL, format: AVAudioFormat) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // Scope the writer so its handle is released before any reader opens
        // the same path — AVAudioFile reports length 0 otherwise.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
    }
}
