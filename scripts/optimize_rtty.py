#!/usr/bin/env python3
"""
RTTY Decoder Parameter Optimization using Optuna.

Uses the RTTYBenchmark's --params flag to explore the parameter space
automatically, finding optimal values for correlationThreshold, stopBitThreshold,
and other configurable parameters.

Usage:
    pip install optuna
    cd Amateur-Digital
    python3 scripts/optimize_rtty.py               # 100 trials, ~2 hours
    python3 scripts/optimize_rtty.py --trials 50    # fewer trials, ~1 hour
    python3 scripts/optimize_rtty.py --resume        # continue from previous run

Results are stored in scripts/rtty_optimization.db (SQLite).
View with: python3 -c "import optuna; s=optuna.load_study('rtty_v1', 'sqlite:///scripts/rtty_optimization.db'); print(s.best_params)"
"""

import argparse
import json
import os
import subprocess
import sys
import time

def run_benchmark(params: dict, release: bool = True) -> dict:
    """Run RTTYBenchmark with given parameters, return results dict."""
    params_path = "/tmp/rtty_optim_params.json"
    with open(params_path, "w") as f:
        json.dump(params, f)

    build_flag = ["-c", "release"] if release else []
    cmd = ["swift", "run"] + build_flag + ["RTTYBenchmark", "--", "--params", params_path]

    try:
        result = subprocess.run(
            cmd,
            cwd=os.path.join(os.path.dirname(__file__), "..", "AmateurDigital", "AmateurDigitalCore"),
            capture_output=True, text=True, timeout=300
        )
    except subprocess.TimeoutExpired:
        return {"composite_score": 0.0, "tests": []}

    results_path = "/tmp/rtty_benchmark_latest.json"
    try:
        with open(results_path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"composite_score": 0.0, "tests": []}


def objective(trial) -> float:
    """Optuna objective: maximize composite score."""
    params = {
        "correlationThreshold": trial.suggest_float("correlationThreshold", 0.05, 0.4),
        "stopBitThreshold": trial.suggest_float("stopBitThreshold", 0.01, 0.15),
    }

    results = run_benchmark(params)
    score = results.get("composite_score", 0.0)

    # Also extract per-category scores for analysis
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


def main():
    parser = argparse.ArgumentParser(description="Optimize RTTY decoder parameters")
    parser.add_argument("--trials", type=int, default=100, help="Number of optimization trials")
    parser.add_argument("--resume", action="store_true", help="Resume from previous study")
    parser.add_argument("--debug", action="store_true", help="Use debug build (slower but better errors)")
    args = parser.parse_args()

    try:
        import optuna
    except ImportError:
        print("Install optuna: pip install optuna")
        sys.exit(1)

    db_path = os.path.join(os.path.dirname(__file__), "rtty_optimization.db")
    storage = f"sqlite:///{db_path}"

    if args.resume:
        study = optuna.load_study(study_name="rtty_v1", storage=storage)
        print(f"Resuming study with {len(study.trials)} existing trials")
    else:
        study = optuna.create_study(
            direction="maximize",
            sampler=optuna.samplers.TPESampler(seed=42),
            storage=storage,
            study_name="rtty_v1",
            load_if_exists=True,
        )

    # First, run with default params to establish baseline
    print("Running baseline (default params)...")
    baseline = run_benchmark({})
    baseline_score = baseline.get("composite_score", 0)
    print(f"Baseline score: {baseline_score:.1f}")

    print(f"\nStarting optimization ({args.trials} trials)...")
    start = time.time()
    study.optimize(objective, n_trials=args.trials)
    elapsed = time.time() - start

    print(f"\n{'='*60}")
    print(f"Optimization complete in {elapsed/60:.1f} minutes")
    print(f"Baseline score:  {baseline_score:.1f}")
    print(f"Best score:      {study.best_value:.1f}")
    print(f"Improvement:     {study.best_value - baseline_score:+.1f}")
    print(f"Best parameters: {json.dumps(study.best_params, indent=2)}")
    print(f"\nTo apply: echo '{json.dumps(study.best_params)}' | python3 -m json.tool")
    print(f"Database: {db_path}")


if __name__ == "__main__":
    main()
