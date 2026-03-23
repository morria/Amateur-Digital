#!/usr/bin/env python3
"""
Optuna optimization of mode classifier thresholds.

Runs the Swift ModeDetectionTrainer as a black-box objective function,
optimizing classifier thresholds for maximum accuracy on real-world samples.

Usage:
    cd ModeClassifierTraining
    python3 optuna_optimize.py --trials 200
    python3 optuna_optimize.py --trials 500 --timeout 3600  # 1 hour max

Requires: pip install optuna
"""

import optuna
import subprocess
import json
import os
import sys
import argparse
import re

# The trainer outputs lines like:
#   [OK] RTTY     53/64 (82%)
#   Overall: 234/257 (91%)
# We parse these to get per-mode and overall accuracy.

TRAINER_CMD = [
    "swift", "run", "ModeDetectionTrainer"
]
TRAINER_CWD = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "AmateurDigital", "AmateurDigitalCore"
)

# Thresholds to optimize — these are the key ones identified through 15+ improvement cycles.
# Each maps to a specific line/value in ModeClassifier.swift
PARAM_SPEC = {
    # Signal detection gate
    "signal_peak_threshold_db": (8.0, 20.0, 12.0),   # peaks must be > X dB above noise
    "signal_flatness_max": (0.5, 0.95, 0.8),          # spectral flatness must be < X

    # RTTY scorer
    "rtty_fsk_no_valley_bonus_3plus": (0.15, 0.55, 0.40),  # bonus for 3+ FSK pairs without valley
    "rtty_fsk_no_valley_cv_max": (0.2, 0.6, 0.5),          # max CV for no-valley path
    "rtty_bw_penalty_wide": (0.02, 0.20, 0.15),            # penalty for BW > 500 Hz
    "rtty_peak_bw_threshold": (20.0, 35.0, 25.0),          # peak BW above X is too wide for RTTY

    # PSK scorer
    "psk_narrow_peak_bonus": (0.20, 0.50, 0.35),      # bonus for narrow peak detection
    "psk_bw_match_bonus": (0.05, 0.25, 0.15),         # bonus for BW matching baud rate
    "psk_cv_high_penalty": (0.05, 0.30, 0.25),        # penalty when CV > 0.7 + transitions < 20
    "psk_min_peak_bw": (18.0, 28.0, 22.0),            # peaks narrower than X are CW, not PSK
    "psk_flatness_penalty": (0.05, 0.25, 0.15),       # penalty when flatness > 0.5

    # CW scorer
    "cw_narrow_peak_bonus": (0.30, 0.60, 0.45),       # bonus for CW-narrow peak (< 22 Hz)
    "cw_ook_bonus": (0.20, 0.50, 0.35),               # bonus for confirmed OOK
    "cw_narrow_peak_threshold": (18.0, 25.0, 22.0),   # peak BW below X is CW-narrow

    # JS8Call/FT8 scorer
    "js8_low_transition_bonus": (0.25, 0.55, 0.40),   # bonus for transition rate < 2/s
    "js8_peak_bw_min": (15.0, 30.0, 20.0),            # GFSK peak BW range min
    "js8_peak_bw_max": (60.0, 80.0, 70.0),            # GFSK peak BW range max
    "js8_gfsk_cv_bonus": (0.15, 0.40, 0.25),          # bonus for constant-envelope GFSK
    "js8_baud_rate_bonus": (0.15, 0.40, 0.25),        # bonus for baud rate 6.25 match

    # Noise scorer
    "noise_weak_peak_bonus": (0.05, 0.25, 0.15),      # bonus when peak < 15 dB
    "noise_broadband_bonus": (0.25, 0.55, 0.40),      # bonus when flatness > 0.8
}


def run_trainer(params=None):
    """Run the Swift trainer and parse results."""
    cmd = list(TRAINER_CMD)
    if params:
        # Pass thresholds as JSON via env var
        env = os.environ.copy()
        env["MODE_CLASSIFIER_PARAMS"] = json.dumps(params)
        result = subprocess.run(cmd, capture_output=True, text=True, cwd=TRAINER_CWD, env=env, timeout=120)
    else:
        result = subprocess.run(cmd, capture_output=True, text=True, cwd=TRAINER_CWD, timeout=120)

    output = result.stdout + result.stderr

    # Parse overall accuracy
    overall_match = re.search(r'Overall:\s+(\d+)/(\d+)', output)
    if not overall_match:
        return None

    correct = int(overall_match.group(1))
    total = int(overall_match.group(2))
    overall = correct / total if total > 0 else 0

    # Parse per-mode accuracy
    modes = {}
    for match in re.finditer(r'\[(?:OK|\.\.| XX)\]\s+(\w+)\s+(\d+)/(\d+)', output):
        mode = match.group(1)
        mode_correct = int(match.group(2))
        mode_total = int(match.group(3))
        modes[mode] = mode_correct / mode_total if mode_total > 0 else 0

    return {
        "overall": overall,
        "correct": correct,
        "total": total,
        "modes": modes,
    }


def objective(trial):
    """Optuna objective: maximize overall accuracy with per-mode constraints."""
    params = {}
    for name, (lo, hi, default) in PARAM_SPEC.items():
        params[name] = trial.suggest_float(name, lo, hi)

    result = run_trainer(params)
    if result is None:
        return 0.0

    # Primary objective: overall accuracy
    score = result["overall"]

    # Penalty: no mode should drop below 70%
    for mode, acc in result["modes"].items():
        if acc < 0.7:
            score -= 0.1 * (0.7 - acc)  # proportional penalty

    # Bonus: FT8 improvement is especially valuable
    ft8_acc = result["modes"].get("FT8", 0)
    score += ft8_acc * 0.05  # small bonus for FT8

    return score


def main():
    parser = argparse.ArgumentParser(description="Optuna mode classifier optimization")
    parser.add_argument("--trials", type=int, default=100, help="Number of optimization trials")
    parser.add_argument("--timeout", type=int, default=None, help="Max seconds for optimization")
    parser.add_argument("--baseline", action="store_true", help="Just run baseline, no optimization")
    args = parser.parse_args()

    print("Mode Classifier Optuna Optimization")
    print("=" * 60)

    # Baseline
    print("\nBaseline (current thresholds):")
    baseline = run_trainer()
    if baseline:
        print(f"  Overall: {baseline['correct']}/{baseline['total']} ({baseline['overall']:.1%})")
        for mode, acc in sorted(baseline["modes"].items()):
            print(f"    {mode:10s} {acc:.1%}")
    else:
        print("  ERROR: Could not run trainer")
        return

    if args.baseline:
        return

    # Note: The current classifier has hardcoded thresholds. To use Optuna effectively,
    # the classifier would need to read thresholds from the MODE_CLASSIFIER_PARAMS env var.
    # This is a placeholder showing the optimization framework.
    print(f"\nNote: The classifier currently uses hardcoded thresholds.")
    print(f"To enable Optuna optimization, the ModeClassifier.swift needs to read")
    print(f"thresholds from a configuration source (env var, file, or command-line args).")
    print(f"")
    print(f"The {len(PARAM_SPEC)} parameters to optimize are:")
    for name, (lo, hi, default) in sorted(PARAM_SPEC.items()):
        print(f"  {name:40s} [{lo:.2f} - {hi:.2f}] default={default:.2f}")

    # Run optimization
    print(f"\nOptimizing {len(PARAM_SPEC)} parameters over {args.trials} trials...")
    print(f"Each trial runs the Swift trainer (~5s) and evaluates accuracy.")
    print()

    study = optuna.create_study(
        direction="maximize",
        sampler=optuna.samplers.TPESampler(seed=42),
        study_name="mode_classifier"
    )

    study.optimize(objective, n_trials=args.trials, timeout=args.timeout)

    # Results
    print()
    print("=" * 60)
    print("OPTIMIZATION RESULTS")
    print("=" * 60)
    print(f"Best trial: #{study.best_trial.number}")
    print(f"Best score: {study.best_trial.value:.4f}")
    print()
    print("Best parameters:")
    for name, value in sorted(study.best_params.items()):
        lo, hi, default = PARAM_SPEC[name]
        delta = value - default
        print(f"  {name:40s} = {value:.4f}  (default {default:.4f}, delta {delta:+.4f})")

    # Run trainer with best params to show detailed results
    print()
    print("Best trial detailed results:")
    best_result = run_trainer(study.best_params)
    if best_result:
        print(f"  Overall: {best_result['correct']}/{best_result['total']} ({best_result['overall']:.1%})")
        for mode, acc in sorted(best_result["modes"].items()):
            flag = "  " if acc >= 0.95 else " *" if acc >= 0.8 else "**"
            print(f"  {flag} {mode:10s} {acc:.1%}")

    # Save best params
    best_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "optuna_best_params.json")
    with open(best_path, "w") as f:
        json.dump(study.best_params, f, indent=2)
    print(f"\nSaved best params to: {best_path}")
    print(f"To use: MODE_CLASSIFIER_PARAMS=$(cat {best_path}) swift run ModeDetectionTrainer")


if __name__ == "__main__":
    main()
