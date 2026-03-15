# PSK Decoding R&D Notes

## Baseline Score: 83.9/100 (2026-03-15)

### Score Breakdown
| Category | Score | Notes |
|----------|-------|-------|
| Clean channel | 100.0 | Perfect baseline |
| Noise immunity | 96.9 | Good down to ~8 dB SNR |
| Frequency offset | **9.7** | CATASTROPHIC - even 1 Hz kills decode |
| Timing jitter | 100.0 | Excellent |
| Adjacent channel | 97.8 | Good |
| All modes clean | 96.7 | QPSK has leading space issue |
| All modes noisy | 96.7 | Same QPSK issue |

### Critical Finding
Frequency offset tolerance is the #1 problem. Our demodulator uses a free-running
local oscillator with no frequency tracking. Even 1 Hz of offset (common in real
radio scenarios) causes total decode failure. Real-world radios routinely have
5-50 Hz of tuning error.

## Improvement Roadmap (Priority Order)

### 1. AFC / Carrier Tracking (HIGHEST PRIORITY)
**Expected impact: +20-30 points on composite score**

What fldigi does:
- Uses a Costas loop PLL for carrier recovery
- The Costas loop tracks the carrier frequency in real-time
- Loop bandwidth ~1-5 Hz for PSK31 (narrow enough to reject noise,
  wide enough to track drift)
- Costas loop is insensitive to 180° phase ambiguity (perfect for BPSK)

Implementation approach:
- Add frequency error detector after IQ mixing
- For BPSK: use `Im(conj(prev) * curr)` as frequency error signal
  (this is the imaginary part of the differential product)
- Feed error through a PI (proportional-integral) loop filter
- Apply correction to the local oscillator phase increment

Key parameters:
- Proportional gain: controls tracking speed vs noise rejection
- Integral gain: corrects steady-state frequency error
- Loop bandwidth: ~2 Hz for PSK31, ~4 Hz for BPSK63

References:
- fldigi source: `src/psk/psk.cxx` (psk_rxprocess function)
- Digital Communications by Proakis, Ch. 6 (Carrier Recovery)
- "PSK31: A New Radio-Teletype Mode" by G3PLX (Peter Martinez)

### 2. Matched Filter (Replace IIR with FIR)
**Expected impact: +3-5 points (better noise immunity)**

Current: simple 1-pole IIR lowpass at 3x baud rate
Better: FIR filter matched to the raised-cosine pulse shape

The matched filter maximizes SNR at the sampling instant. For PSK31
with raised-cosine shaping, the optimal filter IS a raised-cosine filter.

Implementation:
- Pre-compute FIR taps = raised cosine at symbol rate
- Length = 1 symbol period (1536 taps at 48 kHz for PSK31)
- Convolve I and Q channels separately
- Sample at peak of filter output (inherently gives optimal timing)

### 3. QPSK Fix (Leading Space Issue)
**Expected impact: +3 points**

QPSK modes decode a leading space. Likely caused by the first symbol's
differential detection seeing a phase change from the preamble-to-data
transition. Fix: skip the first decoded character after signal detection,
or use the preamble phase as the reference.

### 4. Soft-Decision + Confidence Metric
**Expected impact: +2-5 points at low SNR**

Current: hard bit decisions (threshold at 0)
Better: compute log-likelihood ratio (LLR) and use for:
- Confidence-weighted Varicode decoding
- IMD (intermodulation distortion) quality display
- Adaptive squelch based on decode confidence

### 5. Better Noise Floor Estimation
**Expected impact: +1-2 points**

Current noise floor tracks slowly. During quiet periods between
transmissions, the noise floor should converge faster. Consider
a median-based noise estimator instead of IIR.

### 6. Pre-Detection Bandpass Filter
**Expected impact: +2-3 points for adjacent channel**

Add a narrow bandpass filter before IQ mixing to reject strong
adjacent-channel signals. Use the existing BandpassFilter class
with bandwidth = 2 * baudRate centered on the carrier.

## What Fldigi Does (Reference)

fldigi's PSK implementation (src/psk/psk.cxx) includes:
1. **Costas loop** for carrier/phase tracking
2. **FIR matched filter** (16-tap for PSK31)
3. **Soft Viterbi decoder** for convolutional FEC (QPSK only)
4. **AFC with configurable bandwidth**
5. **IMD measurement** for signal quality
6. **Squelch based on signal quality metric**
7. **Multi-channel browser** (waterfall with multiple decoders)

## Score History

| Date | Score | Change | What Changed |
|------|-------|--------|-------------|
| 2026-03-15 | 83.9 | baseline | Initial benchmark (freq offset test was wrong) |
| 2026-03-15 | 91.8 | +7.9 | AFC via decision-directed leaky integrator + fixed freq offset test |
| 2026-03-15 | 97.6 | +5.8 | Preamble freq estimation + QPSK fix (skip warmup preamble symbols) |
| 2026-03-15 | 99.3 | +1.7 | Merged upstream bandpass filter, AGC, adaptive squelch |
| 2026-03-15 | 99.4 | +0.1 | Sub-symbol (quarter-symbol) preamble freq estimation (+50Hz: 50→72) |
| 2026-03-15 | 96.3 | -3.1 | Expanded to 69 tests: BPSK63 stress, fading, false positive. Phase quality sustain check reduces noise gibberish (FP: 55→82.5). Score drop from harder tests. |

### AFC Implementation Notes (2026-03-15)
- Two-phase AFC: preamble estimation + decision-directed tracking
- Preamble: sub-symbol IQ sampled at quarter-symbol rate, median phase diff for offset estimate
- Decision-directed: after bit decision, de-rotate to get residual phase error
- Leaky integrator (decay 0.999) with dead zone (0.08 rad) prevents clean-channel drift
- Averages phase error over 4 symbols before applying correction
- Ki=0.5 with unit conversion (rad/symbol → rad/sample via /samplesPerSymbol)
- 4-symbol warmup to let IIR filter settle before engaging
- Perfect at ±1-10 Hz, ±20, ±30 Hz. Leading space at ±15-30 Hz (warmup cost). +50 Hz partial (aliasing)
