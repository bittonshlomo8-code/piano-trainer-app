import Foundation

/// Conservative cleanup applied to raw piano notes produced from mixed-audio
/// stems. The processor never invents notes and never shifts onsets backward;
/// every transform is auditable through `MixedAudioPostProcessor.Report`.
///
/// Each pass returns *what changed* alongside the new note set so the
/// pipeline's diagnostics can explain why output looks the way it does
/// instead of silently swallowing edge cases.
public struct MixedAudioPostProcessor: Sendable {

    public struct Config: Sendable, Equatable {
        /// Velocity below which a note is considered a ghost (mixed-audio
        /// detectors leak harmonic energy from non-piano sources).
        public var ghostMinVelocity: Int
        /// Notes shorter than this are dropped unconditionally.
        public var minDuration: Double
        /// Maximum number of simultaneous note onsets at the same timestamp.
        /// Mixed audio frequently fires "burst" detections from drum hits or
        /// vocal sibilance — anything past this count is pruned by velocity.
        public var maxBurstCount: Int
        /// Same-pitch overlap collapse threshold. Two same-pitch notes whose
        /// time ranges overlap by more than this fraction of the shorter
        /// note are merged.
        public var overlapMergeFraction: Double
        /// Hard ceiling on note duration (seconds) — anything past this is
        /// flagged and clamped, since detector glitches in mixed audio love
        /// to produce 60s+ stuck notes from background drone.
        public var maxNoteDuration: Double
        /// Notes longer than this but shorter than `maxNoteDuration` are
        /// kept as-is and surfaced in diagnostics so a human can audit them.
        public var longNoteWarnThreshold: Double
        /// Same-pitch notes separated by less than this gap (seconds) and
        /// with comparable velocity are merged into a single sustained note.
        public var sustainMergeGap: Double
        /// Allow octave correction only when at least this many same-pitch
        /// neighbours exist one octave away with stronger evidence.
        public var octaveCorrectionMinNeighbours: Int
        /// Velocity smoothing weight in [0, 1] toward the median of the
        /// surrounding 5-note window. 0 disables smoothing.
        public var velocitySmoothingWeight: Double

        public init(
            ghostMinVelocity: Int = 18,
            minDuration: Double = 0.06,
            maxBurstCount: Int = 8,
            overlapMergeFraction: Double = 0.6,
            maxNoteDuration: Double = 12.0,
            longNoteWarnThreshold: Double = 6.0,
            sustainMergeGap: Double = 0.18,
            octaveCorrectionMinNeighbours: Int = 3,
            velocitySmoothingWeight: Double = 0.25
        ) {
            self.ghostMinVelocity = ghostMinVelocity
            self.minDuration = minDuration
            self.maxBurstCount = maxBurstCount
            self.overlapMergeFraction = overlapMergeFraction
            self.maxNoteDuration = maxNoteDuration
            self.longNoteWarnThreshold = longNoteWarnThreshold
            self.sustainMergeGap = sustainMergeGap
            self.octaveCorrectionMinNeighbours = octaveCorrectionMinNeighbours
            self.velocitySmoothingWeight = velocitySmoothingWeight
        }

        /// Conservative defaults — fewer false positives, more sustain.
        public static let `default` = Config()

        public var asParameters: [String: String] {
            [
                "ghostMinVelocity": "\(ghostMinVelocity)",
                "minDuration": String(format: "%.4f", minDuration),
                "maxBurstCount": "\(maxBurstCount)",
                "overlapMergeFraction": String(format: "%.4f", overlapMergeFraction),
                "maxNoteDuration": String(format: "%.4f", maxNoteDuration),
                "longNoteWarnThreshold": String(format: "%.4f", longNoteWarnThreshold),
                "sustainMergeGap": String(format: "%.4f", sustainMergeGap),
                "octaveCorrectionMinNeighbours": "\(octaveCorrectionMinNeighbours)",
                "velocitySmoothingWeight": String(format: "%.4f", velocitySmoothingWeight),
            ]
        }
    }

    /// Per-stage counters returned from `process(_:)` so the caller can
    /// surface them in diagnostics without re-deriving them.
    public struct Report: Sendable, Equatable {
        public var ghostsDropped: Int = 0
        public var shortDropped: Int = 0
        public var burstPruned: Int = 0
        public var overlapMerged: Int = 0
        public var sustainMerged: Int = 0
        public var clampedLongNotes: Int = 0
        public var longNoteWarnings: Int = 0
        public var octaveCorrections: Int = 0
        public var velocitySmoothed: Int = 0
    }

    public let config: Config

    public init(config: Config = .default) {
        self.config = config
    }

    /// Run all stages. Stages are independent and ordered from
    /// "must drop garbage" to "tighten valid notes".
    public func process(_ notes: [MIDINote]) -> (notes: [MIDINote], report: Report) {
        var report = Report()
        var current = notes

        current = dropGhosts(current, report: &report)
        current = dropShort(current, report: &report)
        current = limitBursts(current, report: &report)
        current = collapseOverlaps(current, report: &report)
        current = mergeSustain(current, report: &report)
        current = clampLongNotes(current, report: &report)
        current = correctOctaves(current, report: &report)
        current = smoothVelocities(current, report: &report)

        current.sort { $0.onset < $1.onset }
        return (current, report)
    }

    // MARK: - Stages

    func dropGhosts(_ notes: [MIDINote], report: inout Report) -> [MIDINote] {
        var kept: [MIDINote] = []
        kept.reserveCapacity(notes.count)
        for n in notes {
            if n.velocity < config.ghostMinVelocity {
                report.ghostsDropped += 1
            } else {
                kept.append(n)
            }
        }
        return kept
    }

    func dropShort(_ notes: [MIDINote], report: inout Report) -> [MIDINote] {
        var kept: [MIDINote] = []
        kept.reserveCapacity(notes.count)
        for n in notes {
            if n.duration < config.minDuration {
                report.shortDropped += 1
            } else {
                kept.append(n)
            }
        }
        return kept
    }

    /// Keep at most `maxBurstCount` notes per shared onset bucket (8 ms).
    /// When more notes share a timestamp, drop the lowest-velocity ones.
    func limitBursts(_ notes: [MIDINote], report: inout Report) -> [MIDINote] {
        guard config.maxBurstCount > 0 else { return notes }
        let bucket = 0.008
        let grouped = Dictionary(grouping: notes) { Int(($0.onset / bucket).rounded()) }
        var kept: [MIDINote] = []
        kept.reserveCapacity(notes.count)
        for (_, bucketNotes) in grouped {
            if bucketNotes.count <= config.maxBurstCount {
                kept.append(contentsOf: bucketNotes)
            } else {
                let sorted = bucketNotes.sorted { $0.velocity > $1.velocity }
                kept.append(contentsOf: sorted.prefix(config.maxBurstCount))
                report.burstPruned += sorted.count - config.maxBurstCount
            }
        }
        return kept
    }

    /// Merge same-pitch notes that overlap by more than
    /// `overlapMergeFraction` of the shorter note's duration. Avoids the
    /// "same note triggered twice almost on top of each other" pattern.
    func collapseOverlaps(_ notes: [MIDINote], report: inout Report) -> [MIDINote] {
        guard notes.count > 1 else { return notes }
        let sorted = notes.sorted { $0.onset < $1.onset }
        var byPitch: [Int: [MIDINote]] = [:]
        for n in sorted { byPitch[n.pitch, default: []].append(n) }
        var out: [MIDINote] = []
        for (_, list) in byPitch {
            var current = list[0]
            for next in list.dropFirst() {
                let curEnd = current.onset + current.duration
                let overlap = curEnd - next.onset
                let shorter = min(current.duration, next.duration)
                if overlap > 0, shorter > 0,
                   (overlap / shorter) >= config.overlapMergeFraction {
                    let end = max(curEnd, next.onset + next.duration)
                    current = MIDINote(
                        pitch: current.pitch,
                        onset: current.onset,
                        duration: end - current.onset,
                        velocity: max(current.velocity, next.velocity)
                    )
                    report.overlapMerged += 1
                } else {
                    out.append(current)
                    current = next
                }
            }
            out.append(current)
        }
        return out.sorted { $0.onset < $1.onset }
    }

    /// Merge consecutive same-pitch notes when the gap is short and the
    /// velocity is comparable — this preserves real sustained notes that
    /// the detector sliced into pieces.
    func mergeSustain(_ notes: [MIDINote], report: inout Report) -> [MIDINote] {
        guard notes.count > 1 else { return notes }
        let sorted = notes.sorted { $0.onset < $1.onset }
        var out: [MIDINote] = []
        var cur = sorted[0]
        for next in sorted.dropFirst() {
            let gap = next.onset - (cur.onset + cur.duration)
            let velRatio = Double(min(cur.velocity, next.velocity)) /
                           Double(max(cur.velocity, next.velocity))
            if next.pitch == cur.pitch,
               gap >= 0,
               gap <= config.sustainMergeGap,
               velRatio >= 0.6 {
                cur = MIDINote(
                    pitch: cur.pitch,
                    onset: cur.onset,
                    duration: next.onset + next.duration - cur.onset,
                    velocity: max(cur.velocity, next.velocity)
                )
                report.sustainMerged += 1
            } else {
                out.append(cur)
                cur = next
            }
        }
        out.append(cur)
        return out
    }

    /// Hard cap for runaway durations. Notes between `longNoteWarnThreshold`
    /// and `maxNoteDuration` are kept as-is but counted as warnings.
    func clampLongNotes(_ notes: [MIDINote], report: inout Report) -> [MIDINote] {
        var out: [MIDINote] = []
        out.reserveCapacity(notes.count)
        for n in notes {
            if n.duration > config.maxNoteDuration {
                out.append(MIDINote(
                    id: n.id,
                    pitch: n.pitch,
                    onset: n.onset,
                    duration: config.maxNoteDuration,
                    velocity: n.velocity
                ))
                report.clampedLongNotes += 1
                report.longNoteWarnings += 1
            } else {
                if n.duration > config.longNoteWarnThreshold {
                    report.longNoteWarnings += 1
                }
                out.append(n)
            }
        }
        return out
    }

    /// Correct very-low / very-high octave outliers ONLY when the bulk of
    /// surrounding notes sit one octave higher (or lower) and are stronger.
    /// Mixed-audio detectors often pick A1 instead of A4 because subharmonic
    /// salience aliases line up — but we don't move pitches without
    /// strong supporting evidence.
    func correctOctaves(_ notes: [MIDINote], report: inout Report) -> [MIDINote] {
        guard notes.count > config.octaveCorrectionMinNeighbours else { return notes }
        var out = notes
        let pitches = notes.map(\.pitch)
        let counts = Dictionary(pitches.map { ($0, 1) }, uniquingKeysWith: +)
        for (idx, note) in notes.enumerated() {
            // Only consider extreme octaves: piano range bottom (≤ 35) or top (≥ 96).
            if note.pitch <= 35 || note.pitch >= 96 {
                let upOct = note.pitch + 12
                let downOct = note.pitch - 12
                let upN = counts[upOct] ?? 0
                let downN = counts[downOct] ?? 0
                let neighbours = max(upN, downN)
                guard neighbours >= config.octaveCorrectionMinNeighbours else { continue }
                // Move only if the neighbour has stronger maximum velocity.
                let neighbourVels = notes.filter { $0.pitch == (upN >= downN ? upOct : downOct) }
                                         .map(\.velocity)
                guard let strong = neighbourVels.max(), strong > note.velocity else { continue }
                let target = upN >= downN ? upOct : downOct
                out[idx] = MIDINote(
                    id: note.id,
                    pitch: target,
                    onset: note.onset,
                    duration: note.duration,
                    velocity: note.velocity
                )
                report.octaveCorrections += 1
            }
        }
        return out
    }

    /// Pull each note's velocity a fraction of the way toward the median of
    /// its 5-note same-pitch neighbourhood so we kill spike outliers without
    /// flattening real dynamics.
    func smoothVelocities(_ notes: [MIDINote], report: inout Report) -> [MIDINote] {
        guard config.velocitySmoothingWeight > 0 else { return notes }
        let weight = max(0, min(1, config.velocitySmoothingWeight))
        let byPitch = Dictionary(grouping: notes, by: \.pitch)
        var indexed: [UUID: Int] = [:]
        for (_, list) in byPitch {
            let velocities = list.map(\.velocity).sorted()
            for note in list {
                let median = velocities[velocities.count / 2]
                let blended = Int(round(Double(note.velocity) * (1 - weight) + Double(median) * weight))
                let clamped = max(1, min(127, blended))
                if clamped != note.velocity {
                    indexed[note.id] = clamped
                }
            }
        }
        report.velocitySmoothed += indexed.count
        return notes.map { n in
            guard let v = indexed[n.id] else { return n }
            return MIDINote(id: n.id, pitch: n.pitch, onset: n.onset, duration: n.duration, velocity: v)
        }
    }
}
