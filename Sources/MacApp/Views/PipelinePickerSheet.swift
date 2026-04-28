import SwiftUI
import PianoTranscriptionKit

/// Modal sheet that asks the user to pick a transcription pipeline before
/// kicking off a run. Used by:
///   • the import flow, immediately after audio extraction completes
///   • the "Run again with different pipeline" action on the detail view
///
/// The sheet itself never starts the run — it returns the chosen pipeline
/// via `onConfirm` and lets the caller invoke `runTranscription(using:)`.
struct PipelinePickerSheet: View {
    let projectName: String
    let registry: PipelineRegistry
    @Binding var selection: PipelineKind
    /// Title shown above the picker. Differs between the import path and
    /// re-run path so the user knows which case they're in.
    let title: String
    let confirmLabel: String
    let onConfirm: (PipelineKind) -> Void
    let onCancel: () -> Void

    init(
        projectName: String,
        registry: PipelineRegistry = .shared,
        selection: Binding<PipelineKind>,
        title: String = "Choose Transcription Pipeline",
        confirmLabel: String = "Run Transcription",
        onConfirm: @escaping (PipelineKind) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.projectName = projectName
        self.registry = registry
        self._selection = selection
        self.title = title
        self.confirmLabel = confirmLabel
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                Text(projectName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Different songs need different strategies. Pick the pipeline that fits this audio — you can re-run with a different one later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(registry.availableKinds) { kind in
                    pipelineCard(kind: kind)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button {
                    onConfirm(selection)
                } label: {
                    Text(confirmLabel)
                        .frame(minWidth: 130)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func pipelineCard(kind: PipelineKind) -> some View {
        let onFallback = !registry.hasDedicatedBackend(kind)
        let isSelected = selection == kind
        Button {
            selection = kind
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(kind.displayName)
                            .font(.headline)
                        if onFallback {
                            Text("Fallback")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                                .foregroundStyle(Color.orange)
                        }
                    }
                    Text(kind.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if onFallback, let reason = registry.fallbackReason(kind) {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Mixed-audio suitability nudge: clean-piano models
                    // produce catastrophic noise on full-band recordings.
                    if let warning = kind.mixedAudioSuitabilityWarning {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.bubble")
                                .foregroundStyle(.orange)
                                .font(.caption2)
                            Text(warning)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
