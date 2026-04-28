import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Helpers for invoking external CLI tools (Basic Pitch, ByteDance Piano
/// Transcription, future model wrappers). All operations are synchronous and
/// suitable for `Task.detached` callers.
public enum ExternalCommandRunner {

    public struct Result: Sendable, Equatable {
        public let exitStatus: Int32
        public let stdout: String
        public let stderr: String
    }

    public enum CommandError: Error, LocalizedError {
        case binaryNotFound(name: String)
        case launchFailed(String)
        case nonZeroExit(name: String, status: Int32, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound(let n):
                return "External binary not found: \(n). Install it or set the corresponding environment variable to its full path."
            case .launchFailed(let m):
                return "Failed to launch external process: \(m)"
            case .nonZeroExit(let n, let s, let e):
                let trimmed = e.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(n) exited with status \(s).\(trimmed.isEmpty ? "" : " stderr: \(trimmed)")"
            }
        }
    }

    /// Repo-local wrapper directory. Populated by
    /// `scripts/setup-transcription-deps.sh` with shell wrappers
    /// (`basic-pitch-wrapper`, `demucs-wrapper`,
    /// `piano-transcription-wrapper`) that source the project's per-repo
    /// venv. The Swift kit looks here first so the repo is self-contained.
    public static let repoWrapperRelativePath = "tools/transcription/bin"

    /// Resolves an executable URL via, in order:
    ///   1. The optional environment variable name (full path).
    ///   2. Repo-local wrapper directory (`tools/transcription/bin`).
    ///   3. PATH lookup.
    ///   4. A small list of common per-user venv / Homebrew locations.
    ///
    /// Returns `nil` when the binary cannot be located. Cheap to call — the
    /// adapter's `isAvailable` flag uses this on every invocation so a newly
    /// installed binary is picked up without an app restart.
    ///
    /// macOS GUI apps inherit a stripped-down PATH (typically just
    /// `/usr/bin:/bin:/usr/sbin:/sbin`), so `pip install`-style binaries in
    /// `~/.local/bin` or a Homebrew-managed Python's bin directory aren't
    /// reachable from the SwiftUI app even when they are from a Terminal.
    /// The repo-local + extra search list makes the adapter find them anyway.
    public static func locate(executable: String, envOverride: String? = nil) -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let key = envOverride, let path = env[key], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        // Test escape hatch: tests that exercise the "backend missing" path
        // set this so PATH / repo-local / home discovery is bypassed and
        // only the explicit env override above can satisfy lookup.
        if env["PIANO_TRAINER_DISABLE_DISCOVERY"] == "1" {
            return nil
        }
        // Repo-local wrappers come second so a checked-out copy of the repo
        // doesn't depend on global PATH or per-user installs.
        for repoRoot in candidateRepoRoots() {
            let candidate = repoRoot
                .appendingPathComponent(repoWrapperRelativePath)
                .appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // Try PATH lookup.
        let pathDirs = (env["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")
            .split(separator: ":")
            .map(String.init)
        for dir in pathDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // Common per-user / Homebrew locations the GUI app's PATH usually
        // misses. Order: user-local installs first, then Homebrew, then
        // pipx, then the standalone Python framework.
        let home = NSHomeDirectory()
        let extras: [String] = [
            "\(home)/.local/bin",
            "\(home)/.pyenv/shims",
            "\(home)/Library/Python/3.13/bin",
            "\(home)/Library/Python/3.12/bin",
            "\(home)/Library/Python/3.11/bin",
            "\(home)/Library/Python/3.10/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/homebrew/opt/python@3.12/bin",
            "/opt/homebrew/opt/python@3.11/bin",
            "/usr/local/opt/python@3.12/bin",
            "/usr/local/opt/python@3.11/bin",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin",
        ]
        for dir in extras {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Candidate repo roots. Tries:
    ///   1. `PIANO_TRAINER_ROOT` env var (escape hatch for tests / dev).
    ///   2. Source-file location (relative to this file when running from
    ///      a swift-package build).
    ///   3. Process working directory and its ancestors (good enough for
    ///      `swift run` / `swift test` invocations).
    ///   4. The bundle's enclosing directory walked upward (covers the
    ///      release `Piano Trainer.app` next to the repo).
    private static func candidateRepoRoots() -> [URL] {
        var roots: [URL] = []
        if let envRoot = ProcessInfo.processInfo.environment["PIANO_TRAINER_ROOT"],
           !envRoot.isEmpty {
            roots.append(URL(fileURLWithPath: envRoot))
        }
        // Walk up from #file. `swift build` keeps source files in their
        // original location even from a swift-package binary, so this finds
        // the repo when running tests or `swift run`.
        let here = URL(fileURLWithPath: #file)
        roots.append(contentsOf: ancestors(of: here))
        // Walk up from CWD.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        roots.append(contentsOf: ancestors(of: cwd))
        // Walk up from Bundle.main (covers the released `.app` bundle).
        let bundleDir = URL(fileURLWithPath: Bundle.main.bundlePath)
        roots.append(contentsOf: ancestors(of: bundleDir))
        return roots
    }

    private static func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var u = url
        for _ in 0 ..< 10 {
            u = u.deletingLastPathComponent()
            if u.path == "/" { break }
            result.append(u)
        }
        return result
    }

    /// Run `executable` with `arguments`. Captures stdout and stderr.
    /// Throws `CommandError.nonZeroExit` if the tool exits non-zero unless
    /// `allowNonZeroExit` is true.
    @discardableResult
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        allowNonZeroExit: Bool = false,
        displayName: String? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(error.localizedDescription)
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let result = Result(
            exitStatus: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )

        if !allowNonZeroExit, process.terminationStatus != 0 {
            throw CommandError.nonZeroExit(
                name: displayName ?? executable.lastPathComponent,
                status: process.terminationStatus,
                stderr: result.stderr
            )
        }
        return result
    }
}
