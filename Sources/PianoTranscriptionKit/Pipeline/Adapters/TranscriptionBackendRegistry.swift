import Foundation

/// Live status of every transcription backend the kit knows about. The UI
/// reads this to render the Data Flow inspector — every pipeline step in
/// the Mixed Instruments / Advanced flow can show its resolved wrapper
/// path or its missing-dependency reason.
public struct TranscriptionBackendStatus: Equatable, Sendable, Codable {
    public enum BackendID: String, Codable, Sendable, CaseIterable {
        case demucs
        case basicPitch
        case byteDance
    }

    public enum Source: String, Codable, Sendable {
        case envOverride        // resolved via DEMUCS_PATH / BASIC_PITCH_PATH / PIANO_TRANSCRIPTION_PATH
        case repoLocalWrapper   // resolved via tools/transcription/bin
        case path               // resolved via $PATH lookup
        case userExtras         // resolved via per-user / Homebrew / Python framework dirs
        case missing            // not found anywhere
    }

    public let id: BackendID
    public let displayName: String
    /// Wrapper basename the resolver looked for (e.g. `demucs-wrapper`).
    public let wrapperName: String
    /// Env var name that overrides resolution.
    public let envVar: String
    /// Whether the backend is callable right now.
    public let isAvailable: Bool
    /// Where the resolver found the binary, or `.missing`.
    public let source: Source
    /// Absolute path of the resolved wrapper. `nil` when missing.
    public let resolvedPath: String?
    /// Ordered list of paths the resolver checked, with whether each
    /// existed and was executable. Surfaced in Data Flow for debugging.
    public let probes: [Probe]
    /// User-facing reason when missing.
    public let unavailableReason: String?

    public struct Probe: Equatable, Sendable, Codable {
        public let path: String
        public let source: Source
        public let exists: Bool
        public let executable: Bool
    }
}

/// Resolves and reports the status of every transcription backend. Used by
/// the registry, by the new Mixed pipeline's dependency check, and by the
/// inspector's Data Flow section so users can see exactly which paths
/// were consulted and why a particular backend is or isn't available.
public final class TranscriptionBackendRegistry: @unchecked Sendable {

    public static let shared = TranscriptionBackendRegistry()

    public init() {}

    /// Resolution order: env override → repo-local wrapper → PATH → user extras.
    /// Repo root is resolved from PIANO_TRAINER_ROOT, the source-file
    /// location, the current working directory, and `Bundle.main` so the
    /// resolver works from `swift run`, `swift test`, and the packaged app.
    /// All resolved paths are absolute — never relative to the macOS app's
    /// working directory.
    public func resolve(_ id: TranscriptionBackendStatus.BackendID) -> TranscriptionBackendStatus {
        let env = ProcessInfo.processInfo.environment
        let descriptor = descriptorFor(id)
        let disableDiscovery = env["PIANO_TRAINER_DISABLE_DISCOVERY"] == "1"
        var probes: [TranscriptionBackendStatus.Probe] = []
        let log = TranscriptionRunLog.pipeline

        log.debug("backend resolve start id=\(id.rawValue, privacy: .public) wrapper=\(descriptor.wrapperName, privacy: .public) env=\(descriptor.envVar, privacy: .public)")

        // 1. Env override.
        if let v = env[descriptor.envVar], !v.isEmpty {
            let exists = FileManager.default.fileExists(atPath: v)
            let exec = FileManager.default.isExecutableFile(atPath: v)
            log.debug("backend probe id=\(id.rawValue, privacy: .public) source=envOverride path=\(v, privacy: .public) exists=\(exists, privacy: .public) executable=\(exec, privacy: .public)")
            let p = TranscriptionBackendStatus.Probe(path: v, source: .envOverride, exists: exists, executable: exec)
            probes.append(p)
            if exec {
                log.info("backend resolved id=\(id.rawValue, privacy: .public) source=envOverride path=\(v, privacy: .public)")
                return successStatus(id: id, descriptor: descriptor, source: .envOverride, path: v, probes: probes)
            }
        }

        if disableDiscovery {
            log.debug("backend discovery disabled (PIANO_TRAINER_DISABLE_DISCOVERY=1) id=\(id.rawValue, privacy: .public)")
            return missingStatus(id: id, descriptor: descriptor, probes: probes)
        }

        // 2. Repo-local wrappers.
        let roots = candidateRepoRoots()
        for repoRoot in roots {
            log.debug("backend repoRoot id=\(id.rawValue, privacy: .public) root=\(repoRoot.path, privacy: .public)")
            let candidate = repoRoot
                .appendingPathComponent("tools/transcription/bin")
                .appendingPathComponent(descriptor.wrapperName)
            let exists = FileManager.default.fileExists(atPath: candidate.path)
            let exec = FileManager.default.isExecutableFile(atPath: candidate.path)
            log.debug("backend probe id=\(id.rawValue, privacy: .public) source=repoLocal path=\(candidate.path, privacy: .public) exists=\(exists, privacy: .public) executable=\(exec, privacy: .public)")
            let p = TranscriptionBackendStatus.Probe(path: candidate.path, source: .repoLocalWrapper, exists: exists, executable: exec)
            probes.append(p)
            if exec {
                log.info("backend resolved id=\(id.rawValue, privacy: .public) source=repoLocal path=\(candidate.path, privacy: .public)")
                return successStatus(id: id, descriptor: descriptor, source: .repoLocalWrapper, path: candidate.path, probes: probes)
            }
        }

        // 3. PATH.
        let pathDirs = (env["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")
            .split(separator: ":").map(String.init)
        for dir in pathDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(descriptor.wrapperName)
            let exists = FileManager.default.fileExists(atPath: candidate.path)
            let exec = FileManager.default.isExecutableFile(atPath: candidate.path)
            if exists {
                log.debug("backend probe id=\(id.rawValue, privacy: .public) source=PATH path=\(candidate.path, privacy: .public) exists=\(exists, privacy: .public) executable=\(exec, privacy: .public)")
                probes.append(.init(path: candidate.path, source: .path, exists: exists, executable: exec))
            }
            if exec {
                log.info("backend resolved id=\(id.rawValue, privacy: .public) source=PATH path=\(candidate.path, privacy: .public)")
                return successStatus(id: id, descriptor: descriptor, source: .path, path: candidate.path, probes: probes)
            }
        }

        // 4. User / Homebrew / Python framework extras (kept for back-compat
        //    with installs not done via the setup script).
        let home = NSHomeDirectory()
        let extras: [String] = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        for dir in extras {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(descriptor.wrapperName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                probes.append(.init(path: candidate.path, source: .userExtras, exists: true, executable: true))
                log.info("backend resolved id=\(id.rawValue, privacy: .public) source=userExtras path=\(candidate.path, privacy: .public)")
                return successStatus(id: id, descriptor: descriptor, source: .userExtras, path: candidate.path, probes: probes)
            }
        }

        log.error("backend missing id=\(id.rawValue, privacy: .public) wrapper=\(descriptor.wrapperName, privacy: .public) probesChecked=\(probes.count, privacy: .public)")
        return missingStatus(id: id, descriptor: descriptor, probes: probes)
    }

    /// Snapshot of every backend the registry knows about. Used by the UI.
    public func statuses() -> [TranscriptionBackendStatus] {
        TranscriptionBackendStatus.BackendID.allCases.map { resolve($0) }
    }

    // MARK: - Internals

    private struct Descriptor {
        let displayName: String
        let wrapperName: String
        let envVar: String
        let setupHint: String
    }

    private func descriptorFor(_ id: TranscriptionBackendStatus.BackendID) -> Descriptor {
        switch id {
        case .demucs:
            return .init(
                displayName: "Demucs (htdemucs source separation)",
                wrapperName: "demucs-wrapper",
                envVar: "DEMUCS_PATH",
                setupHint: "Run `bash scripts/setup-transcription-deps.sh` to install Demucs."
            )
        case .basicPitch:
            return .init(
                displayName: "Spotify Basic Pitch",
                wrapperName: "basic-pitch-wrapper",
                envVar: "BASIC_PITCH_PATH",
                setupHint: "Run `bash scripts/setup-transcription-deps.sh` to install Basic Pitch."
            )
        case .byteDance:
            return .init(
                displayName: "ByteDance / Qiuqiang Kong piano transcription",
                wrapperName: "piano-transcription-wrapper",
                envVar: "PIANO_TRANSCRIPTION_PATH",
                setupHint: "Run `bash scripts/setup-transcription-deps.sh` to install the piano transcription model."
            )
        }
    }

    private func successStatus(
        id: TranscriptionBackendStatus.BackendID,
        descriptor: Descriptor,
        source: TranscriptionBackendStatus.Source,
        path: String,
        probes: [TranscriptionBackendStatus.Probe]
    ) -> TranscriptionBackendStatus {
        TranscriptionBackendStatus(
            id: id,
            displayName: descriptor.displayName,
            wrapperName: descriptor.wrapperName,
            envVar: descriptor.envVar,
            isAvailable: true,
            source: source,
            resolvedPath: path,
            probes: probes,
            unavailableReason: nil
        )
    }

    private func missingStatus(
        id: TranscriptionBackendStatus.BackendID,
        descriptor: Descriptor,
        probes: [TranscriptionBackendStatus.Probe]
    ) -> TranscriptionBackendStatus {
        TranscriptionBackendStatus(
            id: id,
            displayName: descriptor.displayName,
            wrapperName: descriptor.wrapperName,
            envVar: descriptor.envVar,
            isAvailable: false,
            source: .missing,
            resolvedPath: nil,
            probes: probes,
            unavailableReason: descriptor.setupHint
        )
    }

    private func candidateRepoRoots() -> [URL] {
        var roots: [URL] = []
        if let envRoot = ProcessInfo.processInfo.environment["PIANO_TRAINER_ROOT"], !envRoot.isEmpty {
            roots.append(URL(fileURLWithPath: envRoot))
        }
        roots.append(contentsOf: ancestors(of: URL(fileURLWithPath: #file)))
        roots.append(contentsOf: ancestors(of: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        roots.append(contentsOf: ancestors(of: URL(fileURLWithPath: Bundle.main.bundlePath)))
        return roots
    }

    private func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var u = url
        for _ in 0 ..< 10 {
            u = u.deletingLastPathComponent()
            if u.path == "/" { break }
            result.append(u)
        }
        return result
    }
}
