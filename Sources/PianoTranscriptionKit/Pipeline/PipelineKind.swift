import Foundation

/// The set of transcription pipelines the user can pick between.
/// One entry per user-visible "pipeline" regardless of whether the underlying
/// implementation is currently available — unavailable pipelines render a
/// disabled menu item with a clear "coming soon" hint.
public enum PipelineKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case basicSpectral
    case mockDemo
    case neuralOnsetsFrames

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .basicSpectral:      return "Basic Spectral"
        case .mockDemo:           return "Mock (Demo)"
        case .neuralOnsetsFrames: return "Neural Onsets & Frames"
        }
    }

    public var summary: String {
        switch self {
        case .basicSpectral:      return "Fast FFT-based harmonic salience. Works fully offline."
        case .mockDemo:           return "Synthetic demo notes — for UI testing only."
        case .neuralOnsetsFrames: return "Deep-learning piano transcription. Coming soon."
        }
    }

    public var systemImage: String {
        switch self {
        case .basicSpectral:      return "waveform"
        case .mockDemo:           return "die.face.3"
        case .neuralOnsetsFrames: return "brain.head.profile"
        }
    }

    /// Whether a runner exists for this pipeline today.
    public var isAvailable: Bool {
        switch self {
        case .basicSpectral, .mockDemo: return true
        case .neuralOnsetsFrames:       return false
        }
    }

    /// Builds a runner for this pipeline. Returns nil for unavailable pipelines.
    public func makeRunner() -> (any ModelRunner)? {
        switch self {
        case .basicSpectral:      return BasicPianoModelRunner()
        case .mockDemo:           return MockModelRunner()
        case .neuralOnsetsFrames: return nil
        }
    }
}
