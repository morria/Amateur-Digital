# Performance Roadmap

Battery drain and thermal analysis of the Amateur Digital iOS app. Tier 1 items have been implemented. Tiers 2–4 are documented here for future work.

## Current CPU Budget (per mode at 48 kHz)

| Mode | Channels | Ops/sample/ch | Total Mops/s | Notes |
|------|----------|---------------|-------------|-------|
| CW | 1 | ~1505 | **72** | 513-tap FFT bandpass dominates |
| PSK | 16 | ~22 | **17** | IQ mixing + timing recovery |
| RTTY | 17 | ~15 | **12** | Goertzel pairs × 17 channels |
| Rattlegram | 1 | ~130 | **6** | 197-tap Hilbert + correlator (idle) |
| JS8Call | 1 | ~1 (idle) | **~50** (burst) | 1.5B ops per decode cycle |

## Tier 1 — Implemented

1. DSP moved off main thread (dedicated serial DispatchQueue)
2. Pre-allocated audio buffer with vDSP stereo→mono conversion
3. Batched character decode callbacks (~100ms window)
4. Throttled @Published property updates (change-gated writes)
5. CoreML classification moved to background Task.detached

## Tier 2 — High Impact, DSP Changes (No Quality Loss)

### 6. Replace custom FFT with Accelerate vDSP

The entire DSP stack uses a hand-written radix-2 FFT with per-butterfly trig computation (`cos`/`sin` called per operation). Apple's vDSP FFT is 5–10× faster on ARM64.

**Applies to**: CW bandpass (biggest win — 72 Mops/s), Rattlegram FFT, JS8Call sync search, mode detection spectral analysis.

**Approach**: Replace `FFTProcessor` internals with `vDSP_fft_zrop` / `vDSP_DFT_Execute`. Keep the same public interface. The OverlapAddFilter in CW can use `vDSP_conv` for convolution.

**Expected impact**: CW drops from ~72 Mops/s to ~7–15 Mops/s.

**Files**:
- `AmateurDigitalCore/Sources/AmateurDigitalCore/DSP/FFTProcessor.swift`
- `AmateurDigitalCore/Sources/AmateurDigitalCore/DSP/BandpassFilter.swift` (OverlapAddFilter)
- `RattlegramCore/Sources/RattlegramCore/DSP/FFT.swift`

### 7. Vectorize Goertzel filters with vDSP

RTTY runs 34 Goertzel filters (17 channels × mark+space) and PSK runs 32+, all as scalar loops.

**Approach**: Batch all channels' Goertzel state updates into vector multiply-accumulate using `vDSP_vma`. Process all channels in one pass per sample rather than iterating channels sequentially.

**Expected impact**: 3–5× speedup on RTTY/PSK Goertzel processing.

**Files**:
- `AmateurDigitalCore/Sources/AmateurDigitalCore/DSP/GoertzelFilter.swift`
- `AmateurDigitalCore/Sources/AmateurDigitalCore/Modems/RTTYModem/MultiChannelRTTYDemodulator.swift`
- `AmateurDigitalCore/Sources/AmateurDigitalCore/Modems/PSKModem/MultiChannelPSKDemodulator.swift`

### 8. Decimate before per-channel processing (RTTY/PSK)

RTTY bandwidth is ~250 Hz. PSK31 is ~60 Hz. Both process at 48 kHz — vastly oversampled for the signal bandwidth.

**Approach**: Downsample to ~6 kHz (8×) after a cheap anti-alias filter, then run Goertzel/demod at the lower rate. The existing bandpass filter already limits bandwidth.

**Expected impact**: 8× fewer samples through per-channel DSP. RTTY: 12 → ~1.5 Mops/s. PSK: 17 → ~2 Mops/s.

**Risk**: Adds ~10ms latency. No decode quality impact if anti-alias filter is adequate. Verify against PSK and RTTY benchmarks.

**Files**:
- `AmateurDigitalCore/Sources/AmateurDigitalCore/Modems/RTTYModem/MultiChannelRTTYDemodulator.swift`
- `AmateurDigitalCore/Sources/AmateurDigitalCore/Modems/PSKModem/MultiChannelPSKDemodulator.swift`

## Tier 3 — Medium Impact, Targeted Optimizations

### 9. Reduce CW bandpass filter to 257 taps

Currently 513 taps for −73 dB out-of-band rejection. Amateur CW doesn't need that; −60 dB (257 taps) is more than sufficient and halves the FFT size from 512 to 256.

**Expected impact**: ~35% reduction in CW filter cost. Combine with vDSP (#6) for a massive total reduction.

**Verify**: Run CW benchmark before/after. Expect ≤0.5 point score drop.

**Files**:
- `AmateurDigitalCore/Sources/AmateurDigitalCore/Modems/CWModem/CWDemodulator.swift`

### 10. Throttle Rattlegram idle monitoring

The 197-tap Hilbert filter and Schmidl-Cox correlator run on every sample even when no signal is present.

**Approach**: Decimate to every 4th sample during idle (correlator detection threshold is wide enough). Switch to full rate on sync detection.

**Expected impact**: 75% idle power reduction for Rattlegram (6 → 1.5 Mops/s).

**Files**:
- `RattlegramCore/Sources/RattlegramCore/Decoder.swift`
- `RattlegramCore/Sources/RattlegramCore/DSP/Hilbert.swift`

### 11. Precompute FFT twiddle factors (Rattlegram)

Rattlegram's FFT computes `cos()`/`sin()` per butterfly operation at runtime rather than using lookup tables.

**Approach**: Build twiddle tables at decoder init, index into them during FFT. Replace `Foundation.cos(angle)` / `Foundation.sin(angle)` calls with table lookup.

**Expected impact**: 15–20% ops reduction on all Rattlegram FFT work.

**Files**:
- `RattlegramCore/Sources/RattlegramCore/DSP/FFT.swift`

### 12. Only process active multi-channel slots

RTTY always runs 17 channels and PSK always runs 16 even if the band is quiet. Most of the time, only 1–3 channels have signal.

**Approach**: Use a lightweight energy detector (one Goertzel per slot). Only spin up full demodulation on channels with energy above a threshold.

**Expected impact**: In quiet band conditions (common), CPU drops proportionally with inactive channels.

**Risk**: Brief signal detection latency (~50ms) when a new signal appears. Must tune energy threshold carefully.

**Files**:
- `AmateurDigitalCore/Sources/AmateurDigitalCore/Modems/RTTYModem/MultiChannelRTTYDemodulator.swift`
- `AmateurDigitalCore/Sources/AmateurDigitalCore/Modems/PSKModem/MultiChannelPSKDemodulator.swift`

## Tier 4 — Architectural / Long-Term

### 13. Remove main-thread dispatch from AudioService entirely

The audio tap closure currently dispatches to main for `inputLevel`. Use an atomic store (or `os_unfair_lock`) for the float value and eliminate the main-thread hop from the audio path entirely.

### 14. Reduce Hilbert filter taps (Rattlegram)

197 taps is high for a half-band Hilbert. 65 taps gives acceptable analytic signal quality for OFDM demodulation. Saves ~66 multiply-adds per sample (~3 Mops/s continuously).

### 15. JS8Call: cache sync search results

The Goertzel sync search (250 carriers × 8 tones × 1500 steps = 3M iterations) re-scans the entire buffer each period. Incrementally update only the new samples added since last search. Cache carrier power profiles.

**Expected impact**: Reduces decode burst from ~1.5B ops to ~200–400M ops.

## Estimated Cumulative Impact

| Phase | Items | Expected Power Reduction |
|-------|-------|-------------------------|
| Tier 1 (done) | #1–5 | 20–30% (main thread freed) |
| Tier 2 | #6–8 | 40–60% additional (DSP 5–10× cheaper) |
| Tier 3 | #9–12 | 30–50% additional |
| Tier 4 | #13–15 | 10–20% additional |

Tiers 1 + 2 combined should bring CPU to ~20–25% of pre-optimization levels, eliminating overheating on modern iPhones.
