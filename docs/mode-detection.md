# Automatic Digital Mode Detection

Plan for listening to an audio signal and determining which digital mode it most likely is.

## Problem

The app currently requires the user to manually select a mode before decoding. We want to automatically identify which mode (RTTY, PSK31, BPSK63, QPSK31, QPSK63, CW, JS8Call, Rattlegram) a received signal is using, so the app can either auto-switch or suggest the correct mode.

## Mode Signatures

Each mode has distinct spectral and temporal characteristics:

| Mode | Type | Bandwidth | Spectral Shape | Baud Rate | Distinguishing Feature |
|------|------|-----------|----------------|-----------|----------------------|
| RTTY | FSK | ~250 Hz | Two peaks (mark/space), 170 Hz shift | 45.45 | Dual-tone with valley between |
| PSK31 | BPSK | ~60 Hz | Single narrow peak | 31.25 | Very narrow, phase reversals |
| BPSK63 | BPSK | ~125 Hz | Single narrow peak | 62.5 | Wider than PSK31, same shape |
| QPSK31 | QPSK | ~60 Hz | Single narrow peak | 31.25 | Identical spectrum to PSK31 |
| QPSK63 | QPSK | ~125 Hz | Single narrow peak | 62.5 | Identical spectrum to BPSK63 |
| CW | OOK | ~50-100 Hz | Single very narrow peak, intermittent | Variable | On-off keying pattern |
| JS8Call | 8-GFSK | ~50 Hz | 8 narrow tones | 6.25 | UTC-aligned timing, Costas sync |
| Rattlegram | OFDM | ~1600 Hz | Many equidistant carriers, flat top | N/A | Wideband, Schmidl-Cox preamble |

Key observations:
- **RTTY** is the only mode with two spectral peaks separated by a fixed shift
- **PSK variants** are spectrally identical within their baud rate family; distinguishing PSK31 from QPSK31 requires demodulation (phase constellation analysis)
- **CW** is the only mode with amplitude on/off keying
- **Rattlegram** has dramatically wider bandwidth than everything else
- **JS8Call** has 8 discrete tones and UTC-aligned timing

## Approaches

### 1. RSID (Reed-Solomon Identifier) — Cooperative Detection

**How it works.** RSID is a standardized in-band signaling protocol created by Patrick Lindecker (F6CTE). The transmitting station sends a 1.4-second burst of 15 symbols using 16-tone MFSK (10.766 baud, 172 Hz bandwidth) before each transmission. Each mode has a unique Reed-Solomon code (RS(15,3) over GF(16)). The receiver runs a 2048-point FFT at 11025 Hz and tests ~8,500 candidate codes per second using Hamming distance matching.

**Accuracy.** Near-perfect when the RSID preamble is present. 2.7 Hz frequency precision. 272 modes covered.

**Pros.** Identifies mode AND frequency simultaneously; standardized across fldigi, MultiPSK, DM780; identifies sub-variants (RTTY-45 vs RTTY-75, Olivia 8/250 vs 32/1000).

**Cons.** Only works when the transmitter enables RSID (many operators don't); adds 1.4s overhead; useless for signals already in progress.

**Computational cost.** Moderate — continuous FFT + ~8,500 code comparisons/sec. The fldigi implementation uses a hashing algorithm (by OK1IAK) that makes this efficient. Feasible on mobile.

**Implementation reference.** fldigi source: `src/rsid/rsid.cxx` and `src/rsid/rsid_defs.cxx` (available in `research/fldigi/`).

### 2. Spectral Shape Analysis — Feature-Based Classification

**How it works.** Compute a power spectrum via FFT, then extract features that distinguish mode families:

1. **Peak count and spacing** — RTTY has exactly 2 peaks ~170 Hz apart; PSK/CW have 1 narrow peak; Rattlegram has many equidistant peaks
2. **Occupied bandwidth** — Rattlegram ~1600 Hz vs PSK31 ~60 Hz vs CW ~50 Hz
3. **Spectral flatness** — OFDM signals have high flatness (flat-topped PSD); tonal signals have low flatness
4. **Peak-to-valley ratio** — RTTY shows a distinct dip between mark and space tones

Decision tree:
```
Bandwidth > 500 Hz?
├── Yes → Rattlegram (OFDM)
└── No → Peak count?
    ├── 2 peaks, ~170 Hz apart → RTTY
    └── 1 peak → Bandwidth?
        ├── < 80 Hz → PSK31/QPSK31 or CW
        │   └── Amplitude on/off keying? → CW vs PSK31
        └── 80-200 Hz → BPSK63/QPSK63
```

**Accuracy.** Good at moderate SNR (> 5 dB) for separating mode families. Cannot distinguish BPSK from QPSK (same spectrum). Degrades at low SNR.

**Pros.** No training data needed; deterministic; very fast (< 5 ms); works on signals already in progress.

**Cons.** Requires manual threshold tuning; limited sub-variant discrimination; fragile at low SNR.

**Existing infrastructure.** DecodeWAV already implements `findRTTYCandidates()` (mark/space pair detection with spectral valley check) and `findPSKCandidates()` (narrow peak detection). FFTProcessor and GoertzelFilter are available in the DSP module.

### 3. Baud Rate Estimation — Cyclostationary Analysis

**How it works.** Digital signals have periodicity at the symbol rate. To extract it:

1. Square (or raise to 4th power) the baseband signal envelope — this strips the modulation and exposes the symbol clock
2. Take the FFT of this squared signal
3. Peaks in the result correspond to the baud rate and its harmonics

Mapping baud rate to mode:
- 45.45 baud → RTTY
- 31.25 baud → PSK31 or QPSK31
- 62.5 baud → BPSK63 or QPSK63
- 6.25 baud → JS8Call
- Variable (5-60 WPM → ~2-24 baud) → CW

**Accuracy.** Very high for baud rate estimation at SNR > 5 dB. Combined with spectral shape analysis, resolves most ambiguities. One study using higher-order cumulants with SVM achieved 98% accuracy at 10 dB SNR.

**Pros.** Measures a fundamental signal parameter; works on arbitrary signals without cooperation; discriminates between modes with the same modulation but different baud rates.

**Cons.** Requires 0.5-2 seconds of observation for low baud rates; does not distinguish modulation type (FSK vs PSK) on its own; somewhat more computationally expensive than spectral shape analysis.

**References.**
- [PySDR: Cyclostationary Processing](https://pysdr.org/content/cyclostationary.html)
- [CycloDSP: GNU Radio Tool](https://arxiv.org/html/2405.16911v1)

### 4. Higher-Order Statistics — Modulation Type Classification

**How it works.** Different modulation types have distinct statistical signatures in their higher-order cumulants (C40, C42, C60, C63):

- **Kurtosis of amplitude envelope** — CW (OOK) has bimodal amplitude (on/off); FSK and PSK have approximately constant envelope
- **Std dev of instantaneous phase** — separates FSK from PSK
- **4th-order cumulants** — distinguish BPSK from QPSK (different constellation symmetry)

This is the only DSP-based approach that can distinguish BPSK from QPSK without full demodulation.

**Accuracy.** > 95% at SNR > 5 dB for standard modulation types. Degrades under HF fading.

**Pros.** Theoretically well-founded; lightweight computation (O(N) per feature); short observation windows (~100 ms for higher baud rates).

**Cons.** Sensitive to SNR; HF propagation distortion corrupts statistics; requires careful threshold calibration.

**References.**
- [EURASIP: AMC of Digital Modulations in HF Noise](https://asp-eurasipjournals.springeropen.com/articles/10.1186/1687-6180-2012-238)

### 5. Preamble / Sync Word Detection — Mode-Specific Detectors

**How it works.** Several modes have distinctive synchronization patterns:

- **Rattlegram**: Schmidl-Cox preamble (two repeated OFDM symbols). Detection uses autocorrelation with half-symbol delay. Already implemented in `Sync/SchmidlCox.swift`.
- **JS8Call**: 7x7 Costas Array at frame start. Correlate against known pattern.
- **CW**: On-off keying with characteristic dot/dash timing ratios.

These detectors run continuously in parallel, each watching for its specific sync pattern.

**Accuracy.** Very high when the preamble appears. Also provides time and frequency synchronization for free.

**Pros.** Reliable; low false-positive rate; provides synchronization simultaneously.

**Cons.** Each mode needs its own detector; RTTY and PSK have no formal preamble; only detects transmission starts, not signals already in progress.

### 6. CNN on Spectrograms — Deep Learning Classification

**How it works.** Convert 1-2 seconds of audio into a mel spectrogram image, then classify with a convolutional neural network.

**Recent results.**

| Paper | Modes | Model | Accuracy | Notes |
|-------|-------|-------|----------|-------|
| [Bundscherer et al. (ICASSP 2025)](https://arxiv.org/abs/2501.07337) | 17 modes (98 variants) | EfficientNetB0 | 93.8% | Tested on real UHF transmissions |
| [Scholl (2025)](https://arxiv.org/abs/2504.05455) | 160 shortwave signals | Deep CNN | 90% @ 1s | Synthetic + real training data |

**iOS deployment.** EfficientNetB0 (~5.3M params) runs at ~10-30 ms inference on iPhone Neural Engine via CoreML. MobileNetV3-Large has similar performance. Apple's `SoundAnalysisPreprocessing` provides optimized mel spectrogram extraction via Accelerate.

**Training data.** Can be generated synthetically using our existing modulators (RTTYModulator, PSKModulator, CWModulator, etc.) with noise, fading, and frequency offset augmentation. The `samples/` directory has real-world WAV files for validation.

**Pros.** Highest accuracy; handles many modes simultaneously; learns features automatically; can discriminate fine-grained variants; scales well.

**Cons.** Requires training pipeline; model size ~5-20 MB; black-box; needs retraining to add modes; risk of misclassifying out-of-distribution signals.

### 7. Brute-Force Trial Demodulation

**How it works.** Run all demodulators in parallel on candidate frequencies, score the decoded text, pick the mode that produces the best output. This is what DecodeWAV already does (RTTY and PSK in parallel, comparing `rttyScore()` and `textQuality()`).

Fldigi's signal browser takes a similar approach — up to 30 PSK demodulators running simultaneously across the waterfall.

**Pros.** Bypasses classification entirely; self-validating (correct mode produces readable text); proven in DecodeWAV.

**Cons.** Computationally expensive (scales as frequencies × modes); high latency; not practical for 8 modes on mobile in real time.

## Recommended Strategy: Tiered Detection

A multi-tier architecture that starts fast/cheap and escalates to more expensive methods only when needed:

### Tier 1 — Fast Spectral Pre-Scan (< 5 ms, every 500 ms)

Run on the audio input thread with minimal overhead.

1. Compute power spectrum (4096-point FFT with Hann window over the most recent ~85 ms of audio)
2. Estimate noise floor (median power across bins)
3. Find peaks above noise floor (> 10 dB)
4. Measure occupied bandwidth of each detected signal
5. Classify into broad families:
   - **Wideband** (> 500 Hz) → Rattlegram candidate
   - **Dual-tone** (2 peaks, 150-200 Hz apart) → RTTY candidate
   - **Narrow single-tone** (< 200 Hz) → PSK/CW/JS8Call candidate
   - **No signal detected** → idle

**Output.** A list of `(frequency, candidateFamily)` tuples. This narrows 8 modes down to 1-3 candidates.

**What we already have.** `FFTProcessor`, `GoertzelFilter`, `findRTTYCandidates()` and `findPSKCandidates()` logic from DecodeWAV.

### Tier 2 — Feature-Based Discrimination (< 10 ms, on demand)

Runs when Tier 1 finds a signal. Disambiguates within families.

For **narrow single-tone** candidates:
- **Amplitude envelope analysis** — compute kurtosis of the amplitude envelope over 0.5s. Bimodal (high kurtosis) → CW. Constant envelope → PSK.
- **Baud rate estimation** — square the baseband signal, FFT the result. 31.25 Hz peak → PSK31. 62.5 Hz → BPSK63. 6.25 Hz → JS8Call. No clear peak → CW (variable timing).
- **On/off keying test** — threshold the amplitude envelope, measure duty cycle and transition timing. Regular dot/dash patterns → CW.

For **RTTY** candidates:
- Verify mark/space shift (170 Hz standard, also check 200, 425, 850 Hz)
- Confirm with Goertzel filter power ratio

For **Rattlegram** candidates:
- Run Schmidl-Cox correlator to confirm OFDM preamble

**Output.** A ranked list of `(mode, confidence)` for each detected signal.

### Tier 3 — Sync/Preamble Detection (continuous, background)

Run continuously on a background thread, independent of Tiers 1-2.

- **RSID detector** — watches for the 1.4s RS-coded preamble. Positive detection is authoritative and overrides Tiers 1-2.
- **Schmidl-Cox correlator** — already exists in RattlegramCore. Detects Rattlegram transmissions.
- **Costas array correlator** — detects JS8Call frame starts.

These run at low CPU cost and provide high-confidence identifications when sync patterns appear.

### Tier 4 — Trial Demodulation (expensive, fallback)

When Tier 2 is ambiguous (e.g., PSK31 vs QPSK31, or low-SNR signal), try demodulating with the top 2-3 candidate modes for 2-3 seconds and score the output:

- `rttyScore()` — word structure, letter ratios, ham radio patterns
- `textQuality()` — printable ASCII ratio, word spacing

The mode producing the highest text quality score wins.

This is what DecodeWAV does today and is proven to work. The key is to only invoke it for ambiguous cases, not as the first step.

### Tier 5 (Optional, Future) — CoreML Spectrogram Classifier

A small CNN (EfficientNetB0 or MobileNetV3) trained on spectrograms generated by our own modulators. This would serve as:

- A fast second opinion when Tier 2 is uncertain
- The primary classifier if we add more modes in the future (Olivia, FT8, etc.)
- A way to distinguish BPSK from QPSK without trial demodulation

**Training approach:**
1. Generate synthetic audio for each mode using existing modulators (varying SNR, frequency offset, fading)
2. Convert to mel spectrograms (1-2 second windows)
3. Train EfficientNetB0 with augmentation (noise, frequency shift, Watterson fading)
4. Export to CoreML for Neural Engine inference

**Size estimate.** ~5 MB model, ~10-30 ms inference on iPhone Neural Engine.

## Architecture

```
AudioService (48 kHz input tap, 4096 samples)
    │
    ├── ModeDetector (new component)
    │   ├── Tier 1: SpectralScanner
    │   │   └── FFT → peaks → family classification
    │   ├── Tier 2: FeatureAnalyzer
    │   │   ├── AmplitudeEnvelopeAnalyzer (CW vs PSK)
    │   │   ├── BaudRateEstimator (PSK31 vs BPSK63 vs JS8Call)
    │   │   └── ShiftDetector (RTTY shift verification)
    │   ├── Tier 3: SyncDetectors (background)
    │   │   ├── RSIDDetector
    │   │   ├── SchmidlCoxDetector (Rattlegram)
    │   │   └── CostasDetector (JS8Call)
    │   └── Tier 4: TrialDemodulator (on demand)
    │       └── runs candidate demodulators, scores text output
    │
    ├── ModemService (existing, receives mode recommendation)
    │   └── switches demodulator based on detection result
    │
    └── ModeDetectorDelegate (new protocol)
        func modeDetector(_ detector: ModeDetector,
                          detected mode: DigitalMode,
                          confidence: Float,
                          frequency: Float)
```

### ModeDetector API (sketch)

```swift
protocol ModeDetectorDelegate: AnyObject {
    func modeDetector(_ detector: ModeDetector,
                      detected mode: DigitalMode,
                      confidence: Float,
                      frequency: Float)
}

class ModeDetector {
    weak var delegate: ModeDetectorDelegate?

    /// Feed audio samples continuously (same tap as ModemService)
    func process(samples: [Float])

    /// Current best guess
    var detectedMode: DigitalMode? { get }
    var confidence: Float { get }

    /// Enable/disable specific tiers
    var enableRSID: Bool
    var enableTrialDemod: Bool
    var enableMLClassifier: Bool
}
```

### Integration into ModemService

Two operation modes:

1. **Suggest mode** — ModeDetector runs alongside the current demodulator. When it detects a different mode with high confidence, it notifies the delegate (UI shows a suggestion banner: "Detected RTTY signal — switch?"). User confirms manually.

2. **Auto-switch** — ModeDetector automatically switches the active demodulator when confidence exceeds a threshold (e.g., 0.9). Useful for scanning/monitoring.

## Implementation Order

### Phase 1: Spectral Pre-Scan (Tiers 1-2)

Port the proven logic from DecodeWAV into a reusable `ModeDetector` class:

- [ ] Extract `powerSpectrum()` / `findRTTYCandidates()` / `findPSKCandidates()` from DecodeWAV into the library
- [ ] Add amplitude envelope analysis for CW detection (kurtosis-based)
- [ ] Add baud rate estimator (squared-envelope FFT)
- [ ] Add bandwidth measurement for Rattlegram detection
- [ ] Wire into ModemService as an optional detector
- [ ] Add UI: mode suggestion banner in ChannelDetailView

This phase handles the 80% case — clearly distinguishable signals at moderate SNR.

### Phase 2: Sync/Preamble Detection (Tier 3)

- [ ] Implement RSID detector (port from fldigi `src/rsid/rsid.cxx`)
- [ ] Expose Schmidl-Cox correlator from RattlegramCore for standalone use
- [ ] Add Costas array correlator for JS8Call
- [ ] Run sync detectors on a background thread, independent of Tiers 1-2

### Phase 3: Trial Demodulation (Tier 4)

- [ ] Extract `rttyScore()` and `textQuality()` scoring from DecodeWAV into the library
- [ ] Build lightweight trial demodulator that runs top-2 candidates for 2-3 seconds
- [ ] Use text quality scores to resolve ambiguous cases (PSK31 vs CW at similar bandwidth)

### Phase 4: ML Classifier (Tier 5)

- [ ] Build training data generator using existing modulators + noise/fading augmentation
- [ ] Train EfficientNetB0 or MobileNetV3 on mel spectrograms
- [ ] Export to CoreML, integrate as optional Tier 5
- [ ] Evaluate whether it can replace Tiers 1-2 or serves as a complement

## References

- [RSID Technical Description (W1HKJ)](http://www.w1hkj.com/RSID_description.html)
- [EURASIP: AMC of Digital Modulations in HF Noise](https://asp-eurasipjournals.springeropen.com/articles/10.1186/1687-6180-2012-238)
- [Bundscherer et al. — Amateur Radio Mode Classification (ICASSP 2025)](https://arxiv.org/abs/2501.07337)
- [Scholl — Large-Scale Shortwave Classification (2025)](https://arxiv.org/abs/2504.05455)
- [PySDR: Cyclostationary Processing Tutorial](https://pysdr.org/content/cyclostationary.html)
- [Signal Identification Wiki](https://www.sigidwiki.com/wiki/Signal_Identification_Guide)
- [Panoradio SDR: Introduction to RF Signal Classification](https://panoradio-sdr.de/introduction-to-rf-signal-classification/)
- fldigi source: `research/fldigi/src/rsid/rsid.cxx` (local copy)
