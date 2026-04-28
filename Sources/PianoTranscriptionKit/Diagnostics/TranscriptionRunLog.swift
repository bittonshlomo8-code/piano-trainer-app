import Foundation
import os

/// Central os.Logger used across the kit so every data-flow event lands in
/// the same subsystem and can be filtered with
///   `log stream --predicate 'subsystem == "PianoTranscriptionKit"'`.
///
/// Categories:
///   - Pipeline:  pipeline lifecycle (run start, raw → cleaned counts)
///   - Run:       run construction (mandatory cleanup factory)
///   - Export:    MIDI export (file path, note count being written)
///   - Playback:  notes loaded into the player
public enum TranscriptionRunLog {
    public static let subsystem = "PianoTranscriptionKit"
    public static let log      = Logger(subsystem: subsystem, category: "Run")
    public static let pipeline = Logger(subsystem: subsystem, category: "Pipeline")
    public static let export   = Logger(subsystem: subsystem, category: "Export")
    public static let playback = Logger(subsystem: subsystem, category: "Playback")
}
