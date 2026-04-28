import Foundation
import AVFoundation
import Accelerate

/// FFT-based piano transcription using Apple's vDSP.
///
/// Pipeline
///   1. Load audio → mono Float32 44.1 kHz (converts any AVFoundation-readable source)
///   2. Short-time FFT: 4096-pt, 512-sample hop, Hann-windowed
///   3. Per-pitch harmonic salience: weighted sum of magnitudes at f, 2f … 8f
///   4. Smooth salience (5-frame moving average)
///   5. Threshold = 8 % of global 95th-percentile salience (with 4 % hysteresis release)
///   6. Note segmentation per pitch, gap-merge, short-note discard
///
/// Accuracy: good enough for simple material; suitable for verifying the
/// full pipeline with real audio before a Core ML model is plugged in.
public final class BasicPianoModelRunner: ModelRunner, @unchecked Sendable {

    /// Tuning knobs exposed to pipelines so they can choose between a fast/loose
    /// baseline and a stricter piano-focused configuration.
    public struct Config: Sendable, Equatable {
        /// Onset threshold as a fraction of the global 95th-percentile salience.
        public var activationRatio: Float
        /// Offset threshold as a fraction of the global 95th-percentile salience (hysteresis).
        public var releaseRatio: Float
        /// Minimum surviving note duration, in seconds.
        public var minDuration: Double
        /// Same-pitch notes closer than this gap are merged together.
        public var maxMergeGap: Double
        /// Minimum velocity (0–127) a note must reach to be kept.
        public var minVelocity: Int
        /// Display label baked into the runner's `name` so each tuning shows up
        /// distinctly in run history.
        public var label: String

        public init(
            activationRatio: Float,
            releaseRatio: Float,
            minDuration: Double,
            maxMergeGap: Double,
            minVelocity: Int,
            label: String
        ) {
            self.activationRatio = activationRatio
            self.releaseRatio = releaseRatio
            self.minDuration = minDuration
            self.maxMergeGap = maxMergeGap
            self.minVelocity = minVelocity
            self.label = label
        }

        /// Original loose tuning — keeps the pipeline cheap and shows what the
        /// raw detector produces.
        public static let basic = Config(
            activationRatio: 0.08,
            releaseRatio: 0.04,
            minDuration: 0.05,
            maxMergeGap: 0.08,
            minVelocity: 1,
            label: "BasicSpectral v1"
        )

        /// Stricter onset, wider sustain merge, ghost-note pruning by velocity.
        public static let pianoFocused = Config(
            activationRatio: 0.12,
            releaseRatio: 0.05,
            minDuration: 0.10,
            maxMergeGap: 0.20,
            minVelocity: 24,
            label: "PianoFocused v1"
        )

        /// Snapshot suitable for persisting alongside a TranscriptionRun.
        public var asParameters: [String: String] {
            [
                "activationRatio": String(format: "%.4f", activationRatio),
                "releaseRatio":    String(format: "%.4f", releaseRatio),
                "minDuration":     String(format: "%.4f", minDuration),
                "maxMergeGap":     String(format: "%.4f", maxMergeGap),
                "minVelocity":     "\(minVelocity)",
                "label":           label,
            ]
        }
    }

    public var name: String { config.label }
    public let config: Config

    // FFT
    private let fftSize  = 4096
    private let hopSize  = 512
    private let sampleRate: Double = 44100

    public init(config: Config = .basic) {
        self.config = config
    }

    public func transcribe(audioURL: URL, progress: PipelineProgressHandler?) async throws -> [MIDINote] {
        try await Task.detached(priority: .userInitiated) { [self] in
            try self.pipeline(url: audioURL, progress: progress)
        }.value
    }

    // MARK: - Pipeline

    private func pipeline(url: URL, progress: PipelineProgressHandler?) throws -> [MIDINote] {
        progress?(PipelineProgress(stage: .loading, fraction: 0.02, detail: "reading file"))
        let samples = try loadMono(url: url)
        guard samples.count >= fftSize else {
            progress?(PipelineProgress(stage: .finalizing, fraction: 1.0, detail: "clip too short"))
            return []
        }

        let frames   = stft(samples: samples, progress: progress)
        let salience = harmonicSalience(frames: frames, progress: progress)
        progress?(PipelineProgress(stage: .detecting, fraction: 0.92, detail: "segmenting notes"))
        let notes = segmentNotes(salience: salience)
        return notes
    }

    // MARK: - Audio loading

    private func loadMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFmt = file.processingFormat

        // Cap at 5 minutes
        let maxFrames = Int64(5 * 60 * sampleRate)
        let readCount = AVAudioFrameCount(min(file.length, maxFrames))

        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: readCount) else {
            throw ModelRunnerError.audioLoadFailed("Cannot allocate read buffer")
        }
        try file.read(into: srcBuf)

        // Fast path: already mono float32 at the target sample rate
        if srcFmt.channelCount == 1,
           srcFmt.commonFormat == .pcmFormatFloat32,
           abs(srcFmt.sampleRate - sampleRate) < 1,
           let ptr = srcBuf.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: ptr, count: Int(srcBuf.frameLength)))
        }

        // Convert to mono float32 44.1 kHz
        let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!

        guard let conv = AVAudioConverter(from: srcFmt, to: dstFmt) else {
            throw ModelRunnerError.audioLoadFailed("Cannot create AVAudioConverter")
        }

        let dstCount = AVAudioFrameCount(Double(srcBuf.frameLength) * sampleRate / srcFmt.sampleRate) + 1
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: dstCount) else {
            throw ModelRunnerError.audioLoadFailed("Cannot allocate conversion buffer")
        }

        var convErr: NSError?
        var fed = false
        conv.convert(to: dstBuf, error: &convErr) { _, statusPtr in
            guard !fed else { statusPtr.pointee = .noDataNow; return nil }
            fed = true
            statusPtr.pointee = .haveData
            return srcBuf
        }
        if let e = convErr { throw ModelRunnerError.audioLoadFailed(e.localizedDescription) }

        guard let ptr = dstBuf.floatChannelData?[0] else {
            throw ModelRunnerError.audioLoadFailed("No output channel data")
        }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(dstBuf.frameLength)))
    }

    // MARK: - STFT

    private func stft(samples: [Float], progress: PipelineProgressHandler?) -> [[Float]] {
        let n    = fftSize
        let half = n / 2
        let log2n = vDSP_Length(log2(Float(n)))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        // Normalised Hann window
        var win = [Float](repeating: 0, count: n)
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        var result: [[Float]] = []
        let totalFrames = max(1, (samples.count - n) / hopSize + 1)
        result.reserveCapacity(totalFrames)

        var pos = 0
        var reported = 0
        while pos + n <= samples.count {
            // STFT spans fractions 0.05 → 0.55 of the overall run
            if result.count &- reported >= 32 {
                let frac = 0.05 + 0.50 * Double(result.count) / Double(totalFrames)
                progress?(PipelineProgress(stage: .analyzing, fraction: frac, detail: "frame \(result.count) / \(totalFrames)"))
                reported = result.count
            }
            // Windowed frame
            var frame = Array(samples[pos ..< pos + n])
            vDSP_vmul(frame, 1, win, 1, &frame, 1, vDSP_Length(n))

            // Pack real samples into split-complex (even → re, odd → im)
            var re = [Float](repeating: 0, count: half)
            var im = [Float](repeating: 0, count: half)
            for i in 0 ..< half {
                re[i] = frame[2 * i]
                im[i] = frame[2 * i + 1]
            }

            // In-place real FFT via vDSP
            var mags = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { reBuf in
                im.withUnsafeMutableBufferPointer { imBuf in
                    var sc = DSPSplitComplex(realp: reBuf.baseAddress!, imagp: imBuf.baseAddress!)
                    vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&sc, 1, &mags, 1, vDSP_Length(half))
                }
            }

            // Scale to one-sided amplitude
            var scale = Float(2.0 / Double(n))
            vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(half))

            result.append(mags)
            pos += hopSize
        }

        return result
    }

    // MARK: - Per-pitch harmonic salience

    private struct PitchTrack {
        let pitch:  Int
        var values: [Float]  // one entry per STFT frame
    }

    private func harmonicSalience(frames: [[Float]], progress: PipelineProgressHandler?) -> [PitchTrack] {
        guard !frames.isEmpty else { return [] }

        let half   = fftSize / 2
        let binHz  = sampleRate / Double(fftSize)
        let nFrames = frames.count
        let pitches = Array(21 ... 108)

        return pitches.enumerated().map { (idx, pitch) -> PitchTrack in
            if idx % 8 == 0 {
                // Harmonic salience spans 0.55 → 0.90
                let frac = 0.55 + 0.35 * Double(idx) / Double(pitches.count)
                progress?(PipelineProgress(stage: .analyzing, fraction: frac, detail: "pitch \(idx + 1) / \(pitches.count)"))
            }
            let fund = 440.0 * pow(2.0, Double(pitch - 69) / 12.0)
            var vals = [Float](repeating: 0, count: nFrames)

            for (fi, frame) in frames.enumerated() {
                var sal: Float   = 0
                var wSum: Float  = 0

                for h in 1 ... 8 {
                    let freq = fund * Double(h)
                    guard freq < sampleRate / 2 else { break }

                    let exactBin = freq / binHz
                    let b0 = Int(exactBin)
                    let b1 = b0 + 1
                    guard b1 < half else { break }

                    // Linear interpolation between adjacent bins
                    let frac = Float(exactBin - Double(b0))
                    let mag  = frame[b0] * (1 - frac) + frame[b1] * frac

                    let w = 1.0 / Float(h)   // favour fundamental over overtones
                    sal  += mag * w
                    wSum += w
                }

                vals[fi] = wSum > 0 ? sal / wSum : 0
            }

            // 5-frame moving average smoothing
            let smoothed = movingAverage(vals, halfWindow: 2)
            return PitchTrack(pitch: pitch, values: smoothed)
        }
    }

    private func movingAverage(_ v: [Float], halfWindow: Int) -> [Float] {
        guard !v.isEmpty else { return v }
        var out = [Float](repeating: 0, count: v.count)
        for i in v.indices {
            let lo = max(0, i - halfWindow)
            let hi = min(v.count - 1, i + halfWindow)
            var sum: Float = 0
            for j in lo ... hi { sum += v[j] }
            out[i] = sum / Float(hi - lo + 1)
        }
        return out
    }

    // MARK: - Note segmentation

    private func segmentNotes(salience: [PitchTrack]) -> [MIDINote] {
        guard let first = salience.first, !first.values.isEmpty else { return [] }

        let frameTime = Double(hopSize) / sampleRate

        // Global 95th-percentile threshold — keeps silent/weak pitches inactive
        var all = salience.flatMap(\.values)
        all.sort()
        let p95idx = min(Int(Float(all.count) * 0.95), all.count - 1)
        let p95 = all[p95idx]

        guard p95 > 1e-7 else { return [] }   // effectively silent audio

        let onThreshold  = p95 * config.activationRatio
        let offThreshold = p95 * config.releaseRatio

        // Velocity reference: the loudest salience anywhere in the clip.
        // Dividing by p95 caused even weak sub-harmonic aliases to saturate to
        // 127 on sparse signals; using the global max keeps the dominant pitch
        // near 127 and lets weaker pitches fall off proportionally.
        let globalMax = max(p95, all.last ?? p95)

        var notes: [MIDINote] = []

        for track in salience {
            var noteStart: Int?
            var peak: Float = 0

            for (i, v) in track.values.enumerated() {
                if noteStart == nil {
                    if v >= onThreshold {
                        noteStart = i
                        peak = v
                    }
                } else {
                    if v > peak { peak = v }
                    let isLast  = (i == track.values.count - 1)
                    let release = (v < offThreshold)
                    if release || isLast {
                        let endIdx = release ? i : i + 1
                        let onset  = Double(noteStart!) * frameTime
                        let dur    = Double(endIdx - noteStart!) * frameTime
                        if dur >= config.minDuration {
                            // Velocity: sqrt-scaled against the loudest salience in the clip.
                            let ratio = min(1, max(0, peak / globalMax))
                            let vel = min(127, max(1, Int(sqrt(ratio) * 110) + 15))
                            if vel >= config.minVelocity {
                                notes.append(MIDINote(pitch: track.pitch,
                                                      onset: onset,
                                                      duration: dur,
                                                      velocity: vel))
                            }
                        }
                        noteStart = nil
                        peak = 0
                    }
                }
            }
        }

        notes.sort { $0.onset < $1.onset }
        return mergeGaps(notes)
    }

    /// Merge consecutive notes of the same pitch if the gap is small.
    private func mergeGaps(_ notes: [MIDINote]) -> [MIDINote] {
        guard notes.count > 1 else { return notes }
        var merged: [MIDINote] = []
        var cur = notes[0]
        for nxt in notes.dropFirst() {
            if nxt.pitch == cur.pitch,
               nxt.onset - (cur.onset + cur.duration) <= config.maxMergeGap {
                cur = MIDINote(pitch: cur.pitch,
                               onset: cur.onset,
                               duration: nxt.onset + nxt.duration - cur.onset,
                               velocity: max(cur.velocity, nxt.velocity))
            } else {
                merged.append(cur)
                cur = nxt
            }
        }
        merged.append(cur)
        return merged
    }
}
