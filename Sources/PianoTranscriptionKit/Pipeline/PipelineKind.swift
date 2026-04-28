import Foundation

/// The set of transcription pipelines the user can pick between.
///
/// User-visible pipelines: `cleanSoloPiano`, `noisySoloPiano`,
/// `mixedInstrumentsAdvanced`. Each is backed by a real external model
/// installed by `scripts/setup-transcription-deps.sh` — there is no
/// silent-fallback path; if a backend is missing the pipeline throws
/// `PipelineError.unavailable` with the install instructions so the UI
/// can show a clear blocking error.
///
/// The legacy cases (`pianoFocused`, `basicFast`, `mockDemo`, plus the
/// older `mixedAudio` / `mixedInstrumentPianoPrecision` / `basicPitch` /
/// `portablePianoBaseline` / `bytedancePiano` aliases) stay in the enum
/// for back-compatibility with persisted runs and existing tests, but
/// they are NOT in `userVisibleCases` — they don't appear in the
/// importer sheet or the inspector picker.
public enum PipelineKind: String, CaseIterable, Identifiable, Codable, Sendable {
    // MARK: - User-visible (the only three pipelines exposed in the UI)

    /// Studio / clean piano recording → ByteDance high-resolution model.
    case cleanSoloPiano
    /// Phone-mic / room-recording / hum-noise piano → Basic Pitch (more
    /// robust to capture noise than the high-resolution research model).
    case noisySoloPiano
    /// Mixed-instrument song → Demucs source-separation → ByteDance.
    case mixedInstrumentsAdvanced

    // MARK: - Legacy (kept for back-compat; not in userVisibleCases)

    case basicFast
    case pianoFocused
    case mixedAudio
    case mixedInstrumentPianoPrecision
    case basicPitch
    case portablePianoBaseline
    case bytedancePiano
    case mockDemo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cleanSoloPiano:           return "Clean Solo Piano"
        case .noisySoloPiano:           return "Noisy Solo Piano"
        case .mixedInstrumentsAdvanced: return "Mixed Instruments / Advanced"
        case .basicFast:                return "Basic / Legacy Baseline"
        case .pianoFocused:             return "Piano-Focused (Legacy)"
        case .mixedAudio:               return "Mixed Audio / Piano Isolation (Legacy)"
        case .mixedInstrumentPianoPrecision: return "Mixed Instruments / Piano Precision (Legacy)"
        case .basicPitch:               return "Basic Pitch (Legacy alias)"
        case .portablePianoBaseline:    return "Portable Piano Baseline (Legacy)"
        case .bytedancePiano:           return "ByteDance Piano (Legacy alias)"
        case .mockDemo:                 return "Mock (Demo)"
        }
    }

    public var summary: String {
        switch self {
        case .cleanSoloPiano:
            return "Studio or clean recordings of solo piano. Runs the high-resolution ByteDance / Qiuqiang Kong piano transcription model directly."
        case .noisySoloPiano:
            return "Solo piano recorded with phone-mic / room ambience / hum noise. Runs Spotify's Basic Pitch — robust to capture noise."
        case .mixedInstrumentsAdvanced:
            return "Songs with vocals, drums, or other instruments alongside piano. Demucs isolates the piano stem first, then ByteDance transcribes it."
        case .basicFast:        return "Legacy in-house spectral detector. Hidden from the picker."
        case .pianoFocused:     return "Legacy spectral detector with refinement. Hidden from the picker."
        case .mixedAudio:       return "Legacy mixed-audio pipeline. Hidden from the picker."
        case .mixedInstrumentPianoPrecision:
                                return "Legacy precision pipeline. Hidden from the picker."
        case .basicPitch:       return "Legacy Basic Pitch alias. Use Noisy Solo Piano instead."
        case .portablePianoBaseline:
                                return "Legacy portable baseline alias. Use Noisy Solo Piano instead."
        case .bytedancePiano:   return "Legacy ByteDance alias. Use Clean Solo Piano instead."
        case .mockDemo:         return "Synthetic demo notes — for UI testing only."
        }
    }

    public var systemImage: String {
        switch self {
        case .cleanSoloPiano:           return "pianokeys"
        case .noisySoloPiano:           return "waveform.and.mic"
        case .mixedInstrumentsAdvanced: return "waveform.path.ecg.rectangle"
        case .basicFast:                return "bolt.horizontal"
        case .pianoFocused:             return "pianokeys"
        case .mixedAudio:               return "waveform.path.ecg"
        case .mixedInstrumentPianoPrecision: return "scope"
        case .basicPitch:               return "music.note.list"
        case .portablePianoBaseline:    return "iphone.gen3"
        case .bytedancePiano:           return "brain.head.profile"
        case .mockDemo:                 return "die.face.3"
        }
    }

    /// Whether this kind is enumerable in the user-facing UI. The runtime
    /// availability (i.e. "is the backend installed?") is reported by
    /// `PipelineRegistry.hasDedicatedBackend(_:)` separately.
    public var isAvailable: Bool {
        switch self {
        case .cleanSoloPiano, .noisySoloPiano, .mixedInstrumentsAdvanced,
             .basicFast, .pianoFocused, .mixedAudio,
             .mixedInstrumentPianoPrecision, .basicPitch,
             .portablePianoBaseline, .bytedancePiano, .mockDemo:
            return true
        }
    }

    public var unavailableReason: String? {
        switch self {
        case .cleanSoloPiano:
            return "Clean Solo Piano needs the ByteDance piano transcription wrapper. Run `bash scripts/setup-transcription-deps.sh`."
        case .noisySoloPiano:
            return "Noisy Solo Piano needs the Basic Pitch wrapper. Run `bash scripts/setup-transcription-deps.sh`."
        case .mixedInstrumentsAdvanced:
            return "Mixed Instruments / Advanced requires Demucs and either Basic Pitch or piano-transcription-wrapper. Run bash scripts/setup-transcription-deps.sh."
        default:
            return nil
        }
    }

    /// Pipelines surfaced in user-visible UI (importer sheet, sidebar picker).
    /// Only the three new pipelines appear; legacy kinds stay accessible
    /// from persisted runs but are not selectable.
    public static var userVisibleCases: [PipelineKind] {
        [.cleanSoloPiano, .noisySoloPiano, .mixedInstrumentsAdvanced]
    }

    /// Default starting pipeline for a fresh install.
    public static let defaultKind: PipelineKind = .noisySoloPiano

    /// True when the pipeline expects already-clean piano audio. The picker
    /// uses this to warn when the user selects a clean-piano model on
    /// material that looks mixed.
    public var expectsCleanPianoAudio: Bool {
        switch self {
        case .cleanSoloPiano, .pianoFocused, .basicFast,
             .basicPitch, .portablePianoBaseline, .bytedancePiano:
            return true
        case .noisySoloPiano, .mixedInstrumentsAdvanced,
             .mixedAudio, .mixedInstrumentPianoPrecision, .mockDemo:
            return false
        }
    }

    public var mixedAudioSuitabilityWarning: String? {
        guard expectsCleanPianoAudio else { return nil }
        return "This pipeline expects clean / studio piano audio. For songs with vocals, drums, or other instruments use **Mixed Instruments / Advanced** instead."
    }
}
