---
name: improve-decoders
description: Run one iteration of the decoder improvement machine. Alternates between decoder improvement (odd) and benchmark hardening (even). Designed for `/loop 30m /improve-decoders`.
user-invocable: true
---

# Decoder Improvement Machine

You are running one iteration of the Amateur Digital decoder improvement machine.

## Primary Reference: `docs/decoder-roadmap.md`

This is the **single source of truth**. Read it FIRST every iteration. It contains:
- Current scores and category breakdowns for all decoders
- Prioritized next improvements with expected gains and effort levels
- Failed approaches (DO NOT RETRY) per decoder
- Missing benchmark conditions to add
- Improvement machine process improvements
- Iteration log

**After every iteration, UPDATE `docs/decoder-roadmap.md`** with:
- New scores if benchmarks were run
- New entries in the iteration log table
- Any approaches tried (successful or failed) added to the appropriate section
- Status changes on any roadmap items (e.g., "NOT TESTED" → "TESTED — score X")

## Secondary References

- `improvement-machine.md` — Three-layer architecture and research sources
- `AmateurDigital/AmateurDigitalCore/RTTY_RND_NOTES.md` — RTTY-specific detailed R&D
- `AmateurDigital/AmateurDigitalCore/PSK_RND_NOTES.md` — PSK AFC implementation details
- `.reference/fldigi-research.md` — fldigi algorithm comparison and porting roadmap
- `research/fldigi/src/cw_rtty/rtty.cxx` — fldigi RTTY reference implementation
- `research/fldigi/src/cw_rtty/cw.cxx` — fldigi CW reference implementation

## Determine Iteration Type

Count iterations from conversation history. If unclear, default to odd.

- **Odd iterations**: Improve decoder performance (Section 1 of roadmap)
- **Even iterations**: Harden evaluation harness (Section 2 of roadmap)

## For Odd Iterations (Decoder Improvement)

### Step 1: Assess
Read `docs/decoder-roadmap.md` Section 1 for current scores. Run the benchmark for the weakest decoder. Identify the single worst `(100 - category_score) * weight`.

### Step 2: Choose ONE Target
Consult the "Next improvements" table for the target decoder in the roadmap. Pick the highest-priority item that hasn't been attempted. **CHECK the "Approaches that failed" list — DO NOT RETRY listed approaches.**

Prefer items marked as:
- **Low effort** for quick wins
- **Medium effort** for the core of the iteration
- **High effort** only if you have a clear implementation plan

### Step 3: Research
Read the relevant modem source code AND reference implementation listed in the roadmap. Generate a specific hypothesis: "Changing X will improve Y by ~N points because [DSP reasoning]."

### Step 4: Implement with Regression Guard
Make the change. Run the benchmark. **CRITICAL**: If ANY category drops more than 0.5 points, REVERT immediately. Max 3 attempts per iteration.

### Step 5: Record Results
1. Update `docs/decoder-roadmap.md` — iteration log, score changes, any new failed approaches
2. Update the relevant `*_RND_NOTES.md` if the change was significant
3. If the change was committed, update the scores in Section 1 of the roadmap

## For Even Iterations (Benchmark Hardening)

### Step 1: Assess
Read `docs/decoder-roadmap.md` Section 2 "Missing Conditions" table. Pick the highest-priority condition marked "NOT TESTED".

### Step 2: Implement Tests
Add the new test condition to the appropriate benchmark file. Include:
- A helper function for the impairment (in the signal impairments section)
- 2-4 test cases with varying severity
- A weight for the new category (typically 1.5-2.5)

### Step 3: Run and Analyze
Run the benchmark. Document which tests pass and fail. The results tell us where the decoder is naturally robust and where it needs improvement.

### Step 4: Record Results
1. Update `docs/decoder-roadmap.md` — change "NOT TESTED" to result, add to iteration log
2. If new weaknesses found, add them to the decoder's "Next improvements" table

## Circuit Breakers

- **Max 3 code change attempts** per iteration
- **If stuck on same category 3+ iterations**: Switch decoders or focus on benchmark hardening
- **If all decoders at local optima for incremental changes**: Focus on:
  - Setting up Layer 1 (automated parameter optimization — `--params` CLI flag)
  - Infrastructure improvements (CI regression gate, property-based tests)
  - Architectural changes (complex demodulation, matched filters) that span multiple files
- **Never commit regressions** — baseline only moves forward
- After documenting results, the iteration is complete. Stop and wait for next invocation.

## Quick Reference

```bash
cd AmateurDigital/AmateurDigitalCore
swift run RTTYBenchmark 2>&1 | tail -20    # ~45 sec
swift run PSKBenchmark 2>&1 | tail -20     # ~60 sec
swift run CWBenchmark 2>&1 | tail -20      # ~5 min
swift run JS8Benchmark 2>&1 | tail -20     # ~45 min (skip unless needed)
swift test 2>&1 | tail -5                   # ~10 sec, 351 tests
```
