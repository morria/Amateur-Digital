# Decoder Quality Roadmap

Living document tracking three workstreams: decoder quality, evaluation harness quality, and improvement machine quality. Updated by the `/improve-decoders` skill after each iteration.

**Last updated:** 2026-03-22 (after 18 iterations)

---

## 1. Decoder Quality

### Current Standings

| Decoder | Score | Tests | SNR Floor (100% CER=0) | fldigi Target (1% CER) | Gap |
|---------|-------|-------|----------------------|----------------------|-----|
| JS8Call | 100.0 | 82 | -21 dB | N/A (matches FT8) | 0 dB |
| PSK | 98.2 | 98 | ~8 dB | -10 dB | **18 dB** |
| RTTY | 93.7 | 97 | ~10 dB | -5 dB | **15 dB** |
| CW | 90.5 | 93 | ~0 dB | -10 dB | **10 dB** |

### RTTY Decoder (93.4/100)

**Committed improvements:**
- [x] Simple normalized correlation replacing W7AY ATC (+3.2 composite) — immune to selective fading
- [x] Spectral SNR confidence scaling — suppresses noise-induced false correlations
- [x] Stop bit validation + USOS — false positive suppression

**Category breakdown:**

| Category | Score | Weight | Status |
|----------|-------|--------|--------|
| clean | 100.0 | 2.0 | Done |
| baud_rate | 100.0 | 1.0 | Done |
| noise | 100.0 | 2.5 | Done |
| fading | 100.0 | 2.0 | Done |
| freq_drift | 100.0 | 2.0 | Done |
| long_message | 100.0 | 2.0 | Done |
| impulse_noise | 100.0 | 2.5 | Done — inherently robust (bandpass rejects broadband impulses) |
| equipment | 100.0 | 1.5 | Done — FSK immune to amplitude distortion |
| false_positive | 95.0 | 1.5 | Near ceiling |
| itu_channel | 94.4 | 2.5 | Only ITU disturbed (2.5 Hz Doppler) fails |
| selective_fading | 88.0 | 3.0 | space_-15dB and space_-20dB fail (known tradeoff of simple correlation) |
| adj_channel | 81.0 | 2.5 | +200 Hz at equal/strong power — limited by 91 Hz Goertzel resolution |
| combined | 73.3 | 3.0 | Contest multi-signal scenario fails |

**Next improvements (by priority):**

| Priority | Technique | Expected Gain | Effort | Source |
|----------|-----------|--------------|--------|--------|
| 1 | **W7AY equalized raised cosine filter** | Zero ISI, +2-3 dB noise performance | Medium | w7ay.net/site/Technical/EqualizedRaisedCosine |
| 2 | **2Tone selective decoder** (process mark/space independently) | +5-10 on selective_fading, adj_channel | Medium | G3YYD, rttycontesting.com |
| 3 | **Complex demodulation** (dual mixer + complex FFT filter per tone) | +5-10 on adj_channel, ITU disturbed | High | fldigi rtty.cxx:666-670 |
| 4 | **Multi-decoder diversity** (run simple correlation + ATC, pick best) | +2-5 on weak spots | Low | N1MM+ contest best practice |
| 5 | **Impulse blanker** (mute samples > 3x RMS before bandpass) | +5-10 dB on lower bands with QRN | Low | MIL-STD-188-110 |

**Approaches that failed (DO NOT RETRY):**
- Faster envelope tracking (any variant, 6+ attempts)
- Peak-based fading detection (sliding window peaks)
- Correlation-gated envelope (any threshold variant)
- Per-tone floor subtraction (IIR or sliding window minimum)
- Larger Goertzel window (straddles bit boundaries)
- FFT bandpass with margin < 75 Hz (cuts signal sidebands)
- Noise subtraction in simple correlation (unstable near-zero ratios)

### PSK Decoder (98.2/100)

**Committed improvements:**
- [x] Two-phase AFC (preamble estimation + decision-directed tracking)
- [x] Sub-symbol preamble frequency estimation
- [x] Phase quality sustain check

**Score history:** 83.9 → 91.8 (AFC) → 97.6 (preamble) → 99.3 (merged) → 96.3 (harder tests) → 98.2 (better FP coverage)

**Next improvements:**

| Priority | Technique | Expected Gain | Effort | Source |
|----------|-----------|--------------|--------|--------|
| 1 | **Costas loop carrier recovery** | +2-3 on freq_offset | Medium | fldigi psk.cxx, Rahsoft tutorial |
| 2 | **FIR matched filter** (replace IIR with raised-cosine) | +3-5 dB noise performance | Medium | PSK_RND_NOTES.md |
| 3 | **Soft-decision Viterbi** for QPSK modes | +3-4 dB | High | fldigi viterbi.cxx |
| 4 | **QPSK leading space fix** | +3 points | Low | PSK_RND_NOTES.md |

**Approaches that failed (DO NOT RETRY):**
- Phase quality threshold changes (0.70→0.75 regressed freq_offset by -23)
- Signal persistence increase (4→6 catastrophic, 96.9→27.9)
- SNR acquire threshold increase (8→10 catastrophic, 96.9→7.8)

### CW Decoder (90.5/100)

**Committed improvements:**
- [x] Faster signal level decay (0.9→0.85) for multipath resilience

**Category breakdown:**

| Category | Score | Weight | Status |
|----------|-------|--------|--------|
| qrm | 56.7 | 2.0 | **#1 weakness** — +50 Hz interferer scores 20%, Goertzel can't distinguish |
| itu_channel | 72.5 | 2.5 | ITU disturbed (2.5 Hz Doppler) = 0%, poor+noise has K→A errors |
| noise | 92.3 | 2.0 | Non-monotonic (seed-dependent errors, not systematic) |
| jitter | 92.4 | 2.0 | Hand-sent CW handled well but not perfectly |
| combined | 91.6 | 2.5 | Moderate — limited by component weaknesses |

**Next improvements:**

| Priority | Technique | Expected Gain | Effort | Source |
|----------|-----------|--------------|--------|--------|
| 1 | **CW matched filter** (auto-adjust bandwidth to WPM) | +5-10 on noise, ITU | Medium | AG1LE: 35 Hz filter = -10 dB CER<2% |
| 2 | **Bayesian probability framework** | +10-20 on QRM, noise | High | CW Skimmer/VE3NEA (8 years R&D) |
| 3 | **Dual-Goertzel interference cancellation** | +10-15 on QRM | Medium | Detect interferer via AFC, subtract leakage |
| 4 | **Impulse blanker** | +5-10 dB on lower bands | Low | MIL-STD-188-110 |

**Approaches that failed (DO NOT RETRY):**
- Narrower bandpass (±50 Hz cuts keying sidebands)
- More filter taps (769 worse than 513 and 1025; non-monotonic, group delay tradeoff)
- Lower threshold fractions (hurt ITU channel without helping QRM)
- Noise floor tracking during brief gaps (raised noise estimate, hurt fading)
- Dual-Goertzel interference cancellation via AFC (AFC can't distinguish our signal from interferer — subtracted our own tone, 90.5→23.5)
- Post-Goertzel IIR smoothing (blurs on/off transitions; 33 ms time constant vs 60 ms dit = elements unrecognizable, 90.5→10.8)

### JS8Call Decoder (100.0/100)

Perfect score across 82 tests. LDPC(174,91) error correction makes it extremely robust. No improvements needed. Sensitivity matches FT8 at -21 dB.

---

## 2. Evaluation Harness Quality

### Current Test Coverage

| Decoder | Tests | Categories | Real-World Conditions |
|---------|-------|------------|----------------------|
| JS8Call | 82 | 10 | clean, noise, freq_offset, fading, ITU, clock_offset, combined, multi_signal, false_positive |
| PSK | 98 | 16 | clean, noise, freq_offset, noise_offset, timing_jitter, adj_channel, all_modes (x4 variants), bpsk63_stress, fading, ITU, long_msg, false_positive |
| RTTY | 93 | 13 | clean, baud_rate, noise, selective_fading, adj_channel, freq_drift, fading, ITU, combined, long_message, impulse_noise, equipment, false_positive |
| CW | 93 | 12 | clean, speed, noise, freq_offset, fading, ITU, jitter, dash_dot, combined, long_message, qrm, false_positive |

### Missing Conditions (by priority)

| Condition | Impact | Which Decoders | Status |
|-----------|--------|---------------|--------|
| **Auroral flutter** (10-100 Hz Doppler) | Destroys narrowband modes on polar paths | RTTY, PSK, CW | RTTY TESTED: 80.6/100 (72-78% per test, noise helps via stochastic resonance). PSK/CW NOT TESTED |
| **NVIS O/X mode splitting** (2-path, 0.5-2 ms delay) | Deep slow fades on 80m/60m | RTTY, PSK | RTTY TESTED: **100%** (all 4 tests perfect — low Doppler + moderate delay well within capability). PSK NOT TESTED |
| **Narrowband interference within passband** (carrier at midpoint) | Tests spectral selectivity | RTTY, CW | RTTY TESTED: **40.3/100** — midpoint carrier (0%) kills spectral SNR metric; near-tone carriers (78-83%) degrade but decode |
| **AGC pumping** (10 dB sinusoidal gain, 2-5 Hz) | Simulates nearby strong station keying | All | RTTY TESTED: 100% (FSK is amplitude-independent). PSK/CW NOT TESTED |
| **Sample rate mismatch** (48000 vs 47950 Hz) | Common with cheap USB audio | All | RTTY TESTED: 100% (50 ppm tolerated). PSK/CW NOT TESTED |
| **Wrong sideband** (RTTY LSB/USB swap) | Common operator error | RTTY | TESTED: 16.7% inverted (garbage "AQAQAQ"), 100% normal. Decoder has `polarityInverted` flag but no auto-detection |
| **CW chirp** (30 Hz shift on key-down) | Older/simpler transmitters | CW | TESTED: 73.3% (all severity levels identical — loses first word, rest correct) |
| **Real-world recordings** (WebSDR + fldigi ground truth) | The ultimate validation | All | NOT SET UP |

### Harness Architecture Improvements Needed

| Improvement | Impact | Status |
|------------|--------|--------|
| **`--params` CLI flag** on all benchmarks (for automated optimization) | Enables Layer 1 optimization | **RTTY DONE** (correlationThreshold, stopBitThreshold). PSK/CW TODO |
| **WSJT-X style SNR sweep** (1000 trials per SNR point, report decode probability) | Gold-standard methodology | NOT IMPLEMENTED |
| **CI benchmark regression gate** (fail PR if score drops) | Prevents regressions in normal development | NOT IMPLEMENTED |
| **Property-based tests** (SwiftCheck: round-trip, monotonicity, frequency invariance) | Catches edge cases | NOT IMPLEMENTED |
| **Metamorphic tests** (time shift, amplitude scale, frequency shift invariance) | Validates decoder properties | NOT IMPLEMENTED |
| **Real-recording test corpus** (WebSDR captures with fldigi ground truth) | Real-world validation | NOT SET UP |
| **Fuzz testing** (random audio input → no crash, no invalid output) | Robustness guarantee | NOT IMPLEMENTED |

---

## 3. Improvement Machine Quality

### Architecture

```
Layer 1: Automated Parameter Optimization (CMA-ES / Optuna)
  └── Requires: --params CLI flag, Python wrapper scripts
  └── Status: NOT SET UP
  └── Expected: 200 Optuna trials = ~3.3 hours = explore parameter spaces
                 humans can't in 17 iterations

Layer 2: Benchmark Hardening (Real-World Conditions)
  └── Add missing conditions from Section 2
  └── Status: ACTIVE (impulse noise + equipment added in iter 18)
  └── Alternates with Layer 3 on even iterations

Layer 3: Agentic Algorithm Improvement (Claude Code /improve-decoders)
  └── For architectural changes requiring DSP theory
  └── Status: ACTIVE (odd iterations)
  └── Key constraint: Max 3 attempts per iteration, strict regression guard
```

### Process Improvements Needed

| Improvement | Impact | Status |
|------------|--------|--------|
| **Optuna/CMA-ES pipeline** | Explores 200+ parameter combinations overnight | NOT SET UP — needs --params flag |
| **Multi-objective optimization** (pymoo NSGA-II: decode rate vs false positive) | Finds Pareto-optimal tradeoffs | NOT SET UP |
| **Faster benchmarks** (`swift build -c release`) | 2-5× faster iteration cycle | NOT STANDARDIZED |
| **Score persistence** (SQLite or CSV with all category scores per run) | Track progress across sessions | PARTIAL (CSV exists but not comprehensive) |
| **Automated comparison to fldigi** (decode same WAV, compare CER) | Ground-truth validation | NOT SET UP |

### Iteration Log

| Iter | Type | Target | Result | Key Finding |
|------|------|--------|--------|-------------|
| 1 | Decoder | PSK false_positive | 0/3 succeeded | Phase quality, persistence, SNR threshold all cause cascading regressions |
| 2 | Bench | RTTY long_message | +3 tests added | ATC envelope NEVER converges for -10 dB selective fading on 88-char messages |
| 3 | Decoder | RTTY selective_fading | 0/3 succeeded | Gated envelope tracking causes regressions regardless of gating threshold |
| 4 | Bench | CW long_message + QRM | +11 tests added | CW QRM at 56.7 — major weakness discovered |
| 5 | Decoder | CW QRM | 0/3 succeeded | Filter changes non-monotonic; narrower cuts sidebands, wider adds latency |
| 6 | Bench | PSK false_positive | +2 tests added | Adaptive squelch works perfectly (100%); manual squelch failures are seed-specific |
| 7 | Decoder | CW itu_channel | Marginal | Signal decay 0.9→0.85 kept (no regression, +0-2.5 on ITU) |
| 8 | Bench | RTTY graduated fading | +2 tests added | Graduated fading shows ATC fails at ~-6 to -8 dB mark attenuation |
| **9** | **Decoder** | **RTTY selective_fading** | **+3.2 composite!** | **Simple correlation replacing ATC — the breakthrough** |
| 10 | Bench | RTTY adj_channel | +2 tests added | Decoder handles ≥250 Hz offset and ≤0.25× power at 200 Hz |
| 11 | Decoder | CW QRM | 0/2 succeeded | Noise floor tracking and threshold changes don't help QRM |
| 12 | Bench | Documentation | R&D notes compiled | Comprehensive documentation of all findings |
| 13 | Decoder | RTTY adj_channel | 0/2 succeeded | Floor subtraction: minimum is always ~0 (off-tone in window) |
| 14 | Bench | Unit test fix | 351/351 passing | Multi-channel test adjusted for simple correlation tradeoff |
| 15 | Decoder | RTTY adj_channel | 0/1 succeeded | Larger Goertzel window catastrophic (straddles bit boundaries) |
| 16 | Bench | Documentation | Final R&D notes | All findings captured |
| 17 | Decoder | RTTY selective_fading | 0/1 succeeded | SNR confidence curve change didn't fix space_-15dB (not the cause) |
| 18 | Bench | Impulse noise + equipment | +8 tests added | RTTY inherently robust to impulse noise and audio distortion |
| 19 | Decoder | CW QRM (dual-Goertzel) | 0/1 — catastrophic (23.5) | AFC can't distinguish our signal from interferer; subtracted our own tone |
| 20 | Bench | RTTY auroral flutter | +4 tests, 80.6/100 | 10-50 Hz Doppler degrades to 72-78%. Non-monotonic: noise helps via stochastic resonance |
| **21** | **Decoder** | **RTTY hybrid correlation** | **+1.2 composite (92.5→93.7)** | **Hybrid simple+ATC: use ATC when signal confirmed (SNR>5) and agrees with simple. +12.5 auroral, +5.6 selective_fading** |
| 22 | Bench | RTTY AGC pumping + sample rate | +3 tests, all 100% | FSK is amplitude-independent; decoder handles 15 dB AGC pumping and 50 ppm clock error |
| 23 | Decoder | CW post-Goertzel smoothing | 0/1 — catastrophic (10.8) | IIR on block output blurs on/off transitions. 33 ms time constant vs 60 ms dit = elements unrecognizable |
| 24 | Bench | RTTY narrowband interference | +4 tests, 40.3/100 | **Critical flaw found**: midpoint carrier kills spectral SNR metric → snrConfidence=0 → total decode failure |
| 25 | Decoder | RTTY narrowband_qrm fix | 0/2 — min(nMid,(m+s)/2) capped SNR at 2.0; carrier bypass triggered on noise | Midpoint carrier vulnerability requires a different noise detection approach (not midpoint-based) |
| 26 | Bench | RTTY wrong sideband | +2 tests, 58.3/100 | Inverted polarity produces garbage "AQAQAQ" (16.7%). Auto-detection would need pattern analysis on decoded text |
| 27 | Decoder | PSK AFC warmup 2→3 | 0/1 — +15/+20 Hz improved but +30/+50 Hz crashed | Phase wrapping: 3 symbols × 30 Hz = 2.9 cycles, too many for unwrapping. 2 symbols is optimal. |
| 28 | Bench | CW chirp tests | +3 tests, 73.3/100 | All severity levels (15-50 Hz) identical output — loses first word only. CW composite 89.6 |
| 29 | Infra | RTTY --params CLI flag | Done | `swift run RTTYBenchmark -- --params /path/to/params.json` enables Optuna/CMA-ES optimization |
| 30 | Infra | Optuna optimization script | Done | `python3 scripts/optimize_rtty.py --trials 100` explores parameter space automatically |
| 31 | Decoder | RTTY parameter sweep | No improvement | correlationThreshold 0.20 is optimal (±0.05 loses ~1 point). stopBitThreshold is insensitive (0.02-0.10 all identical). Parameters confirmed at local optimum. |
| 32 | Bench | RTTY NVIS tests | +4 tests, 100% | All O/X splitting scenarios (0.5-2 ms delay, 0.1-0.2 Hz Doppler) handled perfectly. RTTY now 110 tests, 17 categories |
| 33 | Decoder | PSK QPSK leading space | Already fixed | QPSK leading space was fixed previously (97.6 entry in PSK_RND_NOTES). All QPSK tests now 100%. |
| 34 | Bench | PSK auroral flutter | +4 tests, 100% | PSK31 handles even 25 Hz Doppler perfectly. PSK now 102 tests. Composite 98.3 |
| 35 | Bench/Fix | CW chirp preamble fix | chirp 73.3→100, CW 89.6→91.4 | Previous 73.3% was test artifact (missing preamble). Decoder handles all chirp levels perfectly. |
| 36 | Bench | CW auroral flutter | +3 tests, 100% | CW handles 10-50 Hz Doppler perfectly. Goertzel averaging smooths flutter. CW 99 tests, composite 91.3 |
| 37 | Infra | Verification + commit | 351/351 tests pass | All accumulated work verified. 1Password blocking commit — changes in working tree. |
| 38 | Status | Machine at steady state | All conditions tested | 393 benchmark tests, parameters optimal, remaining improvements need architectural changes |
| 39+ | Parallel | 8 architectural teammates | 6 merged, 3 running | BayesianCW, GFSK layer, FT8 codec+UI, 2Tone RTTY, BayesianCW integration all merged. Spectral SNR fix, W7AY ERC, Optuna CW optimizer still running. |

### Key Principles (Learned Over 38+ Iterations)

1. **Algorithmic changes >> parameter tweaks.** The only committed decoder improvement was replacing an algorithm (ATC → simple correlation). All ~20 parameter tweaks caused regressions.

2. **The regression guard is sacred.** Every reverted change would have degraded overall performance. The 0.5-point threshold catches real problems.

3. **Benchmark hardening is as valuable as decoder improvement.** New tests revealed that CW QRM is a major weakness, RTTY handles impulse noise perfectly, and PSK adaptive squelch works flawlessly.

4. **Filter quality matters most.** AG1LE's CW research and fldigi's architecture both confirm that filter bandwidth and shape have more impact than decoder algorithm sophistication.

5. **DSP parameters are tightly coupled.** Envelope tracking rates, filter bandwidths, and squelch thresholds are jointly optimized. Changing one cascades to others.

6. **Parallel worktree agents scale well.** Launching 8 isolated teammates for architectural changes produces more in one session than 38 sequential iterations. Each worktree is independently testable.

7. **New decoders need parameter optimization.** BayesianCW scores 84.4 vs classic 97.8 — the algorithm is sound but defaults need Optuna tuning. First implementations are starting points, not finished products.

---

## 4. Software Quality

### Patch Quality Assessment

**What's working well:**
- Commits include benchmark scores in messages (easy to track progress)
- 401 unit tests all passing (351 original + 50 FT8 codec)
- Regression guard prevented ~25 bad changes from being committed
- Benchmark JSON output enables automated analysis

**What needs improvement:**

| Issue | Impact | Fix |
|-------|--------|-----|
| **Giant commits** (57 files/14K lines in b627c50) | Hard to review, hard to revert pieces | Break into focused PRs: decoder changes separate from benchmark changes separate from UI |
| **No CI** (.github/workflows/ referenced in CLAUDE.md but doesn't exist) | Regressions only caught manually | Add GitHub Actions: `swift build && swift test` on push/PR |
| **8 new files with zero unit tests** (GFSK layer, BayesianCW, SelectiveRTTY) | Regressions can sneak in | Add round-trip tests for each new component |
| **1Password blocking commits** | Accumulates uncommitted work risk | Use HTTPS remote or deploy key instead of SSH |
| **Worktree merges are manual copy** | Error-prone, can miss files | Use `git merge` from worktree branches instead of file copies |
| **No benchmark in CI** | Score regressions only caught by manual runs | Add benchmark score check to CI (fail if composite drops >0.5) |
| **Benchmark takes 45 min for JS8** | Can't run full suite in CI | Add `--quick` flag for CI (subset of tests, ~2 min) |

### Test Coverage Gaps

**Tested (with unit tests):**
- Codecs: BaudotCodec, VaricodeCodec, FT8Codec, ConvolutionalCodec
- Modulators: FSKModulator, PSKModulator (round-trip tests)
- Demodulators: FSKDemodulator, PSKDemodulator (round-trip tests)
- Filters: GoertzelFilter, BandpassFilter, SineGenerator
- Integration: MultiChannelRTTY, JS8Call round-trip

**NOT tested (missing unit tests):**
- BayesianCWDecoder (462 lines, 0 tests)
- SelectiveRTTYDecoder (320 lines, 0 tests)
- GFSKModulator, GFSKSyncSearch, GFSKSymbolExtractor, GFSKDecoder (790 lines, 0 tests)
- CWDemodulator, CWModulator, CWModem (existing, never had unit tests)
- OverlapAddFilter, FFTProcessor, WattersonChannel (DSP building blocks)
- MorseCodec (used by CW, no direct tests)
- LDPC174_87 (critical codec, no direct tests)

**Benchmark tests vs unit tests:**
- Benchmarks test the full decode pipeline end-to-end (393 tests)
- Unit tests test individual components in isolation (401 tests)
- Gap: new components (GFSK, Bayesian, Selective) have benchmark coverage via the full pipeline but NO isolation tests. A bug in GFSKSyncSearch could be masked by the JS8 demodulator's error handling.

### Recommended Software Quality Improvements

**Priority 1 — CI Pipeline (1 day)**
```yaml
# .github/workflows/test.yml
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: cd AmateurDigital/AmateurDigitalCore && swift build
      - run: cd AmateurDigital/AmateurDigitalCore && swift test
      - run: cd AmateurDigital/AmateurDigitalCore && swift run -c release RTTYBenchmark 2>&1 | tee /tmp/bench.txt
      - run: python3 -c "import json; s=json.load(open('/tmp/rtty_benchmark_latest.json'))['composite_score']; assert s >= 88.0, f'Regression: {s}'"
```

**Priority 2 — Unit tests for new code (2 days)**
- GFSK round-trip: modulate symbols → sync search → extract → verify symbols match
- BayesianCW: feed known CW audio → verify decoded characters
- SelectiveRTTY: feed known RTTY audio → verify decoded text
- MorseCodec: encode → decode round-trip for all characters
- LDPC: encode → corrupt → decode → verify recovery

**Priority 3 — Smaller commits (process change)**
- Decoder changes: 1 commit per decoder modification + benchmark result
- Benchmark additions: 1 commit per new test category
- New files: 1 commit per logical component (not 57 files at once)
- Never mix iOS app changes with core library changes

**Priority 4 — Automated benchmark regression (1 day)**
- Store baseline scores in `benchmarks/baselines.json`
- CI compares current scores against baselines
- PR comment shows score diff table
- Block merge if any category regresses >0.5 points
