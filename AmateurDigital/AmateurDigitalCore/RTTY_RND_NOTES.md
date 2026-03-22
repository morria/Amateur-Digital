# RTTY Decoder R&D Notes

## Current Score: 92.3/100 (as of 2026-03-22)

### Score Breakdown
| Category | Score | Weight | Notes |
|----------|-------|--------|-------|
| clean | 100.0 | 2.0 | Perfect |
| baud_rate | 100.0 | 1.0 | 45.45, 50, 75, 100 baud all pass |
| noise | 100.0 | 2.5 | Perfect down to -6 dB SNR |
| fading | 100.0 | 2.0 | QSB fully handled |
| freq_drift | 100.0 | 2.0 | Phase-based AFC works well |
| long_message | 100.0 | 2.0 | ALL sel fading + graduated tests pass |
| itu_channel | 94.4 | 2.5 | Only disturbed (2.5 Hz Doppler) fails |
| false_positive | 95.0 | 1.5 | Spectral SNR scaling effective |
| selective_fading | 88.0 | 3.0 | Short messages still have warmup errors |
| adj_channel | 81.0 | 2.5 | +200 Hz at equal/strong power fails |
| combined | 73.3 | 3.0 | Contest (multi-adjacent) and adj+noise fail |

### Key Algorithm Change (Iteration 9)
**Replaced W7AY ATC formula with spectral-SNR-scaled simple correlation.**

The ATC formula `(mProduct - sProduct) - bias*(envM² - envS²)` depended on slowly-converging
envelope tracking (0.002/step decay = ~19 chars to converge for -10 dB fading). This made the
ATC completely ineffective for selective fading on realistic messages.

The simple correlation `(m - s) / (m + s)` is inherently immune to selective fading — the sign
is always correct regardless of tone power imbalance. Noise rejection is provided by multiplying
by a spectral SNR confidence factor: `min(1.0, max(0, (smoothedSpectralSNR - 1.5) / 2.0))`.

**Result**: +13 points on long_message (87→100), +10 on false_positive (85→95), +4.4 on combined,
+3.4 on ITU channel. Minor regression on adj_channel (-2.3).

### Failed Approaches (DO NOT RETRY)
1. **Faster envelope tracking** (0.05→0.25 attack, 0.002→0.02 decay): Caused cascading regressions
   in noise, adj_channel, ITU. The Goertzel output has too much within-bit variance for any
   per-step envelope acceleration to work.

2. **Peak-based fading detection** (sliding window of recent mark/space peaks): Can't distinguish
   selective fading from multipath or bit transitions. Caused ITU and adj_channel regressions.

3. **Correlation-gated envelope** (only update when tone is dominant, m>s or simpleCorr>threshold):
   Multiple variants tried with gating thresholds 0, 0.3, gap thresholds 0.5, 0.8. ALL caused
   regressions because within-bit Goertzel fluctuations trigger the fast decay even during
   normal operation.

4. **FFT bandpass enabled by default** (OverlapAddFilter, margin 50 Hz): Too narrow — cut signal
   sidebands, causing noise regression from 100→71.3. Margin must be ≥75 Hz if re-enabling.

5. **Noise subtraction in simple correlation** ((m-nf)-(s-nf))/((m-nf)+(s-nf)): Near-zero values
   create unstable ratios, WORSE false positive performance.

### Additional Failed Approaches (Iterations 13-15, DO NOT RETRY)
6. **IIR floor filter** (fast drop 0.9, slow rise 0.001): Floor never converged — the rise rate
   was too slow and adj_leak started ABOVE the initial floor, so fast-drop never triggered.
   itu_channel regressed -2.7.

7. **Sliding window minimum floor** (min of last 40 m/s values): The minimum is always ~0
   because the off-tone value (during the other bit type) is near 0 and appears in every window.
   Catastrophically broke space-side selective fading (100→22% at -15dB) while improving
   mark-side (50→100% at -15dB). The floor subtraction has an asymmetric effect that
   benefits one side while destroying the other.

8. **Larger Goertzel window** (samplesPerBit*3/4 = 792 samples instead of /2 = 528): Catastrophic
   regressions everywhere (-18.3 selective_fading, -20.0 false_positive, -9.5 freq_drift).
   The larger window straddles bit boundaries, corrupting bit decisions through cross-bit
   contamination. NOT viable as a single-component change.

### Remaining Opportunities (Require Architectural Changes)
1. **adj_channel** (81.0): +200 Hz interference puts adjacent space at 2155 Hz, only 30 Hz from
   our mark at 2125 Hz — within Goertzel mainlobe. Requires:
   - **Dual-window architecture**: Short window for bit timing + long window for frequency
   - **Per-bit Goertzel**: Compute exactly once per bit aligned with state machine
   - **Spectral subtraction**: Estimate interferer power from AFC offset filters

2. **selective_fading on short messages** (88.0): Leading garbage chars in first 1-2 characters
   before spectral SNR confidence ramps up. The spectral SNR warmup grace period was tried
   (correlationHistory.count >= 20) but didn't help multi-channel test.

3. **combined/contest** (0%): Multiple strong adjacent signals. Same limitation as adj_channel.

4. **ITU disturbed** (0%): 2.5 Hz Doppler + 5ms multipath. Requires complex demodulation.

### Improvement Machine Summary (16 iterations, 2026-03-22)
- **Total decoder attempts**: 20+ code changes, 1 committed improvement
- **Net RTTY improvement**: 89.1 → 92.3 (+3.2 composite points)
- **Key breakthrough**: Simple correlation replacing ATC (iteration 9)
- **Tests added**: 17 new tests (long_message, graduated fading, expanded adj_channel)
- **Single-component improvements exhausted**: All remaining improvements need multi-file refactoring
