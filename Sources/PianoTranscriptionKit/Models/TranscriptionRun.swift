import Foundation
import os

public struct TranscriptionRun: Codable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let pipelineVersion: String
    public let modelName: String
    public var notes: [MIDINote]
    public var label: String

    /// Stable identifier for the pipeline that produced this run (PipelineKind.rawValue).
    public let pipelineID: String
    /// Human-readable display name of the pipeline at the time the run was produced.
    public let pipelineName: String
    /// Optional model version string when the runner exposes one.
    public let modelVersion: String?
    /// Snapshot of the pipeline's tuning parameters, captured at run time.
    public let pipelineParameters: [String: String]
    /// True when the pipeline applied source separation (e.g. piano isolation) before transcription.
    public let usedSourceSeparation: Bool
    /// Path of the audio file fed into the pipeline (the project's extracted WAV by default).
    public let inputAudioPath: String?
    /// Path of the isolated piano stem if `usedSourceSeparation` is true.
    public let isolatedStemPath: String?

    /// Raw model output before post-processing. `notes` is the cleaned form
    /// that drives playback / export. When the pipeline ran without cleanup
    /// (legacy or test paths), `rawNotes` is empty and callers should fall
    /// back to `notes`.
    public let rawNotes: [MIDINote]
    /// Summary of what `TranscriptionCleanup` removed/clamped. `nil` for
    /// runs that pre-date the cleanup step.
    public let cleanupReport: TranscriptionCleanup.Report?
    /// Authoritative source-audio duration in seconds at run time. Used by
    /// diagnostics so timeline drift is measured against the real source,
    /// not a recomputed file open.
    public let sourceAudioDuration: Double?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        pipelineVersion: String,
        modelName: String,
        notes: [MIDINote],
        label: String = "",
        pipelineID: String = "",
        pipelineName: String = "",
        modelVersion: String? = nil,
        pipelineParameters: [String: String] = [:],
        usedSourceSeparation: Bool = false,
        inputAudioPath: String? = nil,
        isolatedStemPath: String? = nil,
        rawNotes: [MIDINote] = [],
        cleanupReport: TranscriptionCleanup.Report? = nil,
        sourceAudioDuration: Double? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pipelineVersion = pipelineVersion
        self.modelName = modelName
        self.notes = notes
        self.label = label.isEmpty ? DateFormatter.localizedString(from: createdAt, dateStyle: .short, timeStyle: .medium) : label
        self.pipelineID = pipelineID
        self.pipelineName = pipelineName.isEmpty ? modelName : pipelineName
        self.modelVersion = modelVersion
        self.pipelineParameters = pipelineParameters
        self.usedSourceSeparation = usedSourceSeparation
        self.inputAudioPath = inputAudioPath
        self.isolatedStemPath = isolatedStemPath
        self.rawNotes = rawNotes
        self.cleanupReport = cleanupReport
        self.sourceAudioDuration = sourceAudioDuration
    }

    public var duration: Double {
        notes.map { $0.onset + $0.duration }.max() ?? 0
    }

    /// Mandatory-cleanup factory. Every pipeline path that builds a
    /// `TranscriptionRun` from raw model output must call this — no
    /// pipeline can produce a run that bypasses cleanup, even by accident,
    /// because the broken catastrophic numbers (218s notes, 2208 notes,
    /// 60 stuck notes) in the field were caused by exactly that drift.
    ///
    /// The factory:
    ///   1. Forces `cleanupConfig.audioDurationSeconds = audioDurationSeconds`
    ///   2. Runs `TranscriptionCleanup.apply` so safety stages are guaranteed
    ///   3. Stores the *raw* and *cleaned* note arrays, plus the report
    ///   4. Logs the raw → cleaned counts via `os.Logger` so the data flow
    ///      is visible in Console / Xcode logs
    public static func makeWithMandatoryCleanup(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawModelNotes: [MIDINote],
        audioDurationSeconds: Double?,
        pipelineVersion: String,
        modelName: String,
        label: String = "",
        pipelineID: String,
        pipelineName: String,
        modelVersion: String? = nil,
        pipelineParameters: [String: String] = [:],
        usedSourceSeparation: Bool = false,
        inputAudioPath: String? = nil,
        isolatedStemPath: String? = nil,
        cleanupConfig: TranscriptionCleanup.Config = .mandatory
    ) -> TranscriptionRun {
        var cfg = cleanupConfig
        cfg.audioDurationSeconds = audioDurationSeconds
        let outcome = TranscriptionCleanup.apply(rawModelNotes, config: cfg)
        let maxDur = outcome.cleaned.map(\.duration).max() ?? 0
        TranscriptionRunLog.log.info(
            "run \(id.uuidString, privacy: .public) pipeline=\(pipelineName, privacy: .public) model=\(modelName, privacy: .public) raw=\(rawModelNotes.count) cleaned=\(outcome.cleaned.count) maxDur=\(String(format: "%.2f", maxDur))s audio=\(audioDurationSeconds.map { String(format: "%.2f", $0) } ?? "?", privacy: .public)s removed=\(outcome.report.totalRemoved)"
        )
        var params = pipelineParameters
        params["mandatoryCleanup.applied"] = "true"
        params["mandatoryCleanup.rawCount"] = "\(rawModelNotes.count)"
        params["mandatoryCleanup.cleanedCount"] = "\(outcome.cleaned.count)"
        params["mandatoryCleanup.totalRemoved"] = "\(outcome.report.totalRemoved)"
        params["mandatoryCleanup.maxNoteDur"] = String(format: "%.4f", maxDur)
        return TranscriptionRun(
            id: id,
            createdAt: createdAt,
            pipelineVersion: pipelineVersion,
            modelName: modelName,
            notes: outcome.cleaned,
            label: label,
            pipelineID: pipelineID,
            pipelineName: pipelineName,
            modelVersion: modelVersion,
            pipelineParameters: params,
            usedSourceSeparation: usedSourceSeparation,
            inputAudioPath: inputAudioPath,
            isolatedStemPath: isolatedStemPath,
            rawNotes: outcome.raw,
            cleanupReport: outcome.report,
            sourceAudioDuration: audioDurationSeconds
        )
    }

    public var noteCount: Int { notes.count }

    public var pitchRange: ClosedRange<Int>? {
        guard !notes.isEmpty else { return nil }
        let pitches = notes.map(\.pitch)
        return pitches.min()!...pitches.max()!
    }

    // MARK: - Backwards-compatible Codable
    //
    // Earlier versions of this struct only persisted the first six fields; the
    // pipeline metadata block was added later. Custom decoding keeps old
    // project.json files loadable by defaulting any missing keys.

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, pipelineVersion, modelName, notes, label
        case pipelineID, pipelineName, modelVersion, pipelineParameters
        case usedSourceSeparation, inputAudioPath, isolatedStemPath
        case rawNotes, cleanupReport, sourceAudioDuration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let createdAt = try c.decode(Date.self, forKey: .createdAt)
        let pipelineVersion = try c.decode(String.self, forKey: .pipelineVersion)
        let modelName = try c.decode(String.self, forKey: .modelName)
        let notes = try c.decode([MIDINote].self, forKey: .notes)
        let label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        let pipelineID = try c.decodeIfPresent(String.self, forKey: .pipelineID) ?? ""
        let pipelineName = try c.decodeIfPresent(String.self, forKey: .pipelineName) ?? ""
        let modelVersion = try c.decodeIfPresent(String.self, forKey: .modelVersion)
        let params = try c.decodeIfPresent([String: String].self, forKey: .pipelineParameters) ?? [:]
        let usedSep = try c.decodeIfPresent(Bool.self, forKey: .usedSourceSeparation) ?? false
        let inputPath = try c.decodeIfPresent(String.self, forKey: .inputAudioPath)
        let stemPath = try c.decodeIfPresent(String.self, forKey: .isolatedStemPath)
        let raw = try c.decodeIfPresent([MIDINote].self, forKey: .rawNotes) ?? []
        let report = try c.decodeIfPresent(TranscriptionCleanup.Report.self, forKey: .cleanupReport)
        let srcDur = try c.decodeIfPresent(Double.self, forKey: .sourceAudioDuration)

        self.init(
            id: id,
            createdAt: createdAt,
            pipelineVersion: pipelineVersion,
            modelName: modelName,
            notes: notes,
            label: label,
            pipelineID: pipelineID,
            pipelineName: pipelineName,
            modelVersion: modelVersion,
            pipelineParameters: params,
            usedSourceSeparation: usedSep,
            inputAudioPath: inputPath,
            isolatedStemPath: stemPath,
            rawNotes: raw,
            cleanupReport: report,
            sourceAudioDuration: srcDur
        )
    }
}
