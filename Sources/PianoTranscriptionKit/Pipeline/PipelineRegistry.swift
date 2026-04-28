import Foundation

/// Central lookup for pipelines keyed by `PipelineKind`. The UI asks the
/// registry for "what pipelines exist?" and "build me the one the user
/// picked"; concrete pipeline classes never need to be referenced from
/// SwiftUI views.
public final class PipelineRegistry: @unchecked Sendable {

    public static let shared = PipelineRegistry()

    /// Optional plug-in point for piano stem separation. Until something is
    /// installed here, `mixedAudio` stays unavailable.
    public var pianoStemSeparator: PianoStemSeparator?
    /// Directory used to store isolated piano stems produced by the mixed
    /// audio pipeline. Resolved per-call in production usage.
    public var stemOutputDirectory: URL?
    /// Plug-in point used by the `mixedInstrumentPianoPrecision` pipeline.
    /// Defaults to `UnavailableSourceSeparator()` so the pipeline reports
    /// itself unavailable until a real backend is installed.
    public var sourceSeparator: SourceSeparator
    /// Plug-in point for the piano-specialized transcriber used by the
    /// precision pipeline. Defaults to a `FallbackPianoTranscriber` (clearly
    /// flagged as a fallback in run metadata) so the rest of the pipeline
    /// can still be exercised end-to-end during development.
    public var pianoSpecializedTranscriber: PianoSpecializedTranscriber
    /// Directory where precision runs persist their intermediate artifacts.
    /// `nil` means "use the default Application Support location".
    public var precisionArtifactRoot: URL?

    /// Adapter for Spotify's Basic Pitch CLI. Resolves availability against
    /// the live filesystem (PATH or `BASIC_PITCH_PATH`) so installing the
    /// CLI flips the pipeline on without an app restart.
    public var basicPitchTranscriber: PianoSpecializedTranscriber
    /// Adapter for the ByteDance / Qiuqiang Kong piano transcription
    /// research code. Same live-PATH resolution as Basic Pitch.
    public var bytedancePianoTranscriber: PianoSpecializedTranscriber
    /// Shared cleanup config used by adapter pipelines (Basic Pitch /
    /// ByteDance) so all advanced runs are post-processed identically and
    /// `RunComparison` produces apples-to-apples signals.
    public var advancedCleanupConfig: TranscriptionCleanup.Config
    /// When true, `makePipeline(.bytedancePiano)` (and other explicit
    /// dedicated-only modes) refuses to silently fall back to Piano-Focused
    /// when the dedicated backend is missing — instead it returns a
    /// `MissingBackendThrowingPipeline` that throws `PipelineError.unavailable`
    /// with the install instructions so the UI can show an honest error
    /// instead of running cleanup on legacy spectral output and pretending
    /// ByteDance ran.
    public var refuseFallbackForDedicatedOnlyModes: Bool

    public init(
        pianoStemSeparator: PianoStemSeparator? = nil,
        stemOutputDirectory: URL? = nil,
        sourceSeparator: SourceSeparator? = nil,
        pianoSpecializedTranscriber: PianoSpecializedTranscriber = FallbackPianoTranscriber(),
        precisionArtifactRoot: URL? = nil,
        basicPitchTranscriber: PianoSpecializedTranscriber = BasicPitchTranscriber(),
        bytedancePianoTranscriber: PianoSpecializedTranscriber = ByteDancePianoTranscriber(),
        advancedCleanupConfig: TranscriptionCleanup.Config = .init(),
        refuseFallbackForDedicatedOnlyModes: Bool = true
    ) {
        // The Demucs wrapper adapter doubles as both PianoStemSeparator (used
        // by MixedAudioPianoIsolationPipeline) and SourceSeparator (used by
        // MixedInstrumentPianoPrecisionPipeline + MixedInstrumentsAdvanced).
        // We use `DemucsWrapperSeparator` — which resolves the repo-local
        // `tools/transcription/bin/demucs-wrapper` via TranscriptionBackend
        // Registry — instead of the legacy `DemucsSourceSeparator` (which
        // looked for a bare `demucs` binary on PATH and failed when the
        // venv-only install was the only one present).
        let demucs = DemucsWrapperSeparator()
        let resolvedStemSeparator: PianoStemSeparator? = pianoStemSeparator ?? (demucs.isAvailable ? demucs : nil)
        let resolvedSourceSeparator: SourceSeparator = sourceSeparator
            ?? (demucs.isAvailable ? demucs : UnavailableSourceSeparator())

        self.pianoStemSeparator = resolvedStemSeparator
        self.stemOutputDirectory = stemOutputDirectory
        self.sourceSeparator = resolvedSourceSeparator
        self.pianoSpecializedTranscriber = pianoSpecializedTranscriber
        self.precisionArtifactRoot = precisionArtifactRoot
        self.basicPitchTranscriber = basicPitchTranscriber
        self.bytedancePianoTranscriber = bytedancePianoTranscriber
        self.advancedCleanupConfig = advancedCleanupConfig
        self.refuseFallbackForDedicatedOnlyModes = refuseFallbackForDedicatedOnlyModes
    }

    /// All pipeline kinds the UI should display, in the recommended order.
    /// Test-only pipelines are excluded.
    public var availableKinds: [PipelineKind] { PipelineKind.userVisibleCases }

    /// Whether a pipeline of the given kind is selectable in the UI. Every
    /// user-visible kind is selectable — the registry routes to a Piano-Focused
    /// fallback when dedicated dependencies are missing, and `fallbackReason(_:)`
    /// reports why so the UI can show an honest status message.
    public func isAvailable(_ kind: PipelineKind) -> Bool {
        // Test-only kind not exposed to user; everything else stays selectable.
        kind.isAvailable
    }

    /// Whether the kind has a *dedicated* backend installed (vs. running on
    /// a Piano-Focused fallback). UI uses this to render a "Fallback" badge
    /// without disabling the row.
    public func hasDedicatedBackend(_ kind: PipelineKind) -> Bool {
        switch kind {
        case .basicFast, .pianoFocused, .mockDemo: return true
        case .mixedAudio: return pianoStemSeparator != nil
        case .mixedInstrumentPianoPrecision:
            return sourceSeparator.isAvailable && pianoSpecializedTranscriber.isAvailable
        case .basicPitch, .portablePianoBaseline:
            return basicPitchTranscriber.isAvailable
        case .bytedancePiano:
            return bytedancePianoTranscriber.isAvailable
        case .cleanSoloPiano:
            return bytedancePianoTranscriber.isAvailable
        case .noisySoloPiano:
            return basicPitchTranscriber.isAvailable
        case .mixedInstrumentsAdvanced:
            // Mixed Instruments / Advanced requires Demucs + at least one
            // post-separation transcriber. Basic Pitch is preferred but
            // ByteDance alone is also acceptable (the pipeline will mark
            // the run as "less stable" in that case).
            return sourceSeparator.isAvailable
                && (basicPitchTranscriber.isAvailable || bytedancePianoTranscriber.isAvailable)
        }
    }

    /// Per-adapter status snapshot for the UI / `--diagnose` CLI. Returns the
    /// resolved binary path when available and the install hint when not.
    public struct AdapterStatus: Equatable, Sendable {
        public let name: String
        public let isAvailable: Bool
        public let resolvedPath: String?
        public let unavailableReason: String?
    }

    /// Reports the live status of every external-model adapter the registry
    /// knows about. Computed on demand so adapters track newly-installed
    /// binaries without an app restart.
    public func adapterStatuses() -> [AdapterStatus] {
        var out: [AdapterStatus] = []
        // Basic Pitch (used by both `basicPitch` and `portablePianoBaseline`).
        let bp = ExternalCommandRunner.locate(
            executable: BasicPitchTranscriber.executableName,
            envOverride: BasicPitchTranscriber.envOverride
        )
        out.append(AdapterStatus(
            name: "Basic Pitch",
            isAvailable: bp != nil,
            resolvedPath: bp?.path,
            unavailableReason: bp == nil ? basicPitchTranscriber.unavailableReason : nil
        ))
        // ByteDance Piano Transcription.
        let bd = ExternalCommandRunner.locate(
            executable: ByteDancePianoTranscriber.executableName,
            envOverride: ByteDancePianoTranscriber.envOverride
        )
        out.append(AdapterStatus(
            name: "ByteDance Piano Transcription",
            isAvailable: bd != nil,
            resolvedPath: bd?.path,
            unavailableReason: bd == nil ? bytedancePianoTranscriber.unavailableReason : nil
        ))
        out.append(AdapterStatus(
            name: "Source Separator",
            isAvailable: sourceSeparator.isAvailable,
            resolvedPath: nil,
            unavailableReason: sourceSeparator.unavailableReason
        ))
        return out
    }

    /// Returns the reason a kind is on the Piano-Focused fallback, or `nil`
    /// if it has its dedicated backend installed.
    public func fallbackReason(_ kind: PipelineKind) -> String? {
        guard !hasDedicatedBackend(kind) else { return nil }
        switch kind {
        case .cleanSoloPiano, .noisySoloPiano, .mixedInstrumentsAdvanced:
            // The new pipelines do NOT fall back. Surface the install
            // hint so the UI shows a blocking error instead of a fallback.
            return kind.unavailableReason
        case .mixedAudio:
            return "No piano stem separator installed — using Piano-Focused fallback for this mode until dedicated model files are installed."
        case .mixedInstrumentPianoPrecision:
            if !sourceSeparator.isAvailable {
                return (sourceSeparator.unavailableReason ?? kind.unavailableReason ?? "")
                    + " Using Piano-Focused fallback for this mode until dedicated model files are installed."
            }
            if !pianoSpecializedTranscriber.isAvailable {
                return (pianoSpecializedTranscriber.unavailableReason ?? kind.unavailableReason ?? "")
                    + " Using Piano-Focused fallback for this mode until dedicated model files are installed."
            }
            return kind.unavailableReason
        case .basicPitch, .portablePianoBaseline:
            return (basicPitchTranscriber.unavailableReason ?? kind.unavailableReason ?? "")
                + " Using Piano-Focused fallback for this mode until dedicated model files are installed."
        case .bytedancePiano:
            return (bytedancePianoTranscriber.unavailableReason ?? kind.unavailableReason ?? "")
                + " Using Piano-Focused fallback for this mode until dedicated model files are installed."
        case .basicFast, .pianoFocused, .mockDemo:
            return nil
        }
    }

    /// Back-compat shim for callers that still reference `unavailableReason`.
    /// Now returns `fallbackReason(_:)` since no user-visible kind is ever
    /// truly unavailable.
    public func unavailableReason(_ kind: PipelineKind) -> String? {
        fallbackReason(kind)
    }

    /// Builds the pipeline implementation for `kind`. Always returns a
    /// runnable pipeline for user-visible kinds — when the dedicated backend
    /// is missing the registry returns a `FallbackTranscriptionPipeline`
    /// that delegates to Piano-Focused and stamps `fallback.*` metadata so
    /// the UI can clearly show what happened.
    public func makePipeline(_ kind: PipelineKind) -> (any TranscriptionPipeline)? {
        switch kind {
        case .cleanSoloPiano:
            return CleanSoloPianoPipeline(
                transcriber: bytedancePianoTranscriber,
                cleanupConfig: advancedCleanupConfig
            )
        case .noisySoloPiano:
            return NoisySoloPianoPipeline(
                transcriber: basicPitchTranscriber,
                cleanupConfig: advancedCleanupConfig.with { $0.minVelocity = 18 }
            )
        case .mixedInstrumentsAdvanced:
            // Build the full Demucs → (Basic Pitch | ByteDance) chain.
            // Basic Pitch is the preferred primary (more robust on stems
            // with residual instrument leakage); ByteDance is used as a
            // refinement candidate when available, and never required.
            // If Demucs OR (Basic Pitch AND ByteDance) is missing, the
            // pipeline's `run()` throws PipelineError.unavailable with the
            // exact setup-script command — never silent fallback.
            let separator: SourceSeparator = sourceSeparator.isAvailable
                ? sourceSeparator
                : DemucsWrapperSeparator()
            return MixedInstrumentsAdvancedPipeline(
                separator: separator,
                basicPitch: basicPitchTranscriber,
                byteDance: bytedancePianoTranscriber,
                cleanupConfig: advancedCleanupConfig
            )
        case .basicFast:
            return BasicFastPipeline()
        case .pianoFocused:
            return PianoFocusedPipeline()
        case .mixedAudio:
            if let separator = pianoStemSeparator {
                return MixedAudioPianoIsolationPipeline(
                    separator: separator,
                    stemOutputDirectory: stemOutputDirectory
                )
            }
            // No separator wired in — fall back to Piano-Focused and stamp
            // the run with the missing-dependency reason so the UI is honest.
            return FallbackTranscriptionPipeline(
                kind: .mixedAudio,
                fallbackReason: fallbackReason(.mixedAudio) ?? "Piano stem separator not installed."
            )
        case .mixedInstrumentPianoPrecision:
            if hasDedicatedBackend(.mixedInstrumentPianoPrecision) {
                return MixedInstrumentPianoPrecisionPipeline(
                    separator: sourceSeparator,
                    transcriber: pianoSpecializedTranscriber,
                    artifactRoot: precisionArtifactRoot
                )
            }
            return FallbackTranscriptionPipeline(
                kind: .mixedInstrumentPianoPrecision,
                fallbackReason: fallbackReason(.mixedInstrumentPianoPrecision) ?? "Source-separation backend not installed."
            )
        case .basicPitch:
            if hasDedicatedBackend(.basicPitch) {
                return ExternalModelPipeline(
                    kind: .basicPitch,
                    transcriber: basicPitchTranscriber,
                    cleanupConfig: advancedCleanupConfig
                )
            }
            return FallbackTranscriptionPipeline(
                kind: .basicPitch,
                fallbackReason: fallbackReason(.basicPitch) ?? "Basic Pitch CLI not installed."
            )
        case .portablePianoBaseline:
            if hasDedicatedBackend(.portablePianoBaseline) {
                return ExternalModelPipeline(
                    kind: .portablePianoBaseline,
                    transcriber: basicPitchTranscriber,
                    cleanupConfig: advancedCleanupConfig
                )
            }
            return FallbackTranscriptionPipeline(
                kind: .portablePianoBaseline,
                fallbackReason: fallbackReason(.portablePianoBaseline) ?? "Portable model backend not installed."
            )
        case .bytedancePiano:
            if hasDedicatedBackend(.bytedancePiano) {
                return ExternalModelPipeline(
                    kind: .bytedancePiano,
                    transcriber: bytedancePianoTranscriber,
                    cleanupConfig: advancedCleanupConfig
                )
            }
            // ByteDance is dedicated-only. We refuse to silently substitute
            // Piano-Focused under the ByteDance label, because doing so
            // breaks the user's ability to compare "did the advanced model
            // help?" — the run would look like ByteDance ran and improved
            // nothing. Throw with install instructions instead.
            if refuseFallbackForDedicatedOnlyModes {
                return MissingBackendThrowingPipeline(
                    kind: .bytedancePiano,
                    reason: bytedancePianoTranscriber.unavailableReason
                        ?? PipelineKind.bytedancePiano.unavailableReason
                        ?? "ByteDance Piano wrapper is not installed."
                )
            }
            return FallbackTranscriptionPipeline(
                kind: .bytedancePiano,
                fallbackReason: fallbackReason(.bytedancePiano) ?? "ByteDance wrapper not installed."
            )
        case .mockDemo:
            return DefaultPipeline(runner: MockModelRunner(), kind: .mockDemo)
        }
    }

    /// Builds a `ModelRunner` for the kind — used by diagnostics, which only
    /// needs the runner half of a pipeline. Falls back to the basic runner
    /// for kinds that wrap an external separator.
    public func makeRunner(_ kind: PipelineKind) -> (any ModelRunner)? {
        switch kind {
        case .basicFast:    return BasicPianoModelRunner(config: .basic)
        case .pianoFocused: return BasicPianoModelRunner(config: .pianoFocused)
        case .mixedAudio:   return pianoStemSeparator == nil ? nil : BasicPianoModelRunner(config: .pianoFocused)
        case .mixedInstrumentPianoPrecision:
            return isAvailable(.mixedInstrumentPianoPrecision) ? BasicPianoModelRunner(config: .pianoFocused) : nil
        case .basicPitch, .portablePianoBaseline:
            // The portable baseline is a real ModelRunner now — return it
            // directly so anyone holding the runner half (diagnostics,
            // batch-runners) gets the actual external model.
            return isAvailable(kind) ? BasicPitchModelRunner() : nil
        case .bytedancePiano:
            // ByteDance is still external-only; diagnostics fall back to
            // the in-house spectral runner just to validate the kit is healthy.
            return isAvailable(kind) ? BasicPianoModelRunner(config: .pianoFocused) : nil
        case .cleanSoloPiano, .mixedInstrumentsAdvanced:
            // ByteDance-backed; diagnostics use the in-house runner so the
            // kit-health check doesn't depend on the external CLI.
            return BasicPianoModelRunner(config: .pianoFocused)
        case .noisySoloPiano:
            // Basic Pitch–backed; expose its real ModelRunner so diagnostics
            // exercise the actual external CLI when it's installed.
            return basicPitchTranscriber.isAvailable ? BasicPitchModelRunner() : BasicPianoModelRunner(config: .pianoFocused)
        case .mockDemo:     return MockModelRunner()
        }
    }
}
