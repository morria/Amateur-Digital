#!/usr/bin/env python3
"""
Bayesian CW Decoder Parameter Optimization using Optuna.

Uses the CWBenchmark's --bayesian-only and --bayesian-params flags to explore
the parameter space automatically, finding optimal values for the Bayesian
CW decoder's probabilistic tone detection, Gaussian element classification,
and beam search character hypothesis parameters.

Setup:
    python3 -m venv .venv
    source .venv/bin/activate
    pip install optuna

Usage:
    cd Amateur-Digital
    python3 scripts/optimize_cw_bayesian.py               # 100 trials
    python3 scripts/optimize_cw_bayesian.py --trials 50    # fewer trials
    python3 scripts/optimize_cw_bayesian.py --resume        # continue previous run
    python3 scripts/optimize_cw_bayesian.py --debug         # debug build (slower)
    python3 scripts/optimize_cw_bayesian.py --best          # show best params and exit

Results are stored in scripts/cw_bayesian_optimization.db (SQLite).
View best params:
    python3 -c "import optuna; s=optuna.load_study('cw_bayesian_v1', 'sqlite:///scripts/cw_bayesian_optimization.db'); print(s.best_params)"

Each trial takes ~2-3 minutes (release build, Bayesian decoder only).
100 trials ≈ 3-5 hours.
"""

import argparse
import json
import os
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
CORE_DIR = os.path.join(PROJECT_ROOT, "AmateurDigital", "AmateurDigitalCore")
PARAMS_PATH = "/tmp/cw_bayesian_params.json"
RESULTS_PATH = "/tmp/cw_benchmark_latest.json"
DB_PATH = os.path.join(SCRIPT_DIR, "cw_bayesian_optimization.db")
STUDY_NAME = "cw_bayesian_v1"


def run_benchmark(params: dict, release: bool = True) -> dict:
    """Run CWBenchmark with Bayesian params, return results dict.

    Args:
        params: Dictionary of BayesianCWParams fields to override.
        release: If True, build in release mode (much faster).

    Returns:
        Dictionary with 'composite_score' and 'tests' keys.
    """
    with open(PARAMS_PATH, "w") as f:
        json.dump(params, f)

    build_flag = ["-c", "release"] if release else []
    cmd = (
        ["swift", "run"]
        + build_flag
        + ["CWBenchmark", "--", "--bayesian-only", "--bayesian-params", PARAMS_PATH]
    )

    try:
        result = subprocess.run(
            cmd,
            cwd=CORE_DIR,
            capture_output=True,
            text=True,
            timeout=600,
        )
        if result.returncode != 0:
            # Print stderr for debugging on first failure
            if result.stderr:
                print(f"  [stderr] {result.stderr[:200]}", file=sys.stderr)
            return {"composite_score": 0.0, "tests": []}
    except subprocess.TimeoutExpired:
        print("  [timeout] Benchmark exceeded 10 minute limit", file=sys.stderr)
        return {"composite_score": 0.0, "tests": []}

    try:
        with open(RESULTS_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"composite_score": 0.0, "tests": []}


def objective(trial) -> float:
    """Optuna objective: maximize composite CW benchmark score.

    Suggests values for all tunable BayesianCWDecoder parameters.
    Parameter ranges are chosen to bracket the defaults with room to explore.
    """
    params = {
        # -- Tone probability model --
        "toneSmoothing": trial.suggest_float("toneSmoothing", 0.1, 0.9),
        "tonePriorWeight": trial.suggest_float("tonePriorWeight", 0.1, 0.9),
        "signalTrackingRate": trial.suggest_float("signalTrackingRate", 0.05, 0.5),
        "noiseTrackingRate": trial.suggest_float("noiseTrackingRate", 0.01, 0.2),
        "toneDetectionSNR": trial.suggest_float("toneDetectionSNR", 1.5, 10.0),
        "preambleBlocks": trial.suggest_int("preambleBlocks", 5, 40),
        # -- Element classification (Gaussian model) --
        "elementSigmaFraction": trial.suggest_float("elementSigmaFraction", 0.15, 0.60),
        "ditDahBoundary": trial.suggest_float("ditDahBoundary", 1.5, 2.5),
        "minElementFraction": trial.suggest_float("minElementFraction", 0.15, 0.50),
        # -- Gap classification --
        "interCharGapMultiple": trial.suggest_float("interCharGapMultiple", 1.5, 3.5),
        "wordGapMultiple": trial.suggest_float("wordGapMultiple", 4.0, 8.0),
        # -- Beam search --
        "beamWidth": trial.suggest_int("beamWidth", 4, 32),
        "pruneThreshold": trial.suggest_float("pruneThreshold", 0.001, 0.1, log=True),
        # -- Speed tracking --
        "speedTrackerSize": trial.suggest_int("speedTrackerSize", 4, 32),
        "speedJumpRatio": trial.suggest_float("speedJumpRatio", 1.2, 2.0),
        # -- AFC --
        "afcUpdateInterval": trial.suggest_int("afcUpdateInterval", 10, 60),
        "afcLargeOffsetGain": trial.suggest_float("afcLargeOffsetGain", 0.3, 1.0),
        "afcSmallOffsetGain": trial.suggest_float("afcSmallOffsetGain", 0.2, 0.8),
        "afcMinPowerRatio": trial.suggest_float("afcMinPowerRatio", 1.05, 2.0),
        # -- Debounce --
        "debounceFraction": trial.suggest_float("debounceFraction", 0.2, 0.6),
        # -- Threshold adaptation --
        "thresholdFractionClean": trial.suggest_float("thresholdFractionClean", 0.10, 0.40),
        "thresholdFractionModerate": trial.suggest_float("thresholdFractionModerate", 0.15, 0.50),
        "thresholdFractionNoisy": trial.suggest_float("thresholdFractionNoisy", 0.25, 0.60),
        "signalAttackRate": trial.suggest_float("signalAttackRate", 0.10, 0.60),
        "signalDecayRate": trial.suggest_float("signalDecayRate", 0.05, 0.30),
        "recentSignalDecay": trial.suggest_float("recentSignalDecay", 0.10, 0.50),
        "noiseFloorTrackingRate": trial.suggest_float("noiseFloorTrackingRate", 0.01, 0.15),
    }

    results = run_benchmark(params, release=not getattr(objective, "_debug", False))
    score = results.get("composite_score", 0.0)

    # Extract per-category scores for detailed analysis
    if "tests" in results:
        categories = {}
        for t in results["tests"]:
            cat = t.get("category", "unknown")
            if cat not in categories:
                categories[cat] = []
            categories[cat].append(t.get("score", 0))
        for cat, scores in sorted(categories.items()):
            avg = sum(scores) / len(scores) if scores else 0
            trial.set_user_attr(f"cat_{cat}", round(avg, 1))

    return score


def show_best(storage: str):
    """Display the best parameters from a previous study."""
    import optuna

    try:
        study = optuna.load_study(study_name=STUDY_NAME, storage=storage)
    except Exception as e:
        print(f"Error loading study: {e}")
        print(f"Database: {DB_PATH}")
        sys.exit(1)

    print(f"Study: {STUDY_NAME}")
    print(f"Trials: {len(study.trials)}")
    print(f"Best score: {study.best_value:.1f}")
    print(f"\nBest parameters:")
    print(json.dumps(study.best_params, indent=2))

    # Show category breakdown for best trial
    best = study.best_trial
    cat_attrs = {
        k.replace("cat_", ""): v
        for k, v in best.user_attrs.items()
        if k.startswith("cat_")
    }
    if cat_attrs:
        print(f"\nCategory scores for best trial:")
        for cat, score in sorted(cat_attrs.items()):
            print(f"  {cat}: {score:.1f}")

    # Save best params to a file for easy application
    best_path = os.path.join(SCRIPT_DIR, "cw_bayesian_best_params.json")
    with open(best_path, "w") as f:
        json.dump(study.best_params, f, indent=2)
    print(f"\nBest params saved to: {best_path}")
    print(f"Apply with: swift run CWBenchmark -- --bayesian-only --bayesian-params {best_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Optimize Bayesian CW decoder parameters using Optuna",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 scripts/optimize_cw_bayesian.py                # 100 trials (~3-5 hours)
  python3 scripts/optimize_cw_bayesian.py --trials 20    # quick exploration
  python3 scripts/optimize_cw_bayesian.py --resume        # continue from checkpoint
  python3 scripts/optimize_cw_bayesian.py --best          # show best params
""",
    )
    parser.add_argument(
        "--trials",
        type=int,
        default=100,
        help="Number of optimization trials (default: 100)",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="Resume from previous study instead of creating new one",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Use debug build (slower but better error messages)",
    )
    parser.add_argument(
        "--best",
        action="store_true",
        help="Show best parameters from previous run and exit",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for the TPE sampler (default: 42)",
    )
    args = parser.parse_args()

    try:
        import optuna
    except ImportError:
        print("Optuna is required. Install it with:")
        print("  pip install optuna")
        print("Or in a virtual environment:")
        print("  python3 -m venv .venv && source .venv/bin/activate && pip install optuna")
        sys.exit(1)

    storage = f"sqlite:///{DB_PATH}"

    if args.best:
        show_best(storage)
        return

    # Pass debug flag to objective via function attribute
    objective._debug = args.debug

    if args.resume:
        try:
            study = optuna.load_study(study_name=STUDY_NAME, storage=storage)
            print(f"Resuming study with {len(study.trials)} existing trials")
        except Exception:
            print("No existing study found. Creating new one.")
            study = optuna.create_study(
                direction="maximize",
                sampler=optuna.samplers.TPESampler(seed=args.seed),
                storage=storage,
                study_name=STUDY_NAME,
            )
    else:
        study = optuna.create_study(
            direction="maximize",
            sampler=optuna.samplers.TPESampler(seed=args.seed),
            storage=storage,
            study_name=STUDY_NAME,
            load_if_exists=True,
        )

    # Run baseline with default params
    print("Running baseline (default Bayesian params)...")
    baseline = run_benchmark({}, release=not args.debug)
    baseline_score = baseline.get("composite_score", 0)
    print(f"Baseline score: {baseline_score:.1f}")

    if "tests" in baseline:
        categories = {}
        for t in baseline["tests"]:
            cat = t.get("category", "unknown")
            if cat not in categories:
                categories[cat] = []
            categories[cat].append(t.get("score", 0))
        print("Category breakdown:")
        for cat, scores in sorted(categories.items()):
            avg = sum(scores) / len(scores) if scores else 0
            print(f"  {cat}: {avg:.1f}")

    print(f"\nStarting optimization ({args.trials} trials)...")
    print(f"Each trial takes ~2-3 minutes in release mode.")
    print(f"Estimated total time: {args.trials * 2.5 / 60:.1f} - {args.trials * 3.5 / 60:.1f} hours")
    print(f"Database: {DB_PATH}")
    print(f"Press Ctrl+C to stop early (progress is saved).\n")

    start = time.time()
    try:
        study.optimize(objective, n_trials=args.trials)
    except KeyboardInterrupt:
        print("\n\nOptimization interrupted. Progress saved.")

    elapsed = time.time() - start
    n_complete = len([t for t in study.trials if t.state.name == "COMPLETE"])

    print(f"\n{'=' * 60}")
    print(f"Optimization complete")
    print(f"{'=' * 60}")
    print(f"  Trials completed: {n_complete}")
    print(f"  Time elapsed:     {elapsed / 60:.1f} minutes")
    print(f"  Baseline score:   {baseline_score:.1f}")
    print(f"  Best score:       {study.best_value:.1f}")
    print(f"  Improvement:      {study.best_value - baseline_score:+.1f}")
    print(f"\nBest parameters:")
    print(json.dumps(study.best_params, indent=2))

    # Show category breakdown for best trial
    best = study.best_trial
    cat_attrs = {
        k.replace("cat_", ""): v
        for k, v in best.user_attrs.items()
        if k.startswith("cat_")
    }
    if cat_attrs:
        print(f"\nCategory scores for best trial:")
        for cat, score in sorted(cat_attrs.items()):
            print(f"  {cat}: {score:.1f}")

    # Save best params
    best_path = os.path.join(SCRIPT_DIR, "cw_bayesian_best_params.json")
    with open(best_path, "w") as f:
        json.dump(study.best_params, f, indent=2)
    print(f"\nBest params saved to: {best_path}")
    print(f"Database: {DB_PATH}")
    print(f"\nTo apply best params:")
    print(
        f"  cd AmateurDigital/AmateurDigitalCore && swift run -c release CWBenchmark -- --bayesian-only --bayesian-params {best_path}"
    )
    print(f"\nTo compare with classic decoder:")
    print(
        f"  cd AmateurDigital/AmateurDigitalCore && swift run -c release CWBenchmark -- --compare --bayesian-params {best_path}"
    )


if __name__ == "__main__":
    main()
