import Foundation

/// Repair profile for `MidiClinic`. Declares the active pipeline's musical
/// hypothesis and the ordered repair sequence to run. Profiles never
/// silently mutate the data — every operation lands in `RepairLog`
/// counters so the inspector can show what changed.
public struct MidiRepairProfile: Sendable, Equatable, Codable {

    public enum Identifier: String, Sendable, Equatable, Codable {
        case melodyOnly
        case cleanSoloPiano
        case noisySoloPiano
        case mixedAudio
    }

    public let id: Identifier
    public let name: String

    /// Pitch range gate (inclusive).
    public let pitchLow: Int
    public let pitchHigh: Int
    /// Hard cap on simultaneous notes.
    public let maxSimultaneous: Int
    /// Hard cap on notes per second within a 1s window.
    public let maxNotesPerSecond: Int
    /// Drop notes shorter than this.
    public let minNoteDuration: Double
    /// Notes longer than this are clamped to this duration.
    public let maxNoteDuration: Double
    /// Onset cluster window (seconds) used by chord/onset-cluster repair.
    public let onsetClusterWindow: Double
    /// Maximum chord size — clusters larger than this are pruned to
    /// `maxChord` strongest notes.
    public let maxChord: Int
    /// Same-pitch fragments separated by less than this gap are merged.
    public let mergeFragmentMaxGap: Double
    /// Notes shorter than `isolatedNoteMinDuration` AND with no neighbours
    /// within `isolatedNeighborWindow` seconds are removed as ghost notes.
    public let isolatedNoteMinDuration: Double
    public let isolatedNeighborWindow: Double
    /// Velocity threshold below which short isolated notes are considered
    /// ghosts.
    public let ghostVelocity: Int
    /// Timing-jitter smoothing window (milliseconds). 0 disables.
    public let timingJitterMs: Double
    /// Whether to extend short notes to the next same-pitch onset to
    /// preserve a sustained note. Only legal for solo piano profiles.
    public let preserveSustain: Bool
    /// Whether the profile collapses simultaneous notes into a single
    /// melody line. Only for `melodyOnly`.
    public let extractMelodyLine: Bool

    public static let melodyOnly = MidiRepairProfile(
        id: .melodyOnly, name: "Melody Only",
        pitchLow: 55, pitchHigh: 84,
        maxSimultaneous: 1,
        maxNotesPerSecond: 12,
        minNoteDuration: 0.120,
        maxNoteDuration: 6.0,
        onsetClusterWindow: 0.040,
        maxChord: 1,
        mergeFragmentMaxGap: 0.120,
        isolatedNoteMinDuration: 0.150,
        isolatedNeighborWindow: 0.50,
        ghostVelocity: 28,
        timingJitterMs: 25,
        preserveSustain: false,
        extractMelodyLine: true
    )

    public static let cleanSoloPiano = MidiRepairProfile(
        id: .cleanSoloPiano, name: "Clean Solo Piano",
        pitchLow: 21, pitchHigh: 108,
        maxSimultaneous: 8,
        maxNotesPerSecond: 18,
        minNoteDuration: 0.070,
        maxNoteDuration: 15.0,
        onsetClusterWindow: 0.050,
        maxChord: 6,
        mergeFragmentMaxGap: 0.070,
        isolatedNoteMinDuration: 0.10,
        isolatedNeighborWindow: 0.40,
        ghostVelocity: 14,
        timingJitterMs: 0, // never quantize expressive piano timing
        preserveSustain: true,
        extractMelodyLine: false
    )

    public static let noisySoloPiano = MidiRepairProfile(
        id: .noisySoloPiano, name: "Noisy Solo Piano",
        pitchLow: 36, pitchHigh: 96,
        maxSimultaneous: 6,
        maxNotesPerSecond: 14,
        minNoteDuration: 0.100,
        maxNoteDuration: 8.0,
        onsetClusterWindow: 0.050,
        maxChord: 5,
        mergeFragmentMaxGap: 0.080,
        isolatedNoteMinDuration: 0.15,
        isolatedNeighborWindow: 0.50,
        ghostVelocity: 26,
        timingJitterMs: 0,
        preserveSustain: true,
        extractMelodyLine: false
    )

    public static let mixedAudio = MidiRepairProfile(
        id: .mixedAudio, name: "Mixed Audio",
        pitchLow: 40, pitchHigh: 88,
        maxSimultaneous: 5,
        maxNotesPerSecond: 8,
        minNoteDuration: 0.120,
        maxNoteDuration: 5.0,
        onsetClusterWindow: 0.050,
        maxChord: 5,
        mergeFragmentMaxGap: 0.080,
        isolatedNoteMinDuration: 0.20,
        isolatedNeighborWindow: 0.50,
        ghostVelocity: 30,
        timingJitterMs: 0,
        preserveSustain: false,
        extractMelodyLine: false
    )

    /// Diagnosis context that matches this profile's expectations.
    public var diagnosisContext: MidiDiagnoser.Context {
        switch id {
        case .melodyOnly:      return .melodyOnly
        case .cleanSoloPiano:  return .cleanSoloPiano
        case .noisySoloPiano:  return .noisySoloPiano
        case .mixedAudio:      return .mixedAudio
        }
    }

    /// Map a pipeline kind to its default repair profile. Mixed Instruments
    /// always uses `mixedAudio` — even with separation Demucs leaves
    /// instrument leakage in the stem.
    public static func `default`(for pipelineKind: PipelineKind) -> MidiRepairProfile {
        switch pipelineKind {
        case .cleanSoloPiano:           return .cleanSoloPiano
        case .noisySoloPiano:           return .noisySoloPiano
        case .mixedInstrumentsAdvanced: return .mixedAudio
        default:                        return .cleanSoloPiano
        }
    }
}
