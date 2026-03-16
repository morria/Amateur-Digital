# Resilient and Reliable Signal Processing on iOS

A comprehensive survey of state-of-the-art signal processing techniques for each digital mode supported by Amateur Digital, with comparison to fldigi, WSJT-X, CW Skimmer, and academic literature. Goal: ensure we use every known technique for reliable decoding under real-world HF conditions.

---

## Table of Contents

1. [RTTY / FSK](#1-rtty--fsk)
2. [PSK31 / BPSK63 / QPSK31 / QPSK63](#2-psk-modes)
3. [CW (Morse Code)](#3-cw-morse-code)
4. [JS8Call](#4-js8call)
5. [Cross-Mode DSP Infrastructure](#5-cross-mode-dsp-infrastructure)
6. [iOS-Specific Optimization](#6-ios-specific-optimization)
7. [Prioritized Improvement Roadmap](#7-prioritized-improvement-roadmap)
8. [References](#8-references)

---

## 1. RTTY / FSK

### 1.1 Current Implementation

Our RTTY decoder uses dual Goertzel filters at the mark and space frequencies, a normalized correlation metric `(mark - space) / (mark + space)`, adaptive squelch with fast-attack/slow-decay tracking, 4th-order Butterworth IIR bandpass pre-filtering (~40 dB out-of-band rejection), a bit-level state machine with 4 analysis blocks per bit, and AFC via 5-offset Goertzel scanning at [-50, -25, 0, +25, +50] Hz.

### 1.2 Techniques Used by fldigi

Fldigi's RTTY decoder, designed by Dave Freese (W1HKJ) based on theoretical work by Kok Chen (W7AY), employs significantly more sophisticated signal processing:

**FFT-based Bandpass Filtering.** Instead of IIR biquad filters, fldigi uses a Fast Overlap-and-Add Fourier Transform convolution with 256-512 tap FIR filters. This achieves -73 dB stopband rejection vs our ~40 dB, yielding approximately 4-6 dB improvement in the presence of adjacent-channel interference. The overlap-add method processes blocks efficiently: compute FFTs of both audio and filter coefficients, perform pointwise multiplication in the frequency domain, inverse FFT, and overlap-add the tail samples.

**Optimal ATC (Automatic Threshold Correcting) Detector.** This is the single highest-impact technique we lack. Developed by Kok Chen (W7AY), the optimal ATC handles selective fading where one tone (mark or space) fades independently:

```
// Optimal ATC core (from W7AY's paper)
m_clipped = max(0, min(m - noise_floor, envelope_m - noise_floor))
s_clipped = max(0, min(s - noise_floor, envelope_s - noise_floor))
v = (m_clipped) * (env_m - nf) - (s_clipped) * (env_s - nf)
    - 0.5 * ((env_m - nf)^2 - (env_s - nf)^2)
```

Performance at 45.45 baud with 10 dB mark/space imbalance:
| Method | Gain over no-ATC |
|--------|-----------------|
| Linear ATC | +5.7 dB |
| Clipped ATC | +6.2 dB |
| **Optimal ATC** | **+6.7 dB** |

The optimal ATC automatically behaves as a mark-only or space-only demodulator during deep selective fading, eliminating the 3 dB noise penalty of traditional ATC during extreme fades.

**Dual-Rate Envelope/Noise Tracking.** Fldigi tracks both the signal envelope (fast-charge, slow-discharge) and the noise floor independently for each channel. The noise floor estimate is subtracted before the ATC decision, improving SNR by 1-2 dB.

**Transition-Detection Symbol Timing.** Rather than sampling at the center of each bit, fldigi detects mark-space and space-mark transitions and uses them to refine bit timing. This improves performance by 1-2 dB, especially with timing jitter from multipath.

**Phase-Based AFC.** Instead of our quantized 25 Hz Goertzel scanning, fldigi extracts phase information from the complex mixer output for continuous frequency tracking with sub-Hz resolution. This provides ~2 dB improvement under drift conditions.

### 1.3 Additional Techniques from Literature

**Matched Filter Detection.** The theoretically optimal FSK detector uses matched filters (correlators) at the mark and space frequencies, each integrating over exactly one bit period. This is the maximum-likelihood detector for AWGN and provides the best possible BER performance. At 45.45 baud, the optimal filter cutoff is 22.7 Hz (Nyquist criterion for zero ISI at sampling points).

**Raised Cosine Nyquist Filter.** W7AY recommends an equalized raised cosine filter with roll-off factor tuned for the specific baud rate. This satisfies the Nyquist ISI criterion while providing good stopband rejection. Implementation via FFT overlap-and-add convolution is critical — time-domain FIR would require impractically many taps at audio sample rates.

**Kahn Ratio Squarer.** Leonard Kahn's method squares both mark and space detector outputs before forming the decision variable. W7AY demonstrated this performs equivalently to Optimal ATC when combined with clipping, with slight advantages below -7 dB SNR.

**Spectral SNR Measurement.** Computing real-time SNR from the ratio of mark+space power to adjacent-band noise power enables intelligent squelch and signal quality reporting. Fldigi displays this as a numeric readout.

**Limiterless (AM) Detection.** Frank Gaude showed that the historical limiter-discriminator design was fundamentally flawed for HF: it produces unequal output durations under selective fading. All modern demodulators should use "limiterless" (AM envelope) detection with ATC. Our Goertzel-based approach is correctly limiterless.

### 1.4 Estimated Gap vs fldigi

| Technique | Impact | Status |
|-----------|--------|--------|
| FFT bandpass filter | +4-6 dB | Missing |
| Optimal ATC detector | +2-3 dB | Missing |
| Dual-rate envelope tracking | +1-2 dB | Partial (basic AGC) |
| Transition-detection timing | +1-2 dB | Missing |
| Phase-based AFC | +2 dB | Missing (quantized scanning) |
| **Total estimated gap** | **~10-15 dB** | |

---

## 2. PSK Modes

### 2.1 Current Implementation

Our PSK decoder uses IQ quadrature mixing with a phase accumulator NCO, integrate-and-dump matched filtering over one symbol period, 1-pole IIR lowpass on I/Q channels, early-late symbol timing recovery (compares first-quarter vs last-quarter magnitude), differential phase detection (BPSK via dot product, QPSK via atan2), two-phase AFC (preamble estimation + decision-directed tracking), phase quality metric for signal detection, and 4th-order Butterworth IIR bandpass pre-filtering.

### 2.2 Techniques Used by fldigi

**FIR Matched Filter.** Fldigi uses an optimized FIR filter matched to the PSK31 pulse shape (raised-cosine with specific G3PLX shaping) rather than a simple integrate-and-dump. This provides 2-3 dB improvement because it optimally weights samples within each symbol period, de-emphasizing the noisy transition regions.

**Decimation.** Fldigi downsamples from the input rate to a lower processing rate (typically 8x the symbol rate) early in the chain. This reduces computational load and allows longer FIR filters without excessive CPU use. Our decoder processes all 48,000 samples/sec through every stage.

**Soft-Decision Viterbi Decoder for QPSK.** This is the most impactful missing technique for QPSK modes. PSK31's QPSK variant uses a rate-1/2, constraint-length-5 convolutional code. Fldigi implements a soft-decision Viterbi decoder that uses multi-bit confidence values from the demodulator rather than hard 0/1 decisions. Per Phil Karn (KA9Q), soft-decision decoding provides approximately 2-3 dB coding gain over hard-decision decoding. Combined with the underlying convolutional code gain of ~5 dB, QPSK31 should achieve ~7-8 dB total coding gain. Our QPSK implementation makes hard decisions only, forfeiting the soft-decision advantage entirely.

**Convolutional Encoder/Decoder.** The convolutional code used in QPSK31/63 is rate-1/2 with constraint length K=5 (the "NASA Voyager" code, polynomials tapping stages 1,3,4,6,7 and 1,2,3,4,7). The Viterbi decoder maintains 16 states (2^(K-1)) and uses the Add/Compare/Select (ACS) operation. A traceback depth of 5*(K-1) = 20 bits is standard. Per MATLAB documentation, soft-decision Viterbi with 3-bit quantization achieves approximately 2 dB gain over hard decisions at BER = 10^-5.

**Block Interleaving.** QPSK31 uses a rectangular block interleaver to spread burst errors (from fading) across multiple codewords. Without interleaving, a single fade can corrupt an entire codeword; with interleaving, the errors are distributed so the Viterbi decoder can correct them. This provides 2-3 dB improvement in fading channels.

**Gray-Coded Constellation.** Proper Gray coding of the QPSK constellation (00, 01, 11, 10 mapping) ensures that adjacent constellation points differ by only one bit. This minimizes the number of bit errors per symbol error and is essential for soft-decision decoding to work optimally.

**Multi-Tone Goertzel SNR/IMD Measurement.** Fldigi computes signal-to-noise ratio and intermodulation distortion (IMD) in real-time using four Goertzel filters placed at specific offsets around the carrier. This drives the signal quality display and adaptive squelch.

**Gardner/Mueller-Muller Timing Recovery.** More sophisticated symbol timing recovery algorithms (Gardner, Mueller-Muller) use feedback loops that converge faster and track better than the simple early-late approach we use. Gardner's algorithm requires only one sample per symbol for the error computation, while Mueller-Muller uses decision-directed feedback.

### 2.3 Additional Techniques from Literature

**Costas Loop Carrier Recovery.** A second-order PLL (Costas loop) provides continuous carrier phase tracking that is more robust than our decision-directed approach, especially at low SNR where decision errors corrupt the phase estimate.

**Pilot-Aided Synchronization.** Some advanced PSK implementations insert known pilot symbols periodically for channel estimation, enabling coherent detection even through deep fades. Not used in PSK31 but relevant for future modes.

**Turbo Equalization.** Iterating between the equalizer and decoder can improve performance in multipath channels. This is computationally expensive but potentially relevant for the most challenging conditions.

### 2.4 Estimated Gap vs fldigi

| Technique | Impact | Status |
|-----------|--------|--------|
| FIR matched filter | +2-3 dB | Missing (integrate-and-dump only) |
| Soft-decision Viterbi | +2-3 dB (QPSK only) | Missing (hard decisions) |
| Convolutional FEC | +5 dB (QPSK only) | Missing entirely |
| Block interleaving | +2-3 dB (fading) | Missing |
| Decimation | CPU, not dB | Missing |
| Gardner timing recovery | +1-2 dB | Missing |
| Gray-coded constellation | Correctness | Needs verification |
| **Total gap (BPSK)** | **~3-5 dB** | |
| **Total gap (QPSK)** | **~12-16 dB** | |

---

## 3. CW (Morse Code)

### 3.1 Current Implementation

Our CW decoder is the most mature mode, scoring 96.3/100 on a comprehensive benchmark. It uses Goertzel tone detection at configurable frequency, 10ms analysis blocks (~480 samples), adaptive threshold with fast-attack/slow-decay, bandpass pre-filtering centered on tone, an idle/in-tone/after-tone state machine, adaptive speed tracking via dot-dash pair validation, AFC via multi-bin Goertzel scanning (±250 Hz in 25 Hz steps), Morse binary tree character lookup, and QSB fading resistance via recent-signal threshold adaptation.

### 3.2 Techniques Used by CW Skimmer

CW Skimmer, developed by Alex Shovkoplyas (VE3NEA), is widely regarded as the gold standard for CW decoding:

**Bayesian Statistical Framework.** Rather than making hard threshold decisions at each sample, CW Skimmer expresses all prior knowledge as probabilities and uses observed data to update them via Bayes' theorem. This fundamentally different approach provides better noise immunity because uncertain elements contribute proportionally to their confidence rather than being forced into binary decisions.

**Hidden Markov Model (HMM).** The decoder models Morse code as a hidden Markov process where the "hidden" states are the intended dits, dahs, and gaps, and the "observed" data is the noisy tone detection output. The Viterbi algorithm finds the most probable sequence of hidden states given the observations. This is theoretically optimal for this class of problem.

**Histogram-Based Speed Estimation.** Instead of tracking speed from individual dit/dah measurements, CW Skimmer builds timing histograms over a sliding window. The histograms reveal the true dit/dah distribution peaks even in noise, enabling robust speed adaptation. Conditional probabilities are computed: P(dit|x) = P(x|dit)*P(dit) / P(x).

**Multi-Channel FFT Processing.** CW Skimmer monitors hundreds of CW signals simultaneously using a single large FFT, then extracts individual channels from the frequency bins. This is fundamentally more efficient than our approach of one Goertzel filter per channel.

### 3.3 The RSCW Approach (PA3FWM)

RSCW uses a novel combination of techniques:

**IQ Demodulation.** The signal is multiplied with a locally generated carrier to produce I and Q components, preserving phase information that envelope detection discards. The Pythagorean sum sqrt(I^2 + Q^2) produces a phase-independent magnitude signal.

**Dibit-Level Viterbi Decoding.** RSCW exploits a fundamental property of Morse code: the sequence "01" (space followed by mark without a gap) never occurs. This constraint dramatically reduces the state space for a Viterbi-like decoder, enabling soft-decision character recognition that is "theoretically optimal for decoding OOK signals in AWGN."

**Balanced-Mean Threshold.** The threshold is set such that the average distance between the threshold and samples above it equals the average distance between the threshold and samples below it. This prevents bias from unequal signal-present/signal-absent distributions.

### 3.4 Fldigi's SOM Decoder

Fldigi includes a Self-Organizing Map (SOM) decoder that normalizes dit/dah duration patterns and computes Euclidean distance to codebook entries. Combined with a matched filter front-end, this enables CW decoding from **-3 dB SNR** upward — a ~4 dB improvement over threshold-based decoders. The SOM adapts to individual operator timing patterns without explicit speed estimation.

### 3.5 Techniques from Academic Literature

**Deep Learning CW Decoders.** The MorseAngel project (F4EXB) uses two LSTM layers + Dense layer with CTC loss, trained on 50+ hours of generated audio. It achieves 1.5% character error rate and 97.2% word accuracy, decoding to approximately -3 dB SNR. The architecture uses "look-back" windows corresponding to the longest Morse character (5 elements). AG1LE has also demonstrated CNN-LSTM-CTC models for real-time CW decoding.

**Matched Filter Bank.** Computing correlation with stored dit and dah templates at multiple speeds simultaneously, then selecting the best match. More computationally expensive than Goertzel but provides better SNR at the decision point.

**Spectral Line Detection.** Using high-resolution FFT to detect the narrow spectral line of a CW signal in the frequency domain, then tracking its amplitude and phase over time. This enables detection of signals well below the noise floor.

### 3.5 Estimated Gap vs CW Skimmer

| Technique | Impact | Status |
|-----------|--------|--------|
| Bayesian framework | +2-4 dB in noise | Not implemented |
| HMM/Viterbi character recognition | +1-3 dB | Not implemented (binary tree only) |
| Histogram speed estimation | Robustness | Not implemented (pair validation) |
| IQ demodulation (phase) | +1-2 dB AFC | Partial (magnitude only) |
| Multi-channel FFT | Efficiency | Not implemented |
| **Total gap** | **~4-9 dB** | **Benchmark: 96.3/100** |

Our CW decoder is strong for clean-to-moderate conditions but leaves room for improvement at the extreme low-SNR end where Bayesian methods excel.

---

## 4. JS8Call

### 4.1 Current Implementation

Our JS8Call decoder implements the full FT8-derived pipeline: Nuttall-windowed spectrogram (NFFT1=2*NSPS, step=NSPS/4), Costas array correlation with partial sync (AB/BC/ABC), candidate selection with 40th-percentile baseline normalization, DFT-based symbol extraction, dual soft metrics (linear + log amplitude), belief propagation LDPC decoder (30 iterations, early stopping), OSD fallback decoder, CRC-12 verification (XOR 42), multi-pass decoding with signal subtraction, UTC-aligned decode timing, and background DispatchQueue processing.

### 4.2 Techniques Used by WSJT-X / JS8Call

**Frequency-Domain Downsampling.** The original Fortran decoder performs downsampling in the frequency domain: a large FFT of the entire audio segment, extraction of bins around the candidate frequency, taper, shift to baseband, and inverse FFT at reduced size. This is more efficient and potentially more accurate than our time-domain DFT approach.

**Fine Frequency/Time Refinement.** After coarse sync detection, WSJT-X searches ±2.5 Hz in 0.5 Hz steps using complex correlation against Costas waveforms in the downsampled domain. Our implementation does coarse sync but the fine refinement step could be more thorough.

**OSD Depth Optimization.** The JS8Call C++ rewrite (by W6BAZ) fixed the OSD depth to 2 and removed the Fortran version's variable depth. The Fortran version used depths 1-5 with increasing computational cost. We implement variable depth but should profile the cost/benefit tradeoff on iOS hardware.

**Shuffled BP Scheduling.** Recent LDPC research shows that sequential (serial) variable-node updates converge approximately twice as fast as the traditional flooding schedule. Randomized sequential update ("shuffled BP") mitigates short-cycle effects. Our BP implementation uses the standard flooding approach.

**Polynomial Baseline Estimation.** The C++ rewrite improved the baseline estimation by using Chebyshev nodes (proportional to polynomial degree) instead of the Fortran's naive 10th-percentile approach, avoiding Runge's phenomenon in the polynomial fit. Our implementation should adopt the Chebyshev approach.

### 4.3 Techniques from FT8/FT4 Literature

From Franke & Taylor's QEX paper on FT4/FT8:

**8-GFSK Modulation.** FT8 uses Gaussian-smoothed FSK where symbol transitions are smoothed with a Gaussian filter. This reduces spectral splatter and may improve decoder performance. Our modulator generates continuous-phase FSK but without explicit Gaussian shaping.

**AP (A Priori) Decoding.** WSJT-X can exploit known information (e.g., your own callsign, the CQ prefix) to assist decoding by fixing certain bits in the LDPC decoder. This provides 1-3 dB improvement for messages containing known content.

**Deep Decode Multi-Pass.** WSJT-X's "deep search" mode runs up to 3 passes with progressively deeper OSD, combined with signal subtraction. Each pass can reveal signals that were previously masked. WSJT-X routinely decodes 30+ signals per 15-second interval, with signals "two and three deep" under stronger ones.

**Min-Sum LDPC Approximation.** The BP decoder's tanh computations can be replaced with a min-sum approximation (replaces hyperbolic tangent product with minimum operation). The Generalized Adjusted Min-Sum (GA-MS) variant achieves within 0.1 dB of floating-point BP while being much simpler and faster. This is relevant for mobile implementation where battery life matters.

**Hybrid BP+OSD Gains.** Per the FT4/FT8 QEX paper, the combination provides: block detection +1.6 dB (FT4) / +0.7 dB (FT8), and hybrid BP+OSD adds +0.6 dB (FT4) / +0.5 dB (FT8), for a total of 2.2 dB (FT4) and 1.2 dB (FT8) over the baseline decoder.

### 4.4 Estimated Improvement Opportunities

| Technique | Impact | Status |
|-----------|--------|--------|
| Frequency-domain downsampling | Accuracy + speed | Time-domain DFT currently |
| Fine freq/time refinement | +0.5-1 dB | Partial |
| Shuffled BP scheduling | 2x faster convergence | Not implemented |
| Chebyshev baseline | Robustness | Not implemented |
| A priori decoding | +1-3 dB known content | Not implemented |
| Gaussian pulse shaping (TX) | Spectral cleanliness | Not implemented |

---

## 5. Cross-Mode DSP Infrastructure

### 5.1 FFT-Based Bandpass Filtering

The single highest-impact infrastructure improvement. An overlap-add FFT convolution engine would benefit RTTY (+4-6 dB), PSK (+2-3 dB), and CW (spectral analysis). The implementation:

1. Pre-compute the FFT of the FIR filter coefficients (one-time cost)
2. For each block of audio: zero-pad, FFT, multiply by filter FFT, IFFT
3. Overlap-add the tail samples to the next block
4. Block size should be a power of 2, typically 256 or 512 samples

This replaces the current IIR biquad filters and provides:
- Steeper rolloff (512-tap FIR = 256th-order equivalent)
- Linear phase (no group delay distortion)
- -73 dB or better stopband rejection (vs our -40 dB)
- Arbitrary filter shapes (notch, multi-bandpass, etc.)

### 5.2 Automatic Gain Control

A proper dual-loop AGC benefits all modes:

**Fast Loop.** Tracks rapid signal level changes (QSB fading). Time constant: 10-50ms attack, 200-500ms decay. Normalizes the signal to a constant level before the demodulator.

**Slow Loop.** Tracks the overall noise floor. Time constant: 1-5 seconds. Provides the baseline for squelch decisions and SNR measurement.

**Implementation.** Digital AGC using a first-order recursive filter:
```
gain = gain * (1 - alpha) + target_level / signal_level * alpha
```
With separate alpha values for attack (larger, ~0.01-0.1) and decay (smaller, ~0.001-0.01).

### 5.3 Spectral Noise Reduction

**Spectral Subtraction.** Estimate the noise spectrum during signal-absent periods, then subtract it from the signal spectrum. The subtraction factor is typically 0.8-1.2 to avoid over-subtraction artifacts ("musical noise"). This is used by commercial HF DSP noise reducers (bhi, West Mountain Radio ClearSpeech) and provides 3-6 dB perceptual improvement.

**Adaptive Wiener Filter.** A more sophisticated approach that computes the optimal filter as H(f) = max(0, 1 - noise_spectrum/signal_spectrum). This minimizes mean-square error and avoids the musical noise artifacts of spectral subtraction.

### 5.4 Noise Blanking

For impulsive noise (ignition, switching power supplies), a time-domain blanker detects and zeros short impulses before they corrupt the decoder. Implementation: detect samples exceeding N*sigma threshold, replace with interpolated values or zeros. The blanking window should be short enough (0.5-2ms) to avoid corrupting the desired signal.

### 5.5 Waterfall / Spectrum Display

A real-time power spectral density display serves as both a user interface for signal identification and an input to automatic signal detection. Computing the PSD via windowed FFT (Hann or Blackman-Harris window, 50% overlap) at 4-10 FPS is computationally feasible on iOS using the Accelerate framework.

---

## 6. iOS-Specific Optimization

### 6.1 Apple Accelerate Framework

The Accelerate framework provides SIMD-optimized implementations of common DSP operations on ARM NEON hardware:

**vDSP FFT.** `vDSP_fft_zripD` (double) and `vDSP_fft_zrip` (float) provide radix-2 FFT that is 10-50x faster than naive implementations. A 4096-point FFT takes ~5 microseconds on an A-series chip vs ~200 microseconds for our pure-Swift implementation.

**vDSP Vector Operations.** `vDSP_vadd`, `vDSP_vmul`, `vDSP_vsmul` for element-wise arithmetic, `vDSP_meanv` for mean, `vDSP_measqv` for mean-square (power measurement), `vDSP_maxvi` for peak detection.

**vDSP Convolution.** `vDSP_conv` for FIR filtering, `vDSP_desamp` for decimation with filtering.

**vDSP Biquad.** `vDSP_biquad` for IIR filtering (our current bandpass filters could use this for a modest speedup).

### 6.2 Performance Budget

At 48 kHz mono with 4096-sample blocks (~85ms per block):

| Operation | Pure Swift | Accelerate | Budget |
|-----------|-----------|------------|--------|
| 4096-pt FFT | ~200 us | ~5 us | Abundant |
| FIR filter (256 taps) | ~2 ms | ~50 us | Comfortable |
| Goertzel (per block) | ~10 us | ~3 us | Abundant |
| LDPC BP (30 iter) | ~50 ms | N/A (custom) | Tight |

The main bottleneck is the LDPC decoder for JS8Call, which is inherently sequential and cannot be vectorized. Our background-queue approach handles this correctly.

### 6.3 Audio Pipeline Considerations

**AVAudioEngine Buffer Size.** The default 4096-sample buffer at 48 kHz provides 85ms latency. For RTTY/PSK this is fine. For CW at high WPM, consider requesting smaller buffers (1024 or 2048 samples) to reduce decode latency to 21-42ms.

**Sample Rate Conversion.** We currently receive 48 kHz from the audio engine. Most decoders benefit from downsampling to 8 kHz or 12 kHz early in the chain. Using `AVAudioConverter` or `vDSP_desamp` for this step would reduce computational load in all subsequent stages by 4-6x.

**Thread Safety.** Audio callbacks run on a real-time thread. All heavy processing (FFT, LDPC, multi-channel scanning) should be dispatched to background queues. Our JS8Call and Rattlegram decoders do this correctly; RTTY and PSK process synchronously and should be moved to background queues for robustness.

---

## 7. Prioritized Improvement Roadmap

Ranked by impact-to-effort ratio:

### Tier 1: High Impact, Moderate Effort

1. **Optimal ATC for RTTY** (+2-3 dB, ~200 lines of code)
   - Implement W7AY's clipped/optimal ATC detector
   - Add dual-rate envelope and noise floor tracking
   - Estimated: 1-2 days

2. **FFT Overlap-Add Bandpass Filter** (+4-6 dB RTTY, +2-3 dB PSK)
   - Replace IIR biquads with FFT-based FIR convolution
   - Configurable tap count (256-512) per mode
   - Use vDSP for FFT on iOS for 50x speedup
   - Estimated: 2-3 days

3. **Soft-Decision Viterbi for QPSK** (+5-8 dB total QPSK gain)
   - Implement K=5 rate-1/2 convolutional encoder/decoder
   - 3-bit soft quantization from demodulator
   - Add block interleaver/deinterleaver
   - Estimated: 3-5 days

### Tier 2: Moderate Impact, Low-Moderate Effort

4. **Decimation Pipeline** (CPU reduction, enables longer filters)
   - Downsample to 8 kHz for RTTY/PSK, 12 kHz for JS8Call
   - Anti-alias LPF using vDSP_desamp
   - Estimated: 1 day

5. **Gardner Symbol Timing Recovery** (+1-2 dB PSK)
   - Replace early-late with Gardner TED
   - Second-order PLL for timing loop filter
   - Estimated: 1-2 days

6. **Proper AGC** (+1-2 dB all modes)
   - Dual-loop fast/slow AGC before each demodulator
   - Per-channel AGC for multi-channel modes
   - Estimated: 1 day

7. **Phase-Based AFC for RTTY** (+2 dB under drift)
   - Extract phase from complex Goertzel output
   - Continuous frequency tracking instead of 25 Hz steps
   - Estimated: 1 day

### Tier 3: Moderate Impact, Higher Effort

8. **Bayesian CW Decoder** (+2-4 dB in extreme noise)
   - Histogram-based speed estimation
   - Probabilistic character recognition
   - Would improve the 88/100 noise category to ~95/100
   - Estimated: 5-7 days

9. **Frequency-Domain Downsampling for JS8Call** (accuracy + speed)
   - Port the Fortran js8_downsample approach
   - Large FFT, extract band, IFFT at reduced size
   - Estimated: 2-3 days

10. **A Priori Decoding for JS8Call** (+1-3 dB known content)
    - Fix bits corresponding to own callsign/CQ prefix
    - Modify LDPC decoder to accept fixed-bit constraints
    - Estimated: 2-3 days

### Tier 4: Research / Future

11. **Spectral Noise Reduction** (3-6 dB perceptual, all modes)
    - Spectral subtraction or Wiener filter pre-processing
    - Risk of artifacts with aggressive subtraction

12. **Multi-Channel FFT Channelizer** (efficiency for RTTY/CW)
    - Replace per-channel Goertzel with single FFT
    - Extract all channels from frequency bins

13. **Deep Learning CW** (research)
    - CNN/LSTM for extreme noise conditions
    - Requires training data collection

14. **Turbo Equalization** (research)
    - Iterative equalizer-decoder for multipath PSK
    - Very high computational cost

---

## 8. SNR Reference Table (2500 Hz Bandwidth)

| Mode | SNR Threshold | Eb/N0 | Excess over Shannon |
|------|:---:|:---:|:---:|
| SSB (voice) | +6 to +10 dB | ~31 dB | ~33 dB |
| RTTY (45.45 baud) | -5 to -9 dB | ~14 dB | ~16 dB |
| PSK31 (BPSK) | -8 to -10 dB | ~9 dB | ~11 dB |
| CW (by ear, 20 WPM) | -12 to -18 dB | ~16 dB | ~18 dB |
| CW (machine, best) | -3 dB | — | — |
| FT8 | -20 dB | — | — |
| FT4 | -17.5 dB | — | — |
| JS8Call (Normal) | -24 dB | — | — |
| JT65 | -24 dB | ~5 dB | ~7 dB |
| WSPR | -28 dB | ~5 dB | ~7 dB |

The large "excess over Shannon" values for RTTY and PSK31 indicate significant room for improvement through better signal processing. FT8/JS8Call/WSPR are much closer to the theoretical limit.

---

## 9. References

### RTTY / FSK
- Kok Chen (W7AY), [Improved Automatic Threshold Correction Methods for FSK](http://www.w7ay.net/site/Technical/ATC/) - The definitive reference for optimal FSK demodulation under selective fading
- Dave Freese (W1HKJ), [Fldigi RTTY Documentation](http://www.w1hkj.com/FldigiHelp/rtty_page.html) - Implementation details of fldigi's RTTY decoder
- [Frequency-shift keying (Wikipedia)](https://en.wikipedia.org/wiki/Frequency-shift_keying) - Theoretical background on FSK detection methods

### PSK
- Phil Karn (KA9Q), [Convolutional Decoders for Amateur Packet Radio](http://www.ka9q.net/papers/cnc_coding.html) - Viterbi decoder implementation for amateur radio, K=7 rate-1/2
- [Viterbi decoder (Wikipedia)](https://en.wikipedia.org/wiki/Viterbi_decoder) - Comprehensive overview of hard vs soft decision decoding
- MathWorks, [Estimate BER for Hard and Soft Decision Viterbi Decoding](https://www.mathworks.com/help/comm/ug/estimate-ber-for-hard-and-soft-decision-viterbi-decoding.html) - Quantified performance comparison

### CW (Morse Code)
- Mauri Niininen (AG1LE), [Towards Bayesian Morse Decoder](http://ag1le.blogspot.com/2013/01/towards-bayesian-morse-decoder.html) - Probabilistic CW decoding framework
- Pieter-Tjerk de Boer (PA3FWM), [RSCW Algorithm](http://www.pa3fwm.nl/software/rscw/algorithm.html) - Theoretically optimal OOK decoder using dibit-level Viterbi
- [CW Skimmer (Wikipedia)](https://en.wikipedia.org/wiki/CW_Skimmer) - Multi-channel Bayesian CW decoder by VE3NEA

### JS8Call / FT8
- S. Franke & J. Taylor, [The FT4 and FT8 Communication Protocols](https://wsjt.sourceforge.io/FT4_FT8_QEX.pdf) - Definitive protocol specification
- [WSJT-X User Guide](https://wsjt-x-improved.sourceforge.io/wsjtx-main_en.html) - Decoder configuration and behavior
- [PyFT8](https://github.com/G1OJS/PyFT8) - Python FT8 implementation for research

### General DSP
- [Overlap-add method (Wikipedia)](https://en.wikipedia.org/wiki/Overlap%E2%80%93add_method) - Efficient convolution for real-time filtering
- Julius O. Smith, [Spectral Audio Signal Processing: Overlap-Add STFT Processing](https://www.dsprelated.com/freebooks/sasp/Overlap_Add_OLA_STFT_Processing.html) - Comprehensive reference
- [AGC in Receivers](https://www.qsl.net/va3iul/Files/Automatic_Gain_Control.pdf) - Digital AGC implementation theory
- [Liquid SDR: AGC](https://www.liquidsdr.org/doc/agc/) - Open-source AGC reference implementation

### Noise Reduction
- [Spectral Subtraction (DSP textbook chapter)](https://dsp-book.narod.ru/304.pdf) - Theory and processing distortions
- West Mountain Radio, [ClearSpeech Adaptive DSP](https://www.westmountainradio.com/content.php?page=digital_process) - Commercial HF noise reduction product
- [RadioDSP-DNR (GitHub)](https://github.com/gcallipo/RadioDSP-DNR-Stm32f407) - Open-source spectral subtraction for shortwave

### iOS / Apple
- Apple Developer Documentation: Accelerate > vDSP - FFT, convolution, vector operations
- Apple Developer Documentation: AVAudioEngine - Real-time audio I/O

---

### Additional References (from background research)
- W7AY, [RTTY Demodulators: A Historical Survey](http://w7ay.net/site/Technical/RTTY%20Demodulators/)
- W7AY, [Equalized Raised Cosine Filter](http://w7ay.net/site/Technical/EqualizedRaisedCosine/index.html)
- PA3FWM, [Signal/Noise Ratio of Digital Amateur Modes](http://www.pa3fwm.nl/technotes/tn09b.html)
- PA3FWM, [Squelch Algorithms for Digital Modes](https://pa3fwm.nl/technotes/tn16e.html)
- AG1LE, [Fldigi Matched Filter and SOM Decoder](http://ag1le.blogspot.com/2012/05/fldigi-matched-filter-and-som-decoder.html)
- AG1LE, [Real-Time Deep Learning Morse Decoder](http://ag1le.blogspot.com/2020/04/new-real-time-deep-learning-morse.html)
- F4EXB, [MorseAngel Deep Neural Network CW Decoder](https://github.com/f4exb/morseangel)
- WB2FKO, [FT8 Synchronization - Costas Arrays](https://files.tapr.org/meetings/DCC_2019/2019-4-WB2FKO.pdf)
- N6MW, [FT8 Modulation and Decoding](https://www.k0nr.com/wordpress/wp-content/uploads/2025/03/FT8v6lessS-6.pdf)
- K0NR, [Weak-Signal Performance of Common Modulation Formats](https://www.k0nr.com/wordpress/2025/03/weak-signal-performance/)
- Lloyd Rochester, [PSK31 Convolutional Decoder Implementation](https://lloydrochester.com/psk31/cnvdec/)
- ARRL, [PSK31 Specification](http://www.arrl.org/psk31-spec)
- WirelessPi, [Costas Loop for Carrier Phase Synchronization](https://wirelesspi.com/costas-loop-for-carrier-phase-synchronization/)
- WirelessPi, [Gardner Timing Error Detector](https://wirelesspi.com/gardner-timing-error-detector-a-non-data-aided-version-of-zero-crossing-timing-error-detectors/)
- WirelessPi, [Mueller and Muller Timing Synchronization](https://wirelesspi.com/mueller-and-muller-timing-synchronization-algorithm/)
- WirelessPi, [How Automatic Gain Control Works](https://wirelesspi.com/how-automatic-gain-control-agc-works/)
- KK5JY, [RTTY Modem (quadrature demodulation approach)](http://www.kk5jy.net/rtty-modem-v1/)
- fldigi source code, [GitHub Repository](https://github.com/w1hkj/fldigi)
- A Tasty Pixel, [Fast Lock-Free Ring Buffer for Audio Processing](https://atastypixel.com/a-simple-fast-circular-buffer-implementation-for-audio-processing/)
- Apple, [vDSP Documentation](https://developer.apple.com/documentation/accelerate/vdsp)
- Apple, [Introducing Accelerate for Swift (WWDC19)](https://developer.apple.com/videos/play/wwdc2019/718/)
- RF Cafe, [FSK: Signals and Demodulation](https://www.rfcafe.com/references/articles/wj-tech-notes/fsk-signals-demodulation-v7-5.pdf)

---

*Document generated March 2026 from analysis of fldigi source code, WSJT-X documentation, CW Skimmer references, academic literature, and web research. All estimated dB improvements are approximate and based on published measurements or theoretical analysis.*
