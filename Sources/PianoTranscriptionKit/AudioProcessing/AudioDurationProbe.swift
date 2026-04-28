import Foundation
import AVFoundation

/// Cheap one-shot duration probe used by pipelines so they can:
///   1. clamp note ends against the source length, and
///   2. record the source duration on the resulting `TranscriptionRun`.
///
/// Lives in its own type so all pipelines hit the same code path; the previous
/// regime had each pipeline computing duration differently which was the root
/// cause of timeline drift.
public enum AudioDurationProbe {
    public static func durationSeconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return nil }
        return Double(file.length) / sr
    }
}
