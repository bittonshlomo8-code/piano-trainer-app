import SwiftUI
import PianoTranscriptionKit

/// Right-hand inspector. Wires together:
///   • project navigation/back
///   • playback controls + mode picker
///   • transcription view filters
///   • pipeline controls (re-run / export / delete)
///   • piano-isolation placeholders (disabled, with helper text)
///   • collapsible debug diagnostics
struct InspectorSidebarView: View {
    @ObservedObject var vm: ProjectViewModel
    @ObservedObject var playback: PlaybackViewModel
    @Binding var filter: NoteDisplayFilter
    @Binding var isolationOn: Bool
    @Binding var muteBackgroundInstruments: Bool
    @Binding var reduceBackgroundNoise: Bool
    var onBack: () -> Void
    var onDelete: () -> Void
    /// Ask the parent to present the pipeline picker for a fresh run.
    var onRequestRerunPicker: () -> Void

    @State private var showDebug = false
    @State private var diagnosticsView: DiagnosticsView = .cleaned
    private let registry = PipelineRegistry.shared

    enum DiagnosticsView: String, CaseIterable, Identifiable {
        case cleaned, raw
        var id: String { rawValue }
        var label: String { self == .cleaned ? "Cleaned" : "Raw" }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                navSection
                Divider()
                evaluationCycleSection
                Divider()
                playbackSection
                Divider()
                transcriptionViewSection
                Divider()
                pipelineSection
                Divider()
                runDiagnosticsSection
                if vm.project.runs.count >= 2 {
                    Divider()
                    runComparisonSection
                }
                Divider()
                isolationSection
                Divider()
                dataFlowSection
                Divider()
                debugSection
            }
            .padding(14)
        }
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
        .background(.regularMaterial)
    }

    // MARK: - Computed analysis (memoization-light: SwiftUI re-evaluates only when inputs change)

    private var currentAnalysis: TranscriptionAnalysis? {
        guard let run = vm.selectedRun else { return nil }
        let notes = (diagnosticsView == .raw && !run.rawNotes.isEmpty) ? run.rawNotes : run.notes
        guard !notes.isEmpty else { return nil }
        let audio = run.sourceAudioDuration
                 ?? (playback.audioDuration > 0 ? playback.audioDuration : nil)
        return TranscriptionDiagnostics.analyze(notes: notes, audioDuration: audio)
    }

    /// True when the run has both raw and cleaned snapshots so the toggle
    /// is meaningful.
    private var hasRawAndCleaned: Bool {
        guard let run = vm.selectedRun else { return false }
        return !run.rawNotes.isEmpty && run.cleanupReport != nil
    }

    private var comparison: RunComparison {
        RunComparison.compare(
            runs: vm.project.runs,
            audioDuration: playback.audioDuration > 0 ? playback.audioDuration : nil
        )
    }

    // MARK: - Sections

    private var navSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onBack) {
                Label("Back to Projects", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Text(vm.project.name)
                .font(.title3.bold())
                .lineLimit(2)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                metadataRow("Duration", value: timeString(playback.duration))
                metadataRow("Notes", value: "\(vm.selectedRun?.noteCount ?? 0)")
                if let run = vm.selectedRun {
                    metadataRow("Run", value: run.label)
                    let pipelineLabel = run.pipelineName.isEmpty ? run.modelName : run.pipelineName
                    metadataRow("Pipeline", value: pipelineLabel)
                    metadataRow("Model", value: run.modelName)
                    // Honest "what actually ran" line — distinguishes the
                    // dedicated external model from a Piano-Focused fallback
                    // execution.
                    HStack(spacing: 4) {
                        Text("Backend ran")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(run.backendRan)
                            .font(.caption.monospacedDigit())
                        if run.ranOnFallback {
                            Text("Fallback")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.20), in: Capsule())
                                .foregroundStyle(Color.orange)
                        } else if run.backendKind == "dedicated" {
                            Text("Dedicated")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.20), in: Capsule())
                                .foregroundStyle(Color.green)
                        }
                    }
                    if run.usedSourceSeparation {
                        metadataRow("Source sep.", value: "yes")
                    }
                }
            }

            if vm.selectedRun != nil {
                Button {
                    if let run = vm.selectedRun { _ = vm.promptExportMIDI(for: run) }
                } label: {
                    Label("Export Selected Run…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(vm.isRunning)
            }
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Playback")

            Picker("Mode", selection: $playback.mode) {
                ForEach(PlaybackViewModel.Mode.allCases) { m in
                    Label(m.displayName, systemImage: m.systemImage).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                Button {
                    playback.isPlaying ? playback.pause() : playback.play()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(" ", modifiers: [])
                .help(playback.isPlaying ? "Pause (Space)" : "Play (Space)")
                .disabled(playback.duration <= 0)

                Button { playback.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .help("Stop")

                Spacer()

                Text(timeString(playback.currentTime) + " / " + timeString(playback.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(1, playback.duration)
            )
        }
    }

    private var transcriptionViewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Transcription View")

            Toggle("Show raw notes (debug)", isOn: $filter.showRaw)
                .controlSize(.small)
                .help("Bypass all view filters and show every note from the run.")

            Group {
                labeledSlider(
                    "Confidence threshold",
                    value: Binding(
                        get: { Double(filter.minVelocity) },
                        set: { filter.minVelocity = Int($0) }
                    ),
                    in: 0...127,
                    valueText: "\(filter.minVelocity)/127"
                )

                labeledSlider(
                    "Min note duration",
                    value: $filter.minDuration,
                    in: 0...0.5,
                    valueText: String(format: "%.2fs", filter.minDuration)
                )

                Toggle("Hide very short notes (<60ms)", isOn: $filter.hideVeryShort)
                    .controlSize(.small)

                labeledSlider(
                    "Velocity scale",
                    value: $filter.velocityScale,
                    in: 0.25...2.0,
                    valueText: String(format: "%.2f×", filter.velocityScale)
                )
            }
            .disabled(filter.showRaw)
            .opacity(filter.showRaw ? 0.5 : 1.0)
        }
    }

    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Pipeline")

            HStack(spacing: 6) {
                Image(systemName: vm.pipelineKind.systemImage)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vm.pipelineKind.displayName)
                        .font(.caption.weight(.medium))
                    Text(vm.pipelineKind.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("Pipeline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $vm.pipelineKind) {
                    ForEach(PipelineKind.userVisibleCases) { kind in
                        let onFallback = !registry.hasDedicatedBackend(kind)
                        Text(kind.displayName + (onFallback ? " · fallback" : "")).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(vm.isRunning)
            }

            Button {
                Task { await vm.runTranscription() }
            } label: {
                Label(vm.project.runs.isEmpty ? "Run Transcription" : "Re-run Transcription",
                      systemImage: "waveform.badge.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(vm.isRunning)

            if let reason = registry.fallbackReason(vm.pipelineKind) {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !vm.project.runs.isEmpty {
                Button(action: onRequestRerunPicker) {
                    Label("Run with different pipeline…", systemImage: "rectangle.stack.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(vm.isRunning)
            }

            Button {
                if let run = vm.selectedRun { _ = vm.promptExportMIDI(for: run) }
            } label: {
                Label("Export MIDI…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(vm.selectedRun == nil || vm.isRunning)

            Button(role: .destructive, action: onDelete) {
                Label("Delete Project", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Evaluation cycle (6 stages)

    private var evaluationCycleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Evaluation Cycle")
            Text("Verify each stage before changing the model.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            evalStage(1, "Original input audio",
                      done: playback.audioDuration > 0,
                      hint: playback.loadedAudioURL?.lastPathComponent ?? "no audio loaded")
            evalStage(2, "Generated MIDI notes",
                      done: vm.selectedRun != nil,
                      hint: vm.selectedRun.map { "\($0.noteCount) notes" } ?? "no run yet")
            evalStage(3, "Rendered MIDI playback",
                      done: playback.midiDuration > 0,
                      hint: timeString(playback.midiDuration))
            evalStage(4, "Visual piano roll",
                      done: vm.selectedRun?.notes.isEmpty == false,
                      hint: vm.selectedRun.map { "rendered \($0.noteCount) notes" } ?? "—")
            evalStage(5, "Diagnostics",
                      done: currentAnalysis != nil,
                      hint: currentAnalysis.map { "status: \($0.status.rawValue)" } ?? "no run")
            evalStage(6, "Comparison vs prior run",
                      done: vm.project.runs.count >= 2,
                      hint: vm.project.runs.count >= 2 ? "\(vm.project.runs.count) runs" : "need ≥2 runs")
        }
    }

    @ViewBuilder
    private func evalStage(_ n: Int, _ label: String, done: Bool, hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "\(n).circle.fill" : "\(n).circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.caption)
            Text(label).font(.caption)
            Spacer()
            Text(hint)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Run diagnostics

    private var runDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Run Diagnostics")
                Spacer()
                if let analysis = currentAnalysis {
                    statusBadge(analysis.status)
                }
            }

            // Raw ↔ Cleaned toggle (only when the run has both snapshots).
            if hasRawAndCleaned {
                Picker("View", selection: $diagnosticsView) {
                    ForEach(DiagnosticsView.allCases) { v in
                        Text(v.label).tag(v)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Cleanup before/after summary
            if let report = vm.selectedRun?.cleanupReport {
                cleanupSummaryView(report)
            }

            if let analysis = currentAnalysis {
                diagnosticsBody(analysis)
            } else {
                Text("Run a transcription to see diagnostics.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func cleanupSummaryView(_ r: TranscriptionCleanup.Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Post-processing")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(r.inputCount) → \(r.outputCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Each non-zero counter as a chip
            FlowingChips(items: [
                ("clamped to audio", r.clampedToAudioDuration),
                ("dropped long", r.droppedLongNotes),
                ("clamped long", r.clampedLongNotes),
                ("cluster prune", r.prunedFromClusters),
                ("density prune", r.prunedFromDensity),
                ("exact pileup", r.prunedExactPileup),
                ("trim overlap", r.trimmedSamePitchOverlap),
                ("merged overlap", r.mergedSamePitchOverlap),
                ("sustain ghost", r.droppedSustainGhost),
                ("sustain merge", r.mergedSustainFragments),
                ("dropped 0/neg", r.droppedZeroDuration + r.droppedNegativeDuration),
            ].filter { $0.1 > 0 })
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private func diagnosticsBody(_ a: TranscriptionAnalysis) -> some View {
        // Quality score bar
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Quality score").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f / 100", a.qualityScore * 100))
                    .font(.caption.monospacedDigit())
            }
            ProgressView(value: a.qualityScore)
                .tint(qualityTint(a.qualityScore))
        }

        // Stats grid
        VStack(alignment: .leading, spacing: 2) {
            statRow("Notes", "\(a.stats.totalNotes)")
            statRow("Run duration", String(format: "%.2fs", a.stats.runDuration))
            if let ad = a.stats.audioDuration {
                statRow("Audio duration", String(format: "%.2fs", ad))
            }
            statRow("Notes / sec", String(format: "%.2f", a.stats.notesPerSecond))
            if let lo = a.stats.minPitch, let hi = a.stats.maxPitch {
                statRow("Pitch range", "\(lo)…\(hi)")
            }
            statRow("Median duration", String(format: "%.3fs", a.stats.medianDuration))
            statRow("Max duration", String(format: "%.2fs", a.stats.maxDuration))
            statRow("Median velocity", "\(a.stats.medianVelocity)")
            statRow("Avg confidence (vel)", String(format: "%.1f / 127", a.stats.avgVelocity))
        }

        // Issues
        if !a.issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Detected issues").font(.caption.weight(.medium))
                ForEach(a.issues) { issue in
                    issueRow(issue)
                }
            }
        }

        // Octave histogram
        if !a.stats.octaveHistogram.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Octave histogram").font(.caption.weight(.medium))
                octaveHistogramView(a.stats.octaveHistogram)
            }
        }

        // Density chart
        if !a.densityBuckets.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Note density (per second)").font(.caption.weight(.medium))
                densityChart(a.densityBuckets)
            }
        }

        // Longest notes table
        if !a.longestNotes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Longest notes").font(.caption.weight(.medium))
                ForEach(a.longestNotes.indices, id: \.self) { i in
                    let n = a.longestNotes[i]
                    HStack {
                        Text("p\(n.pitch)").font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2fs @ %.2fs", n.duration, n.onset))
                            .font(.caption2.monospacedDigit())
                        Spacer()
                        Text("v\(n.velocity)").font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }

        // Suspicious clusters table
        if !a.suspiciousClusters.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Suspicious onset clusters").font(.caption.weight(.medium))
                ForEach(a.suspiciousClusters.indices, id: \.self) { i in
                    let c = a.suspiciousClusters[i]
                    HStack {
                        Text(String(format: "%.2fs", c.onsetSeconds))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(c.noteCount) notes")
                            .font(.caption2)
                        Spacer()
                        Text(c.pitches.prefix(6).map { "\($0)" }.joined(separator: ","))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func issueRow(_ issue: TranscriptionAnalysis.Issue) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: issue.severity == .fail
                  ? "xmark.octagon.fill"
                  : (issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                .foregroundStyle(issue.severity == .fail ? .red
                                 : (issue.severity == .warning ? .orange : .blue))
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(issue.title).font(.caption.weight(.medium))
                    Spacer()
                    Text("×\(issue.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(issue.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func octaveHistogramView(_ hist: [Int: Int]) -> some View {
        let sorted = hist.sorted { $0.key < $1.key }
        let maxCount = max(1, sorted.map(\.value).max() ?? 1)
        VStack(spacing: 2) {
            ForEach(sorted, id: \.key) { entry in
                HStack(spacing: 4) {
                    Text("Oct \(entry.key)")
                        .font(.caption2.monospacedDigit())
                        .frame(width: 44, alignment: .leading)
                        .foregroundStyle(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.15))
                            Rectangle()
                                .fill(.blue.opacity(0.7))
                                .frame(width: geo.size.width * CGFloat(entry.value) / CGFloat(maxCount))
                        }
                    }
                    .frame(height: 8)
                    Text("\(entry.value)")
                        .font(.caption2.monospacedDigit())
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func densityChart(_ buckets: [TranscriptionAnalysis.DensityBucket]) -> some View {
        let maxCount = max(1, buckets.map(\.noteCount).max() ?? 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(buckets.indices, id: \.self) { i in
                    let h = CGFloat(buckets[i].noteCount) / CGFloat(maxCount) * geo.size.height
                    Rectangle()
                        .fill(buckets[i].noteCount >= 25 ? Color.red.opacity(0.8) : Color.green.opacity(0.7))
                        .frame(height: max(1, h))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 40)
    }

    // MARK: - Pipeline comparison

    private var runComparisonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Pipeline Comparison")
            let rows = comparison.rows
            if rows.isEmpty {
                Text("No runs to compare.").font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in
                        comparisonRow(row, isSelected: row.runID == vm.selectedRunID)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func comparisonRow(_ row: RunComparison.Row, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                statusBadge(row.status)
                Text(row.pipelineName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(String(format: "Q %.0f", row.qualityScore * 100))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(qualityTint(row.qualityScore).opacity(0.25), in: Capsule())
            }
            Text(row.label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                compStat("notes", "\(row.noteCount)")
                compStat("avg vel", String(format: "%.0f", row.avgVelocity))
                compStat("ghost", "\(row.ghostNoteWarnings)")
                compStat("long", "\(row.longNoteWarnings)")
            }
            // Octave fingerprint (mini histogram)
            HStack(spacing: 1) {
                let maxC = max(1, row.octaveHistogram.values.max() ?? 1)
                ForEach((0...10), id: \.self) { oct in
                    let c = row.octaveHistogram[oct] ?? 0
                    Rectangle()
                        .fill(Color.blue.opacity(0.6))
                        .frame(width: 6, height: max(1, CGFloat(c) / CGFloat(maxC) * 16))
                        .frame(height: 16, alignment: .bottom)
                }
            }
            .frame(height: 16)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue.opacity(0.5) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { vm.selectedRunID = row.runID }
    }

    private func compStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.caption2.monospacedDigit().weight(.medium))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Status badge

    private func statusBadge(_ status: TranscriptionAnalysis.Status) -> some View {
        let (text, color) = statusBadgeStyle(status)
        return Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.20), in: Capsule())
            .foregroundStyle(color)
    }

    private func statusBadgeStyle(_ s: TranscriptionAnalysis.Status) -> (String, Color) {
        switch s {
        case .pass:    return ("PASS", .green)
        case .warning: return ("WARN", .orange)
        case .fail:    return ("FAIL", .red)
        }
    }

    private func qualityTint(_ q: Double) -> Color {
        if q >= 0.7 { return .green }
        if q >= 0.4 { return .orange }
        return .red
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private var isolationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Source Separation")

            Text("Requires piano stem separation pipeline.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Toggle("Piano isolation", isOn: $isolationOn)
                .controlSize(.small)
                .disabled(true)
            Toggle("Mute background instruments", isOn: $muteBackgroundInstruments)
                .controlSize(.small)
                .disabled(true)
            Toggle("Reduce background noise", isOn: $reduceBackgroundNoise)
                .controlSize(.small)
                .disabled(true)
        }
    }

    /// "Data Flow" section — proves which note set is being shown, played,
    /// and exported. Added in response to a field bug where users were seeing
    /// pre-cleanup numbers in diagnostics. Each row labels exactly which
    /// list each downstream consumer is reading from.
    private var dataFlowSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Data Flow")
            if let run = vm.selectedRun {
                let cleanedMaxDur = run.notes.map(\.duration).max() ?? 0
                let rawMaxDur    = run.rawNotes.map(\.duration).max() ?? 0
                dataFlowRow("Run ID", run.id.uuidString)
                dataFlowRow("Created", Self.timestampFormatter.string(from: run.createdAt))
                dataFlowRow("Selected mode", run.dataflow("selectedModeDisplay") ?? run.pipelineName)
                dataFlowRow("Pipeline", run.pipelineName.isEmpty ? run.modelName : run.pipelineName)
                dataFlowRow("Actual separator", run.dataflow("actualSeparator") ?? "(none)")
                dataFlowRow("Actual transcriber", run.dataflow("actualTranscriber") ?? run.modelName)
                dataFlowRow("Model", run.modelName + (run.modelVersion.map { " (\($0))" } ?? ""))
                let pipelineFallback = run.dataflow("fallback") ?? (run.ranOnFallback ? "true" : "false")
                dataFlowRow("Fallback", pipelineFallback)
                if let reason = run.pipelineParameters["fallback.reason"] {
                    dataFlowRow("Fallback reason", reason)
                }
                if let stemPath = run.isolatedStemPath ?? run.dataflow("isolatedStemPath") {
                    dataFlowRow("Isolated stem", URL(fileURLWithPath: stemPath).lastPathComponent)
                }
                if let inputDur = run.dataflow("inputAudioDuration") {
                    dataFlowRow("Input audio duration", "\(inputDur)s")
                }
                if let stemDur = run.dataflow("isolatedStemDuration") {
                    dataFlowRow("Isolated stem duration", "\(stemDur)s")
                }
                if let warn = run.suitabilityWarning {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                        Text(warn)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().padding(.vertical, 2)
                dataFlowRow("Raw notes (model)", "\(run.rawNotes.count)")
                dataFlowRow("Cleaned notes (run.notes)", "\(run.notes.count)")
                dataFlowRow("Playback uses", "cleaned (\(run.notes.count))")
                dataFlowRow("Playback instrument", playback.playbackInstrumentName)
                dataFlowRow("Export uses", "cleaned (\(run.notes.count))")
                dataFlowRow("Diagnostics view", diagnosticsView == .cleaned
                    ? "cleaned (\(run.notes.count))"
                    : "raw (\(run.rawNotes.count))")
                Divider().padding(.vertical, 2)
                dataFlowRow("Cleaned max duration", String(format: "%.2fs", cleanedMaxDur))
                dataFlowRow("Raw max duration", String(format: "%.2fs", rawMaxDur))
                dataFlowRow("Source audio duration",
                            run.sourceAudioDuration.map { String(format: "%.2fs", $0) } ?? "—")
                if let report = run.cleanupReport {
                    dataFlowRow("Cleanup applied", "yes")
                    dataFlowRow("Removed", "\(report.totalRemoved)")
                } else {
                    dataFlowRow("Cleanup applied", "NO — pre-mandatory run")
                }
                // Piano Playability Critic — runs after MIDI Clinic. Each
                // row is rendered only if the critic ran (older runs lack
                // these keys), so the section stays empty for legacy data.
                if let beforeStr = run.dataflow("playabilityBeforeScore"),
                   let afterStr = run.dataflow("playabilityAfterScore") {
                    Divider().padding(.vertical, 2)
                    dataFlowRow("Playability score before", beforeStr)
                    dataFlowRow("Playability score after",  afterStr)
                    if let s = run.dataflow("playabilityImpossibleSpansBefore") {
                        dataFlowRow("Impossible spans found", s)
                    }
                    if let s = run.dataflow("playabilityImpossibleJumpsBefore") {
                        dataFlowRow("Impossible jumps found", s)
                    }
                    if let s = run.dataflow("playabilityNotesRemoved") {
                        dataFlowRow("Playability notes removed", s)
                    }
                    if let s = run.dataflow("playabilityNotesReassigned") {
                        dataFlowRow("Playability notes reassigned", s)
                    }
                    if let s = run.dataflow("playabilityHandSplit") {
                        dataFlowRow("Hand split (MIDI)", s)
                    }
                    if let s = run.dataflow("playabilityStopReason") {
                        dataFlowRow("Playability stop reason", s)
                    }
                }
                dataFlowRow("Last MIDI export",
                            vm.lastMIDIExportURL?.lastPathComponent ?? "—")
            } else {
                Text("No run selected.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption2.monospacedDigit())
    }

    private func dataFlowRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    private var debugSection: some View {
        DisclosureGroup(isExpanded: $showDebug) {
            VStack(alignment: .leading, spacing: 4) {
                debugRow("Audio duration", timeString(playback.audioDuration))
                debugRow("MIDI duration", timeString(playback.midiDuration))
                debugRow("Timeline", timeString(playback.duration))
                debugRow("Sample rate", playback.audioSampleRate > 0
                        ? String(format: "%.0f Hz", playback.audioSampleRate)
                        : "—")
                debugRow("Mode", playback.mode.displayName)
                debugRow("Notes (raw)", "\(vm.selectedRun?.noteCount ?? 0)")
                if let run = vm.selectedRun {
                    let earliest = run.notes.map(\.onset).min() ?? 0
                    let latest = run.notes.map { $0.onset + $0.duration }.max() ?? 0
                    debugRow("Earliest onset", String(format: "%.2fs", earliest))
                    debugRow("Latest end", String(format: "%.2fs", latest))
                }
                debugRow("Run ID", vm.selectedRunID?.uuidString.prefix(8).description ?? "—")
                debugRow("Audio file", playback.loadedAudioURL?.lastPathComponent ?? "—")
                if let url = vm.lastMIDIExportURL {
                    debugRow("MIDI export", url.lastPathComponent)
                }
            }
            .padding(.top, 6)
            .font(.caption.monospacedDigit())
        } label: {
            Label("Debug", systemImage: "ladybug")
                .font(.caption)
        }
    }

    // MARK: - Building blocks

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(valueText).font(.caption.monospacedDigit())
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private var statusColor: Color {
        if vm.isRunning { return .blue }
        if vm.runError != nil { return .red }
        return vm.project.runs.isEmpty ? .gray : .green
    }

    private var statusLabel: String {
        if vm.isRunning { return "Processing" }
        if vm.runError != nil { return "Failed" }
        if vm.project.runs.isEmpty { return "Not processed" }
        return "Processed"
    }

    private func timeString(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let m = Int(total) / 60
        let s = Int(total) % 60
        let ms = Int((total - Double(Int(total))) * 10)
        return String(format: "%d:%02d.%01d", m, s, ms)
    }
}

/// Wraps a list of (label, count) pairs into a small flow layout of chips.
/// Used by the diagnostics section to surface what the cleanup pass removed.
private struct FlowingChips: View {
    let items: [(String, Int)]

    var body: some View {
        // Simple two-column wrap; SwiftUI's Layout APIs are heavier than we
        // need for a 9-chip max list.
        let rows = items.chunked(into: 2)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 4) {
                    ForEach(rows[r], id: \.0) { label, count in
                        chip(label: label, count: count)
                    }
                    if rows[r].count == 1 { Spacer() }
                }
            }
        }
    }

    private func chip(label: String, count: Int) -> some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0+size, count)]) }
    }
}
