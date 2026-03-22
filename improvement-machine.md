# Decoder Improvement Machine v2

Autonomous system for continually improving Amateur Digital decoder performance under real-world HF conditions.

## Design Philosophy

1. **Oracle verifiers** (benchmarks) with zero verification noise are the foundation
2. **Real-world conditions first** — test what operators actually encounter, not just theoretical models
3. **Automated parameter optimization** (CMA-ES/Optuna) for the parameters, **agentic AI** for the algorithms
4. **Regression guard** — baseline only moves forward
5. **Multi-decoder diversity** — the best contest operators run 2-4 decoders in parallel

## Three-Layer Improvement System

### Layer 1: Automated Parameter Optimization (CMA-ES / Optuna)

For continuous parameters (thresholds, filter coefficients, time constants), use numerical optimizers.
Humans/AI choose the algorithms; optimizers tune the parameters.

**Setup required:**
1. Add `--params /path/to/params.json` flag to each benchmark CLI
2. Make hardcoded `private let` constants into configurable properties
3. Run Python optimizer wrapper that calls `swift run -c release <Benchmark> --params ...`

**Key parameters to optimize per decoder:**
- RTTY: `correlationThreshold`, `agcDecay`, `envelopeDecay`, `afcAlpha`, `stopBitThreshold`, spectral SNR curve shape
- PSK: `phaseQualityThreshold`, `acquireThreshold`, `sustainThreshold`, `signalPersistRequired`
- CW: `thresholdFraction` (3 values by SNR range), `debounceThreshold`, `interCharThreshold`, `wordThreshold`

**Toolchain:** `pip install optuna cma pymoo` + Python wrapper script in `scripts/optimize_<mode>.py`

### Layer 2: Benchmark Hardening (Real-World Conditions)

Current benchmarks test AWGN, ITU channels, and some impairments. Missing conditions:

#### Impulse Noise (Highest Priority Addition)
Real HF below 14 MHz is dominated by non-Gaussian impulse noise. Decoders optimized for AWGN lose 5-10 dB with impulsive noise.
- **Lightning/QRN**: Poisson-distributed impulses, ~5/sec, 0.5-1 ms duration, 20-30 dB above noise floor
- **Power line noise**: 120 Hz impulse train, 100 us pulses, 15 dB above noise
- **Impulse blanker**: A simple blanker (mute samples > 3x RMS) recovers most of the loss. Test WITH and WITHOUT blanker.

#### Auroral Flutter
Paths crossing the auroral oval experience 10-100 Hz Doppler spread (vs 0.1-2.5 Hz for normal ionospheric fading). This destroys narrowband modes.
- Mild: 10 Hz Doppler spread, 2-path, 1.0 ms delay
- Severe: 50 Hz Doppler spread, 2-path, 2.0 ms delay

#### Realistic QRM Scenarios
- **RTTY contest pileup**: 5 signals at ±200-1000 Hz, levels +10 to +30 dB above target
- **Broadcast splatter**: AM signal at +3 kHz, 40 dB above noise, 80% modulation
- **CW pileup**: 10 simultaneous CW signals at ±50-500 Hz, speeds 15-35 WPM

#### Equipment Imperfections
- **Audio overdrive**: Clip at ±80% peak (10% THD), ±50% (30% THD)
- **AGC pumping**: Multiply signal by sinusoidal gain, 10 dB depth, 2-5 Hz
- **60 Hz hum**: Add 60 Hz + harmonics at -25 dB relative to signal
- **Sample rate mismatch**: Resample 48000→47950 Hz (44100 vs 44118 Hz clock error)
- **Wrong sideband (RTTY)**: Invert audio spectrum

#### CW-Specific Real-World Tests
- **Chirp**: 30 Hz exponential frequency shift over first 5 ms of each key-down
- **Bug key**: Consistent dots (40-60 ms), variable dashes (100-200 ms at 20 WPM)
- **Running together**: Inter-character gap reduced to 2 dit lengths

### Layer 3: Agentic Algorithm Improvement (Claude Code Loop)

For algorithmic changes that require understanding DSP theory and reading reference implementations.

**When to use the agent loop:**
- After Layer 1 optimization has converged (parameters at local optimum)
- When benchmark hardening reveals a new failure mode that requires a new algorithm
- When published research suggests a better approach (W7AY equalized raised cosine, 2Tone selective decoder, CW Skimmer Bayesian approach)

**Agent loop protocol:**
```
1. Run benchmark → identify worst weighted category
2. Read reference implementation (fldigi, WSJT-X, MMTTY) for that failure mode
3. Generate hypothesis with DSP reasoning
4. Implement with regression guard (any category drop > 0.5 → revert)
5. Max 3 attempts per session, then switch targets
6. Document findings in *_RND_NOTES.md
```

## Improvement Priorities (Research-Based)

### Proven Techniques We Haven't Implemented

| Technique | Source | Expected Gain | Decoder |
|-----------|--------|--------------|---------|
| **Equalized raised cosine filter** | W7AY | Zero ISI (eliminates inter-symbol interference) | RTTY |
| **Impulse blanker** | MIL-STD-188-110 | +5-10 dB on lower bands with QRN | All |
| **2Tone selective decoder** | G3YYD | Better weak-signal RTTY (S3 and below) | RTTY |
| **Bayesian probability framework** | CW Skimmer/VE3NEA | Higher accuracy CW, especially in QRM | CW |
| **Matched filter for CW** | AG1LE/fldigi | -10 dB SNR with <2% CER (filter BW matters most!) | CW |
| **Multi-decoder diversity** | Contest best practice | Run 2+ decoders, take best result | RTTY |
| **Soft-decision Viterbi** | fldigi | +3-4 dB for QPSK modes | PSK |

### SNR Targets (Published Real-World Benchmarks)

| Mode | Our Current | fldigi | Best Known | Target |
|------|-------------|--------|------------|--------|
| RTTY | ~10 dB (100% CER=0) | ~-5 dB (1% CER) | -9 dB (MFSK) | -5 dB |
| PSK31 | ~8 dB (100% CER=0) | ~-10 dB (1% CER) | -10 dB | -8 dB |
| CW 20 WPM | ~0 dB | ~-10 dB (2% CER) | -18 dB (by ear) | -10 dB |
| JS8Call | -21 dB (matches FT8) | N/A | -24 dB (with AP) | -21 dB |

### Filter Quality is #1 (AG1LE Research Conclusion)

AG1LE's systematic CW decoder testing proved that **filter bandwidth has MORE impact on CER than decoder algorithm choice**. A 35 Hz FFT filter consistently outperformed wider filters by 3-5 dB regardless of the downstream decoder algorithm. This applies across all modes:
- CW: Optimal filter = ~35 Hz at 20 WPM (matched to signal bandwidth)
- RTTY: Optimal filter per tone = ~91 Hz at 45.45 baud
- PSK31: Optimal filter = ~62 Hz (matched to symbol rate bandwidth)

## Current Scores (2026-03-22, after 17 iterations)

| Decoder | Score | Tests | Weakest Category |
|---------|-------|-------|-----------------|
| JS8Call | 100.0 | 82 | — |
| PSK | 98.2 | 98 | false_positive 83.8 |
| RTTY | 92.3 | 85 | combined 73.3, adj_channel 81.0 |
| CW | 90.5 | 93 | qrm 56.7, itu_channel 72.5 |

## Lessons Learned (17 iterations)

### What Works
- **Algorithmic changes >> parameter tweaks**: RTTY simple correlation (+3.2) was the only committed improvement across 25+ attempts
- **Benchmark hardening reveals real weaknesses**: QRM, long messages, graduated fading tests exposed invisible problems
- **Strict regression guard prevents damage**: Every reverted change would have degraded overall performance

### What Doesn't Work (DO NOT RETRY)
- **RTTY faster envelope tracking** (any variant): 6+ failed attempts. Goertzel output has too much within-bit variance.
- **RTTY per-tone floor subtraction**: Minimum is always ~0 because off-tone appears in every window.
- **CW filter narrowing**: ±50 Hz cuts signal sidebands. ±100 Hz is the minimum safe width at 513 taps.
- **CW tap count changes**: Non-monotonic (769 worse than both 513 and 1025). Group delay tradeoff.
- **PSK phase quality / persistence / SNR threshold changes**: All caused cascading regressions in other categories.

### Architectural Changes Needed (Beyond Incremental Loop)
1. **RTTY complex demodulation** (fldigi-style dual mixer + FFT filter)
2. **CW dual-Goertzel interference cancellation**
3. **CW matched filter** (auto-adjusts bandwidth to WPM)
4. **Impulse blanker** (pre-processing stage before all decoders)
5. **W7AY equalized raised cosine** for RTTY (zero ISI)
6. **2Tone selective decoder** (process mark/space independently)

## Research Sources

- W7AY ATC Paper: http://www.w7ay.net/site/Technical/ATC/
- W7AY Equalized Raised Cosine: http://w7ay.net/site/Technical/EqualizedRaisedCosine/
- AG1LE CW SNR vs CER: http://ag1le.blogspot.com/2013/01/morse-decoder-snr-vs-cer-testing.html
- FT4/FT8 QEX Paper: https://wsjt.sourceforge.io/FT4_FT8_QEX.pdf
- fldigi Modem Test: https://github.com/mirandadam/fldigi_modem_test
- PA3FWM Digital Mode SNR: http://www.pa3fwm.nl/technotes/tn09b.html
- MIL-STD-188-110 Testing: ITU-R F.1487 channel models
- Deep Learning Receivers Survey (2025): arxiv.org/abs/2501.17184
- GVU Self-Improving Agent Framework: arxiv.org/abs/2512.02731
- CMA-ES: https://cma-es.github.io/
- Optuna: https://optuna.org/
