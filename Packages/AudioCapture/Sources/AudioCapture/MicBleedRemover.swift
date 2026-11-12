import Accelerate
import Foundation

// Pavarotti: removing loudspeaker bleed from the microphone track after recording.
//
// The microphone is recorded passively (see `PassiveMicCaptureEngine`), so when
// the user listens on loudspeakers the far side of the call is also picked up by
// the microphone, delayed by the output latency (about a third of a second on a
// Bluetooth speaker). The system track holds that same audio cleanly, so it
// serves as the reference: per block, the delay is found from the band
// envelopes, a short per-band filter predicts the bleed and subtracts it, and
// what is left of it is suppressed with a spectral gain. Blocks where the
// reference is silent or does not show up in the microphone (headphones) are
// returned untouched, sample for sample.

/// One block of spectra, band-major: `band * frames + frame`.
final class BleedSpectrogram {
    let frames: Int
    let bands: Int
    let real: UnsafeMutablePointer<Float>
    let imag: UnsafeMutablePointer<Float>

    /// Allocates zeroed storage for `frames` × `bands` complex values.
    init(frames: Int, bands: Int) {
        self.frames = frames
        self.bands = bands
        real = .allocate(capacity: frames * bands)
        imag = .allocate(capacity: frames * bands)
        real.initialize(repeating: 0, count: frames * bands)
        imag.initialize(repeating: 0, count: frames * bands)
    }

    deinit {
        real.deallocate()
        imag.deallocate()
    }

    /// The split-complex view of one band, starting at `frame`.
    func band(_ band: Int, from frame: Int = 0) -> DSPSplitComplex {
        DSPSplitComplex(realp: real + band * frames + frame, imagp: imag + band * frames + frame)
    }
}

/// Short-time Fourier transform with a square-root Hann window at half overlap.
final class BleedTransform {
    let frameSize: Int
    let hopSize: Int
    var bands: Int {
        frameSize / 2 + 1
    }

    private let window: [Float]
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup

    /// Builds the window and both transform setups for `frameSize`.
    init(frameSize: Int, hopSize: Int) {
        self.frameSize = frameSize
        self.hopSize = hopSize
        window = (0 ..< frameSize).map { index in
            Float(sin(Double.pi * Double(index) / Double(frameSize)))
        }
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(frameSize), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(frameSize), .INVERSE)
        else {
            preconditionFailure("vDSP refused a DFT of \(frameSize) points")
        }
        self.forward = forward
        self.inverse = inverse
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// Number of frames that fit completely into `sampleCount` samples.
    func frameCount(for sampleCount: Int) -> Int {
        sampleCount < frameSize ? 0 : 1 + (sampleCount - frameSize) / hopSize
    }

    /// Spectra of every complete frame in `samples`.
    func analyze(_ samples: [Float]) -> BleedSpectrogram {
        let frames = frameCount(for: samples.count)
        let result = BleedSpectrogram(frames: frames, bands: bands)
        var windowed = [Float](repeating: 0, count: frameSize)
        let zeros = [Float](repeating: 0, count: frameSize)
        var outReal = [Float](repeating: 0, count: frameSize)
        var outImag = [Float](repeating: 0, count: frameSize)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for frame in 0 ..< frames {
                vDSP_vmul(base + frame * hopSize, 1, window, 1, &windowed, 1, vDSP_Length(frameSize))
                vDSP_DFT_Execute(forward, windowed, zeros, &outReal, &outImag)
                for band in 0 ..< bands {
                    result.real[band * frames + frame] = outReal[band]
                    result.imag[band * frames + frame] = outImag[band]
                }
            }
        }
        return result
    }

    /// Overlap-adds the frames of `spectra` back into `sampleCount` samples.
    func synthesize(_ spectra: BleedSpectrogram, sampleCount: Int) -> [Float] {
        var output = [Float](repeating: 0, count: sampleCount)
        var weight = [Float](repeating: 0, count: sampleCount)
        var inReal = [Float](repeating: 0, count: frameSize)
        var inImag = [Float](repeating: 0, count: frameSize)
        var outReal = [Float](repeating: 0, count: frameSize)
        var outImag = [Float](repeating: 0, count: frameSize)
        let scale = 1 / Float(frameSize)
        for frame in 0 ..< spectra.frames {
            for band in 0 ..< bands {
                let real = spectra.real[band * spectra.frames + frame]
                let imag = spectra.imag[band * spectra.frames + frame]
                inReal[band] = real
                inImag[band] = imag
                if band > 0, band < frameSize / 2 {
                    inReal[frameSize - band] = real
                    inImag[frameSize - band] = -imag
                }
            }
            vDSP_DFT_Execute(inverse, inReal, inImag, &outReal, &outImag)
            let start = frame * hopSize
            for index in 0 ..< frameSize {
                output[start + index] += outReal[index] * scale * window[index]
                weight[start + index] += window[index] * window[index]
            }
        }
        for index in 0 ..< sampleCount {
            output[index] /= max(weight[index], 1e-3)
        }
        return output
    }
}

/// Removes the far side of a call from one block of the microphone track.
final class MicBleedRemover {
    /// What happened to one block.
    struct BlockResult {
        /// The block, cleaned or returned as it came in.
        let samples: [Float]
        /// Whether bleed was found and removed.
        let cleaned: Bool
        /// Envelope correlation between the microphone and the delayed reference.
        let correlation: Float
        /// Delay of the bleed against the reference in seconds, when cleaned.
        let delaySeconds: Double?
        /// Share of the microphone's power, while the far side is audible, that
        /// the delayed reference predicts.
        var explained: Float = 0
    }

    static let frameSize = 1024
    static let hopSize = 512
    /// Longest delay searched, in frames (about 0.7 s at 24 kHz).
    static let maxDelayFrames = 40
    /// Frames of the per-band prediction filter: one before the delay, five after.
    static let tapCount = 6
    /// Samples of reference history a block needs in front of it.
    static let referenceLead = maxDelayFrames * hopSize
    /// Below this envelope correlation the block has no bleed worth touching.
    static let minimumCorrelation: Float = 0.12
    /// Mean-square level under which the reference counts as silent (-75 dBFS).
    static let silentReferencePower: Float = 3.2e-8
    /// Smallest share of the microphone that the reference must predict.
    static let minimumExplained: Float = 0.1
    /// How strongly the residual of the predicted bleed is suppressed.
    static let overSubtraction: Float = 4
    /// Lowest spectral gain (-30 dB), so suppressed passages keep a noise floor.
    static let gainFloor: Float = 0.0316

    private let transform = BleedTransform(frameSize: frameSize, hopSize: hopSize)

    /// Cleans one block.
    ///
    /// - Parameters:
    ///   - mic: the microphone block.
    ///   - reference: the system track for the same span, preceded by
    ///     `referenceLead` earlier samples (`mic.count + referenceLead` in total).
    ///   - sampleRate: rate of both tracks, used to report the delay.
    func clean(mic: [Float], reference: [Float], sampleRate: Double) -> BlockResult {
        let untouched = BlockResult(samples: mic, cleaned: false, correlation: 0, delaySeconds: nil)
        guard reference.count == mic.count + Self.referenceLead, mic.count >= 4 * Self.frameSize,
              vDSP.meanSquare(reference) > Self.silentReferencePower
        else { return untouched }

        // Zero-pad the end so the last samples are covered by a complete frame.
        let padding = [Float](repeating: 0, count: Self.frameSize)
        let micSpectra = transform.analyze(mic + padding)
        let refSpectra = transform.analyze(reference + padding)
        guard refSpectra.frames == micSpectra.frames + Self.maxDelayFrames else { return untouched }

        let match = findDelay(mic: micSpectra, reference: refSpectra)
        guard match.correlation >= Self.minimumCorrelation else {
            return BlockResult(samples: mic, cleaned: false, correlation: match.correlation, delaySeconds: nil)
        }

        let before = activePower(of: micSpectra, reference: refSpectra, delay: match.delay)
        let predicted = predictBleed(mic: micSpectra, reference: refSpectra, delay: match.delay)
        let explained = activePower(of: predicted, reference: refSpectra, delay: match.delay) / (before + 1e-12)
        guard explained >= Self.minimumExplained else {
            return BlockResult(
                samples: mic, cleaned: false, correlation: match.correlation, delaySeconds: nil, explained: explained
            )
        }
        suppress(mic: micSpectra, predicted: predicted, reference: refSpectra, delay: match.delay)
        let output = transform.synthesize(micSpectra, sampleCount: mic.count + Self.frameSize)
        return BlockResult(
            samples: Array(output[0 ..< mic.count]),
            cleaned: true,
            correlation: match.correlation,
            delaySeconds: Double(match.delay * Self.hopSize) / sampleRate,
            explained: explained
        )
    }

    /// Power of `spectra` in the speech bands over the frames in which the
    /// delayed reference is audible.
    private func activePower(of spectra: BleedSpectrogram, reference: BleedSpectrogram, delay: Int) -> Float {
        let bands = 6 ..< 171
        let offset = Self.maxDelayFrames - delay
        var loudness = [Float](repeating: 0, count: spectra.frames)
        var own = [Float](repeating: 0, count: spectra.frames)
        for band in bands {
            for frame in 0 ..< spectra.frames {
                loudness[frame] += power(reference, band: band, frame: offset + frame)
                own[frame] += power(spectra, band: band, frame: frame)
            }
        }
        let threshold = 0.05 * loudness.sorted()[spectra.frames * 95 / 100]
        var total: Float = 0
        for frame in 0 ..< spectra.frames where loudness[frame] > threshold {
            total += own[frame]
        }
        return total
    }

    // MARK: - Delay search

    /// Finds the delay (in frames) at which the compressed band envelopes of the
    /// reference line up best with the microphone, and how well they do.
    private func findDelay(mic: BleedSpectrogram, reference: BleedSpectrogram) -> (delay: Int, correlation: Float) {
        let bandRange = 6 ..< 171 // roughly 150 Hz to 4 kHz
        let frames = mic.frames
        let micEnvelope = envelope(of: mic, bands: bandRange, removeMean: true)
        let refEnvelope = envelope(of: reference, bands: bandRange, removeMean: false)
        let micEnergy = vDSP.sumOfSquares(micEnvelope)
        var best: (delay: Int, correlation: Float) = (0, -1)
        for delay in 0 ..< (Self.maxDelayFrames - Self.tapCount) {
            let offset = Self.maxDelayFrames - delay
            var cross: Float = 0
            var refEnergy: Float = 0
            for index in 0 ..< bandRange.count {
                micEnvelope.withUnsafeBufferPointer { micPointer in
                    refEnvelope.withUnsafeBufferPointer { refPointer in
                        guard let micBase = micPointer.baseAddress, let refBase = refPointer.baseAddress else { return }
                        let refBand = refBase + index * reference.frames + offset
                        var dot: Float = 0
                        var sum: Float = 0
                        var squares: Float = 0
                        vDSP_dotpr(micBase + index * frames, 1, refBand, 1, &dot, vDSP_Length(frames))
                        vDSP_sve(refBand, 1, &sum, vDSP_Length(frames))
                        vDSP_svesq(refBand, 1, &squares, vDSP_Length(frames))
                        cross += dot
                        refEnergy += squares - sum * sum / Float(frames)
                    }
                }
            }
            let correlation = cross / (micEnergy * refEnergy + 1e-12).squareRoot()
            if correlation > best.correlation { best = (delay, correlation) }
        }
        // A block in which the user talks a lot dilutes that figure, so the
        // decision uses only the frames in which the far side is audible.
        let active = activeCorrelation(
            mic: mic, reference: reference, bands: bandRange, offset: Self.maxDelayFrames - best.delay
        )
        return (best.delay, active ?? best.correlation)
    }

    /// Envelope correlation over the frames in which the reference is loud, or
    /// `nil` when there are too few of them to judge.
    private func activeCorrelation(
        mic: BleedSpectrogram, reference: BleedSpectrogram, bands: Range<Int>, offset: Int
    ) -> Float? {
        let frames = mic.frames
        var loudness = [Float](repeating: 0, count: frames)
        for band in bands {
            for frame in 0 ..< frames {
                loudness[frame] += power(reference, band: band, frame: offset + frame)
            }
        }
        let threshold = 0.05 * loudness.sorted()[frames * 95 / 100]
        let active = (0 ..< frames).filter { loudness[$0] > threshold && loudness[$0] > 0 }
        guard active.count >= 25 else { return nil }

        var cross: Float = 0
        var micEnergy: Float = 0
        var refEnergy: Float = 0
        for band in bands {
            let micValues = active.map { pow(power(mic, band: band, frame: $0), 0.3) }
            let refValues = active.map { pow(power(reference, band: band, frame: offset + $0), 0.3) }
            let micMean = vDSP.mean(micValues)
            let refMean = vDSP.mean(refValues)
            for index in active.indices {
                let micValue = micValues[index] - micMean
                let refValue = refValues[index] - refMean
                cross += micValue * refValue
                micEnergy += micValue * micValue
                refEnergy += refValue * refValue
            }
        }
        return cross / (micEnergy * refEnergy + 1e-12).squareRoot()
    }

    /// Compressed magnitudes (`|X|^0.6`) of the chosen bands, band-major.
    private func envelope(of spectra: BleedSpectrogram, bands: Range<Int>, removeMean: Bool) -> [Float] {
        let frames = spectra.frames
        var result = [Float](repeating: 0, count: bands.count * frames)
        for (index, band) in bands.enumerated() {
            var total: Float = 0
            for frame in 0 ..< frames {
                let real = spectra.real[band * frames + frame]
                let imag = spectra.imag[band * frames + frame]
                let value = pow(real * real + imag * imag, 0.3)
                result[index * frames + frame] = value
                total += value
            }
            guard removeMean else { continue }
            let mean = total / Float(frames)
            for frame in 0 ..< frames {
                result[index * frames + frame] -= mean
            }
        }
        return result
    }
}

// MARK: - Linear prediction and residual suppression

extension MicBleedRemover {
    /// Predicts the bleed in every band from a few delayed reference frames
    /// (regularised least squares) and subtracts it from `mic` in place.
    /// Returns the prediction.
    func predictBleed(mic: BleedSpectrogram, reference: BleedSpectrogram, delay: Int) -> BleedSpectrogram {
        let frames = mic.frames
        let predicted = BleedSpectrogram(frames: frames, bands: mic.bands)
        // Reference frame for mic frame 0 at tap 0; taps reach one frame earlier
        // in delay (later in the reference) and up to four frames later.
        let origin = Self.maxDelayFrames - delay
        let offsets = (-1 ..< Self.tapCount - 1).map { origin - $0 }.filter { $0 >= 0 && $0 + frames <= reference.frames }
        let length = vDSP_Length(frames)
        for band in 0 ..< mic.bands {
            var target = mic.band(band)
            var output = predicted.band(band)
            let weights = solveTaps(reference: reference, band: band, offsets: offsets, target: target, frames: frames)
            for (tap, offset) in offsets.enumerated() {
                accumulate(column: reference.band(band, from: offset), weight: weights[tap], into: output, frames: frames)
            }
            vDSP_zvsub(&target, 1, &output, 1, &target, 1, length) // target - output
        }
        return predicted
    }

    /// `output += column * weight` for one band.
    func accumulate(column: DSPSplitComplex, weight: ComplexValue, into output: DSPSplitComplex, frames: Int) {
        let weightReal = Float(weight.real)
        let weightImag = Float(weight.imag)
        for frame in 0 ..< frames {
            let real = column.realp[frame]
            let imag = column.imagp[frame]
            output.realp[frame] += real * weightReal - imag * weightImag
            output.imagp[frame] += real * weightImag + imag * weightReal
        }
    }

    /// Solves the normal equations of one band for the tap weights.
    func solveTaps(
        reference: BleedSpectrogram, band: Int, offsets: [Int], target: DSPSplitComplex, frames: Int
    ) -> [ComplexValue] {
        let count = offsets.count
        let length = vDSP_Length(frames)
        var matrix = [ComplexValue](repeating: .zero, count: count * count)
        var vector = [ComplexValue](repeating: .zero, count: count)
        var targetCopy = target
        var trace = 0.0
        for row in 0 ..< count {
            var rowColumn = reference.band(band, from: offsets[row])
            for column in row ..< count {
                var other = reference.band(band, from: offsets[column])
                let value = conjugateDot(&rowColumn, &other, length)
                matrix[row * count + column] = value
                matrix[column * count + row] = value.conjugate
            }
            vector[row] = conjugateDot(&rowColumn, &targetCopy, length)
            trace += matrix[row * count + row].real
        }
        let regularisation = 1e-3 * trace / Double(max(count, 1)) + 1e-9
        for index in 0 ..< count {
            matrix[index * count + index].real += regularisation
        }
        return ComplexValue.solve(matrix: &matrix, vector: &vector, count: count)
    }

    /// `sum(conj(lhs) * rhs)`.
    func conjugateDot(_ lhs: inout DSPSplitComplex, _ rhs: inout DSPSplitComplex, _ length: vDSP_Length) -> ComplexValue {
        var real: Float = 0
        var imag: Float = 0
        withUnsafeMutablePointer(to: &real) { realPointer in
            withUnsafeMutablePointer(to: &imag) { imagPointer in
                var result = DSPSplitComplex(realp: realPointer, imagp: imagPointer)
                vDSP_zidotpr(&lhs, 1, &rhs, 1, &result, length)
            }
        }
        return ComplexValue(real: Double(real), imag: Double(imag))
    }

    // MARK: - Residual suppression

    /// Scales `mic` (already holding the prediction error) by a spectral gain
    /// that removes what the linear prediction left of the bleed.
    func suppress(mic: BleedSpectrogram, predicted: BleedSpectrogram, reference: BleedSpectrogram, delay: Int) {
        let frames = mic.frames
        let bands = mic.bands
        let origin = Self.maxDelayFrames - delay
        var bleedPower = [Float](repeating: 0, count: frames * bands)
        for band in 0 ..< bands {
            var predictedPower = [Float](repeating: 0, count: frames)
            var referencePower = [Float](repeating: 0, count: frames)
            var predictedSum: Float = 0
            var referenceSum: Float = 0
            for frame in 0 ..< frames {
                let predictedNow = power(predicted, band: band, frame: frame)
                let referenceNow = power(reference, band: band, frame: origin + frame)
                predictedSum += predictedNow
                // Let both estimates decay over the following frames (room tail).
                predictedPower[frame] = frame > 0 ? max(predictedNow, 0.5 * predictedPower[frame - 1]) : predictedNow
                referencePower[frame] = frame > 0 ? max(referenceNow, 0.55 * referencePower[frame - 1]) : referenceNow
                referenceSum += referencePower[frame]
            }
            // Bleed the filter cannot follow (distortion, jitter) still scales with
            // the reference power, by the coupling the filter found in this band.
            let coupling = predictedSum / (referenceSum + 1e-12)
            for frame in 0 ..< frames {
                bleedPower[band * frames + frame] = max(predictedPower[frame], coupling * referencePower[frame])
            }
        }
        applyGain(to: mic, bleedPower: bleedPower)
    }

    /// Applies `sqrt(1 - overSubtraction * bleed / error)`, floored, per bin.
    func applyGain(to mic: BleedSpectrogram, bleedPower: [Float]) {
        let frames = mic.frames
        let bands = mic.bands
        for band in 0 ..< bands {
            for frame in 0 ..< frames {
                let index = band * frames + frame
                let lower = band > 0 ? bleedPower[index - frames] : 0
                let upper = band < bands - 1 ? bleedPower[index + frames] : 0
                let smoothed = 0.25 * lower + 0.5 * bleedPower[index] + 0.25 * upper
                let error = power(mic, band: band, frame: frame)
                let ratio = 1 - Self.overSubtraction * smoothed / (error + 1e-12)
                let gain = max(Self.gainFloor * Self.gainFloor, min(1, ratio)).squareRoot()
                mic.real[index] *= gain
                mic.imag[index] *= gain
            }
        }
    }

    func power(_ spectra: BleedSpectrogram, band: Int, frame: Int) -> Float {
        let real = spectra.real[band * spectra.frames + frame]
        let imag = spectra.imag[band * spectra.frames + frame]
        return real * real + imag * imag
    }
}

/// A double-precision complex number for the small per-band solves.
struct ComplexValue {
    var real: Double
    var imag: Double

    static let zero = ComplexValue(real: 0, imag: 0)

    var conjugate: ComplexValue {
        ComplexValue(real: real, imag: -imag)
    }

    static func * (lhs: ComplexValue, rhs: ComplexValue) -> ComplexValue {
        ComplexValue(real: lhs.real * rhs.real - lhs.imag * rhs.imag, imag: lhs.real * rhs.imag + lhs.imag * rhs.real)
    }

    static func - (lhs: ComplexValue, rhs: ComplexValue) -> ComplexValue {
        ComplexValue(real: lhs.real - rhs.real, imag: lhs.imag - rhs.imag)
    }

    static func -= (lhs: inout ComplexValue, rhs: ComplexValue) {
        lhs = lhs - rhs
    }

    static func / (lhs: ComplexValue, rhs: ComplexValue) -> ComplexValue {
        let scale = rhs.real * rhs.real + rhs.imag * rhs.imag
        guard scale > 0 else { return .zero }
        let product = lhs * rhs.conjugate
        return ComplexValue(real: product.real / scale, imag: product.imag / scale)
    }

    /// Solves `matrix * x = vector` for a small Hermitian positive-definite
    /// `matrix` (row-major, `count` × `count`) by Gaussian elimination.
    static func solve(matrix: inout [ComplexValue], vector: inout [ComplexValue], count: Int) -> [ComplexValue] {
        for pivot in 0 ..< count {
            let diagonal = matrix[pivot * count + pivot]
            for row in (pivot + 1) ..< count {
                let factor = matrix[row * count + pivot] / diagonal
                for column in pivot ..< count {
                    matrix[row * count + column] -= factor * matrix[pivot * count + column]
                }
                vector[row] -= factor * vector[pivot]
            }
        }
        var solution = [ComplexValue](repeating: .zero, count: count)
        for row in stride(from: count - 1, through: 0, by: -1) {
            var value = vector[row]
            for column in (row + 1) ..< count {
                value -= matrix[row * count + column] * solution[column]
            }
            solution[row] = value / matrix[row * count + row]
        }
        return solution
    }
}
