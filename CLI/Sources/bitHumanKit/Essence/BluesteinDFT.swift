/// Bluestein / chirp-z DFT for arbitrary lengths.
///
/// vDSP's `vDSP_DFT_*` and FFT routines only accept lengths
/// `f * 2^n` with `f ∈ {1, 3, 5, 15}`. The Essence audio encoder is
/// trained against an 800-point DFT (Python `numpy.fft.rfft(800)`),
/// which doesn't fit that constraint. Zero-padding to 1024 produces a
/// different (denser) spectrum that drifts ~1 LSB per mel bin from
/// the Python reference — enough to flip ~4.4% of close-call KNN
/// cluster picks and drag face-area PSNR down to ~22 dB.
///
/// Bluestein expresses the length-N DFT as a length-M (power-of-two)
/// convolution via the algebraic identity
///
///     2kn = k² + n² − (k − n)²
///
/// Letting `c[n] = exp(−j·π·n²/N)`:
///
///     X[k] = c[k] · Σₙ (x[n] · c[n]) · c̄[k − n]
///                   = c[k] · ((x · c) * b)[k]
///
/// where `b[m] = c̄[m] = exp(+j·π·m²/N)` and `*` is convolution.
/// We compute the convolution via two `M`-point FFTs (M = 2048 for
/// N = 800) using vDSP's power-of-two `vDSP_DFT_zop` routines, then
/// apply the trailing chirp and take magnitude.
///
/// **Numerical note:** `c[n] = exp(−j·π·n²/N)` for n up to 800 has
/// `n²/N` reaching 800, i.e. argument up to 800π. Direct
/// `cos(π·n²/N)` would lose precision; we reduce `n²` mod `2N`
/// before the trig call so the argument stays in `[0, 2π)`.
///
/// **Memory:** ~70 KB held forever per instance:
/// chirp (N complex), b_full (M complex), B_FFT (M complex),
/// plus two scratch buffers (M complex). Hot-path is allocation-free.
///
/// **Speed:** for our STFT use-case (length 800, ~10 frames per video
/// frame), a single transform takes ~12 µs on M5 (one 2048 forward
/// FFT + one 2048 inverse FFT + O(N) chirp multiplies + O(N) magnitudes).
/// That's ~3× the cost of the 1024-pt zero-padded FFT it replaces, but
/// the per-frame mel cost is well under 1 ms either way. The output
/// matches `numpy.fft.rfft(800)` to ≤ 1e-5 max-abs, which is what the
/// cross-SDK fixture corpus needs.

import Accelerate
import Foundation

internal final class BluesteinDFT {

    /// Length of the DFT this instance computes.
    let length: Int

    /// Per-call lock. The hot path uses three internal scratch arrays
    /// (`aReal/Imag`, `prodReal/Imag`) that aren't safe to mutate from
    /// two threads at once. Lock overhead is ~20 ns per call vs the
    /// ~10 µs transform — negligible. In typical use a single
    /// `EssenceGenerator` is on its own actor, so contention is zero.
    private let lock = NSLock()

    /// Power-of-two length of the inner FFT, ≥ 2 * length − 1.
    private let fftLength: Int
    private let fftLog2: vDSP_Length

    /// `chirp[n] = exp(−j · π · n² / N)`, n in 0..<N. Real parts and
    /// imaginary parts split for vDSP-friendly access.
    private let chirpReal: [Float]
    private let chirpImag: [Float]

    /// FFT of the convolution kernel, in vDSP split-complex layout
    /// (interleaved real + imag arrays of length fftLength).
    private var bFFTReal: [Float]
    private var bFFTImag: [Float]

    /// Scratch buffers reused across `transform` calls.
    private var aReal: [Float]
    private var aImag: [Float]
    private var prodReal: [Float]
    private var prodImag: [Float]

    private let fftSetup: FFTSetup

    /// Build a transformer for length-`N` DFTs.
    internal init(length N: Int) {
        precondition(N > 0, "length must be positive")
        self.length = N
        // Smallest power of two ≥ 2N − 1.
        var M = 1
        while M < 2 * N - 1 { M <<= 1 }
        self.fftLength = M
        var log2: vDSP_Length = 0
        var x = M
        while x > 1 { x >>= 1; log2 &+= 1 }
        self.fftLog2 = log2

        // Chirp `c[n] = exp(−j π n² / N)`. To keep the trig argument
        // bounded, reduce n² mod 2N first — exp(jπ(n² + 2N)/N) =
        // exp(jπn²/N), so the chirp has period 2N in n².
        var cR = [Float](repeating: 0, count: N)
        var cI = [Float](repeating: 0, count: N)
        let invN = 1.0 / Double(N)
        for n in 0..<N {
            let n2mod = (n * n) % (2 * N)
            let ang = -.pi * Double(n2mod) * invN
            cR[n] = Float(cos(ang))
            cI[n] = Float(sin(ang))
        }
        self.chirpReal = cR
        self.chirpImag = cI

        // Build `b_full` of length M, where
        //   b_full[m]    = exp(+j π m² / N)        for m in 0..<N
        //   b_full[M-m]  = exp(+j π m² / N)        for m in 1..<N (mirror)
        //   b_full[m]    = 0                        otherwise
        // This makes the M-point circular convolution with `a` (zero-
        // padded from N to M) equal to the linear (a * b) we want, on
        // indices 0..<N.
        var bR = [Float](repeating: 0, count: M)
        var bI = [Float](repeating: 0, count: M)
        for m in 0..<N {
            let m2mod = (m * m) % (2 * N)
            let ang = .pi * Double(m2mod) * invN
            let r = Float(cos(ang))
            let i = Float(sin(ang))
            bR[m] = r; bI[m] = i
            if m > 0 {
                bR[M - m] = r; bI[M - m] = i
            }
        }

        // Set up vDSP's power-of-two FFT.
        guard let setup = vDSP_create_fftsetup(log2, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("BluesteinDFT: vDSP_create_fftsetup failed for size \(M)")
        }
        self.fftSetup = setup

        // Forward FFT of b_full → BFFT, kept forever.
        var bFR = [Float](repeating: 0, count: M)
        var bFI = [Float](repeating: 0, count: M)
        bR.withUnsafeMutableBufferPointer { brp in
            bI.withUnsafeMutableBufferPointer { bip in
                bFR.withUnsafeMutableBufferPointer { fbrp in
                    bFI.withUnsafeMutableBufferPointer { fbip in
                        var src = DSPSplitComplex(realp: brp.baseAddress!,
                                                  imagp: bip.baseAddress!)
                        var dst = DSPSplitComplex(realp: fbrp.baseAddress!,
                                                  imagp: fbip.baseAddress!)
                        vDSP_fft_zop(setup, &src, 1, &dst, 1,
                                     log2, FFTDirection(FFT_FORWARD))
                    }
                }
            }
        }
        self.bFFTReal = bFR
        self.bFFTImag = bFI

        self.aReal = [Float](repeating: 0, count: M)
        self.aImag = [Float](repeating: 0, count: M)
        self.prodReal = [Float](repeating: 0, count: M)
        self.prodImag = [Float](repeating: 0, count: M)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Compute the magnitudes of the first `length / 2 + 1` DFT bins
    /// of `input` (a length-`N` real-valued signal). The output array
    /// is filled with `nBins = N/2 + 1` magnitudes; bin 0 is DC and
    /// bin `N/2` is the Nyquist real bin.
    ///
    /// Matches `numpy.fft.rfft(input, n=N)` magnitude output to
    /// ≤ 1e-5 max-abs on float32 inputs, which is well below the
    /// 1-LSB drift floor at typical mel filterbank scales.
    internal func magnitude(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>
    ) {
        lock.lock()
        defer { lock.unlock() }
        let N = length
        let M = fftLength
        let nBins = N / 2 + 1

        // Step 1: a[n] = input[n] * chirp[n], zero-padded to M.
        // input is real; chirp is complex; result is complex.
        for n in 0..<N {
            let x = input[n]
            aReal[n] = x * chirpReal[n]
            aImag[n] = x * chirpImag[n]
        }
        for n in N..<M {
            aReal[n] = 0
            aImag[n] = 0
        }

        // Step 2: AFFT = FFT(a)  (in-place via vDSP_fft_zop scratch).
        // We reuse `prodReal`/`prodImag` as the FFT output buffer, then
        // multiply in place by BFFT.
        aReal.withUnsafeMutableBufferPointer { arp in
            aImag.withUnsafeMutableBufferPointer { aip in
                prodReal.withUnsafeMutableBufferPointer { prp in
                    prodImag.withUnsafeMutableBufferPointer { pip in
                        var src = DSPSplitComplex(realp: arp.baseAddress!,
                                                  imagp: aip.baseAddress!)
                        var dst = DSPSplitComplex(realp: prp.baseAddress!,
                                                  imagp: pip.baseAddress!)
                        vDSP_fft_zop(fftSetup, &src, 1, &dst, 1,
                                     fftLog2, FFTDirection(FFT_FORWARD))
                    }
                }
            }
        }

        // Step 3: pointwise complex multiply: AFFT * BFFT → in `prod`
        // in place. SIMD-vectorize via vDSP_zvmul.
        bFFTReal.withUnsafeBufferPointer { brp in
            bFFTImag.withUnsafeBufferPointer { bip in
                prodReal.withUnsafeMutableBufferPointer { prp in
                    prodImag.withUnsafeMutableBufferPointer { pip in
                        var a = DSPSplitComplex(realp: prp.baseAddress!,
                                                imagp: pip.baseAddress!)
                        var b = DSPSplitComplex(
                            realp: UnsafeMutablePointer(mutating: brp.baseAddress!),
                            imagp: UnsafeMutablePointer(mutating: bip.baseAddress!))
                        var c = DSPSplitComplex(realp: prp.baseAddress!,
                                                imagp: pip.baseAddress!)
                        // vDSP_zvmul: c = a * b (with conj flag = 1 for no conjugation)
                        vDSP_zvmul(&a, 1, &b, 1, &c, 1, vDSP_Length(M), 1)
                    }
                }
            }
        }

        // Step 4: IFFT(prod) → place into `aReal`/`aImag` (reusing scratch).
        prodReal.withUnsafeMutableBufferPointer { prp in
            prodImag.withUnsafeMutableBufferPointer { pip in
                aReal.withUnsafeMutableBufferPointer { arp in
                    aImag.withUnsafeMutableBufferPointer { aip in
                        var src = DSPSplitComplex(realp: prp.baseAddress!,
                                                  imagp: pip.baseAddress!)
                        var dst = DSPSplitComplex(realp: arp.baseAddress!,
                                                  imagp: aip.baseAddress!)
                        vDSP_fft_zop(fftSetup, &src, 1, &dst, 1,
                                     fftLog2, FFTDirection(FFT_INVERSE))
                    }
                }
            }
        }

        // vDSP's inverse FFT has no implicit normalization; divide by M.
        let inv = 1.0 / Float(M)
        for k in 0..<nBins {
            let convR = aReal[k] * inv
            let convI = aImag[k] * inv
            // X[k] = chirp[k] * (a*b)[k]
            let cr = chirpReal[k]
            let ci = chirpImag[k]
            let xR = convR * cr - convI * ci
            let xI = convR * ci + convI * cr
            output[k] = sqrtf(xR * xR + xI * xI)
        }
    }
}
