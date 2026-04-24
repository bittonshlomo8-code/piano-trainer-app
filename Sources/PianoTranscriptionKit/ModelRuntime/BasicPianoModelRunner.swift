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

    public let name = "BasicSpectral v1"

    // FFT
    private let fftSize  = 4096
    private let hopSize  = 512
    private let sampleRate: Double = 44100

    // Segmentation
    private let activationRatio: Float = 0.08   // onset: fraction of p95
    private let releaseRatio:    Float = 0.04   // offset: fraction of p95
    private let minDuration:     Double = 0.05  // seconds
    private let maxMergeGap:     Double = 0.08  // seconds

    public init() {}

    public func transcribe(audioURL: URL) async throws -> [MIDINote] {
        try await Task.detached(priority: .userInitiated) { [self] in
            try self.pipeline(url: audioURL)
        }.value
    }

    // MARK: - Pipeline

    private func pipeline(url: URL) throws -> [MIDINote] {
        let samples = try loadMono(url: url)
        guard samples.count >= fftSize else { return [] }

        let frames   = stft(samples: samples)
        let salience = harmonicSalience(frames: frames)
        return segmentNotes(salience: salience)
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

    private func stft(samples: [Float]) -> [[Float]] {
        let n    = fftSize
        let half = n / 2
        let log2n = vDSP_Length(log2(Float(n)))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        // Normalised Hann window
        var win = [Float](repeating: 0, count: n)
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        var result: [[Float]] = []
        result.reserveCapacity(samples.count / hopSize)

        var pos = 0
        while pos + n <= samples.count {
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

    private func harmonicSalience(frames: [[Float]]) -> [PitchTrack] {
        guard !frames.isEmpty else { return [] }

        let half   = fftSize / 2
        let binHz  = sampleRate / Double(fftSize)
        let nFrames = frames.count

        return (21 ... 108).map { pitch -> PitchTrack in
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

        let onThreshold  = p95 * activationRatio
        let offThreshold = p95 * releaseRatio

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
                        if dur >= minDuration {
                            // Velocity: sqrt-scaled against p95 (dynamic range compression)
                            let vel = min(127, max(1, Int(sqrt(peak / p95) * 90) + 15))
                            notes.append(MIDINote(pitch: track.pitch,
                                                  onset: onset,
                                                  duration: dur,
                                                  velocity: vel))
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
               nxt.onset - (cur.onset + cur.duration) <= maxMergeGap {
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
