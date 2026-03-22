---
name: improve-mode-classifier
description: Continually improve the digital mode classifier through iterative cycles of classifier tuning, evaluation hardening, and research.
user-invocable: true
---

You are improving the Amateur Digital mode detection classifier. Work in cycles:

## Cycle Structure

### Phase 1: Improve the Classifier

1. Run the trainer to get the current baseline:
   ```
   cd AmateurDigital/AmateurDigitalCore && swift run ModeDetectionTrainer
   ```
2. Examine every failure — run with `--dump-csv` to get feature values for failing cases
3. Identify the root cause pattern (wrong threshold, missing feature, training gap)
4. Fix the hand-tuned classifier (`Sources/AmateurDigitalCore/ModeDetection/ModeClassifier.swift`) based on training data patterns
5. Re-run the trainer to verify improvement and check for regressions
6. If accuracy improved, regenerate training data, re-extract features, retrain and re-export the GBM CoreML model:
   ```
   swift run GenerateModeTrainingData --count 50
   swift run ModeDetectionFeatureExtractor 1> ../../../ModeClassifierTraining/training_features.csv 2>/dev/null
   cd /Users/asm/d/Amateur-Digital/ModeClassifierTraining
   /tmp/coreml_venv/bin/python3 <train_and_export_script>
   ```
   The coreml venv uses Python 3.13 + coremltools 8.3 + scikit-learn 1.5.2 with patched `_tree_ensemble.py` and `tree_ensemble.py` for numpy scalar conversion.

### Phase 2: Improve the Evaluation Harness

1. Look at what real-world scenarios the current test set is missing. Consider:
   - Modes at unusual frequencies or baud rates
   - Modes combined with different noise types (ambient, hum, pink, band noise)
   - Signals at very low SNR where detection is marginal
   - Combined impairments (noise + fading + offset simultaneously)
   - Cross-mode confusion pairs that are spectrally similar
   - Real-world conditions not yet simulated (AGC pumping, adjacent signals, band noise)
2. Add new test cases to `Sources/ModeDetectionTrainer/main.swift`
3. Add corresponding training data generators to `Sources/GenerateModeTrainingData/main.swift`
4. Run the trainer to see if new tests expose weaknesses
5. Also run the official benchmark: `swift run ModeDetectionBenchmark`

### Phase 3: Research Improvements

1. Read the mode detection plan at `docs/mode-detection.md` for approaches not yet implemented
2. Consider what new spectral features might help (check `Sources/AmateurDigitalCore/ModeDetection/SpectralAnalyzer.swift` for what's currently extracted)
3. Look at the feature importance from the GBM training output to understand which features matter most
4. Consider whether new DSP techniques would help:
   - Baud rate estimation via cyclostationary analysis
   - RSID detection
   - Preamble/sync word detection
5. Check if the existing modulators can generate more realistic test signals
6. Study the confusion matrix to find systematic weaknesses

## Key Files

| File | Purpose |
|------|---------|
| `AmateurDigitalCore/Sources/AmateurDigitalCore/ModeDetection/ModeClassifier.swift` | Hand-tuned rule-based classifier (scores 11 features) |
| `AmateurDigitalCore/Sources/AmateurDigitalCore/ModeDetection/SpectralAnalyzer.swift` | FFT feature extraction (Accelerate vDSP) |
| `AmateurDigitalCore/Sources/AmateurDigitalCore/ModeDetection/ModeDetector.swift` | Public API, result types |
| `AmateurDigitalCore/Sources/ModeDetectionTrainer/main.swift` | Training harness (121+ test signals, accuracy tracking) |
| `AmateurDigitalCore/Sources/ModeDetectionBenchmark/main.swift` | Official benchmark (57 tests, composite score) |
| `AmateurDigitalCore/Sources/GenerateModeTrainingData/main.swift` | WAV generator for ML training (6400+ files) |
| `AmateurDigitalCore/Sources/ModeDetectionFeatureExtractor/main.swift` | Extracts features from WAVs to CSV |
| `ModeClassifierTraining/train_feature_model.py` | GBM training script |
| `ModeClassifierTraining/training_features.csv` | Feature CSV for GBM training |
| `AmateurDigital/ModeClassifierModel/` | Swift package wrapping CoreML model |
| `AmateurDigital/AmateurDigital/ViewModels/ChatViewModel.swift` | iOS integration (blends ML 70% + hand-tuned 30%) |

## Current Feature Set (11 features)

1. `bandwidth` — occupied bandwidth in Hz
2. `flatness` — spectral flatness (0=tonal, 1=noise)
3. `num_peaks` — number of spectral peaks above noise
4. `top_peak_power` — strongest peak's power above noise in dB
5. `top_peak_bw` — 3dB bandwidth of strongest peak in Hz
6. `fsk_pairs` — number of detected FSK mark/space pairs
7. `fsk_valley_pairs` — FSK pairs with spectral valley between tones
8. `envelope_cv` — coefficient of variation of amplitude envelope
9. `duty_cycle` — fraction of time signal is "on"
10. `transition_rate` — on/off transitions per second
11. `has_ook` — boolean: on-off keying detected

## Key Mode Signatures (from 6400-sample training)

| Feature | RTTY | PSK31 | CW | JS8Call | Noise |
|---------|------|-------|----|---------| ------|
| top_peak_bw | 17.2 Hz | 33.1 Hz | **17.6 Hz** | 45.0 Hz | 117+ Hz |
| transition_rate | 38/s | 35/s | **8/s** | **0.7/s** | 25-50/s |
| envelope_cv | **0.05** | 0.34 | **0.83** | 0.46 | **0.01-0.22** |
| fsk_valley_pairs | **4.2** | 0.1 | 3.0 | **0** | 0-1.4 |
| spectral_flatness | 0.09 | 0.09 | 0.04 | 0.14 | **0.95+** |
| duty_cycle | 0.47 | 0.59 | 0.48 | **0.68** | 0.25-0.45 |

## Rules

- Always run the trainer before AND after making changes
- Never break a test that was passing — regressions are worse than stagnation
- When adding features to SpectralAnalyzer, update the feature extraction in ModeDetectionFeatureExtractor and the feature dict in ChatViewModel.runModeDetection()
- The iOS app blends ML (70%) + hand-tuned (30%) — improve both
- Build the iOS app after changes: `cd /Users/asm/d/Amateur-Digital && xcodebuild -project AmateurDigital/AmateurDigital.xcodeproj -scheme AmateurDigital -destination 'platform=iOS Simulator,name=iPhone 16e' build`
- Run tests: `cd AmateurDigital/AmateurDigitalCore && swift test --filter ModeDetectorTests`
