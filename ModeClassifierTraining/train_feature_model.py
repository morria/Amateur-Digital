#!/usr/bin/env python3
"""
Mode Classifier Training — Feature-based model using GradientBoosting

Instead of a CNN on spectrograms, trains a gradient boosted classifier on
the spectral features that the Swift SpectralAnalyzer already extracts.
This approach:
  - Uses features proven to work (97% on training harness)
  - Trains in seconds instead of hours
  - Produces a tiny model (~50KB)
  - Runs on CPU in <1ms

The feature extraction must be identical between Python (training) and
Swift (inference). We generate the features using the Swift trainer
which dumps them as CSV.

Usage:
    # 1. Generate feature CSV:
    #    cd AmateurDigital/AmateurDigitalCore
    #    swift run ModeDetectionTrainer --dump-csv > /tmp/mode_features.csv
    #
    # 2. Generate extended training features:
    #    swift run GenerateModeTrainingData --count 50
    #    swift run ModeDetectionFeatureExtractor > /tmp/mode_training_features.csv
    #
    # 3. Train model:
    #    python3 train_feature_model.py
"""

import os
import sys
import csv
import numpy as np
from pathlib import Path

from sklearn.ensemble import GradientBoostingClassifier
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.preprocessing import LabelEncoder

try:
    import coremltools as ct
    from coremltools.converters import sklearn as sklearn_converter
    HAS_COREML = True
except ImportError:
    HAS_COREML = False

MODE_LABELS = ["rtty", "psk31", "bpsk63", "qpsk31", "qpsk63", "cw", "js8call", "noise"]

FEATURE_NAMES = [
    "bandwidth", "flatness", "num_peaks", "top_peak_power", "top_peak_bw",
    "fsk_pairs", "fsk_valley_pairs", "envelope_cv", "duty_cycle",
    "transition_rate", "has_ook", "baud_rate", "baud_confidence"
]

def load_training_csv(path):
    """Load the CSV dumped by ModeDetectionTrainer --dump-csv."""
    X, y = [], []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            mode = row["mode"].lower()
            if mode not in MODE_LABELS:
                continue
            features = [
                float(row["bw"]),
                float(row["flatness"]),
                int(row["peaks"]),
                float(row["topPeakPower"]),
                float(row["topPeakBW"]),
                int(row["fskPairs"]),
                int(row["fskValley"]),
                float(row["cv"]),
                float(row["duty"]),
                float(row["transitions"]),
                1.0 if row["ook"] == "true" else 0.0,
                float(row.get("baudRate", 0)),
                float(row.get("baudConf", 0)),
            ]
            X.append(features)
            y.append(mode)
    return np.array(X), np.array(y)


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # Look for training features CSV
    csv_path = os.path.join(script_dir, "training_features.csv")
    if not os.path.exists(csv_path):
        csv_path = "/tmp/mode_training_features.csv"
    if not os.path.exists(csv_path):
        print("Error: training_features.csv not found.")
        print("Generate it with:")
        print("  cd AmateurDigital/AmateurDigitalCore")
        print("  swift run ModeDetectionFeatureExtractor > ../../../ModeClassifierTraining/training_features.csv")
        sys.exit(1)

    print("Mode Classifier Training (Feature-based)")
    print("=" * 60)

    X, y = load_training_csv(csv_path)
    print(f"  Loaded {len(X)} samples with {len(FEATURE_NAMES)} features")

    # Class distribution
    for mode in MODE_LABELS:
        count = (y == mode).sum()
        print(f"    {mode:10s} {count:5d}")

    # Encode labels
    le = LabelEncoder()
    le.fit(MODE_LABELS)
    y_encoded = le.transform(y)

    # Split
    X_train, X_test, y_train, y_test = train_test_split(
        X, y_encoded, test_size=0.2, stratify=y_encoded, random_state=42
    )
    print(f"  Train: {len(X_train)}, Test: {len(X_test)}")

    # Train GradientBoosting
    print("\nTraining...")
    clf = GradientBoostingClassifier(
        n_estimators=200,
        max_depth=5,
        learning_rate=0.1,
        min_samples_split=5,
        min_samples_leaf=2,
        subsample=0.8,
        random_state=42,
    )
    clf.fit(X_train, y_train)

    # Evaluate
    y_pred = clf.predict(X_test)
    accuracy = (y_pred == y_test).mean()
    print(f"\nTest accuracy: {accuracy:.1%}")
    print()

    target_names = le.inverse_transform(range(len(MODE_LABELS)))
    print(classification_report(y_test, y_pred, target_names=target_names, zero_division=0))

    # Confusion matrix
    cm = confusion_matrix(y_test, y_pred)
    header = "          " + " ".join(f"{m[:6]:>6s}" for m in target_names)
    print(header)
    for i, row in enumerate(cm):
        print(f"  {target_names[i]:8s} " + " ".join(f"{v:6d}" for v in row))

    # Feature importance
    print("\nFeature importance:")
    importances = sorted(zip(FEATURE_NAMES, clf.feature_importances_), key=lambda x: -x[1])
    for name, imp in importances:
        bar = "#" * int(imp * 100)
        print(f"  {name:20s} {imp:.3f} {bar}")

    # Cross-validation
    print("\nCross-validation (5-fold):")
    scores = cross_val_score(clf, X, y_encoded, cv=5, scoring='accuracy')
    print(f"  {scores.mean():.1%} ± {scores.std():.1%}")

    # Save sklearn model
    import joblib
    model_path = os.path.join(script_dir, "ModeClassifier_features.joblib")
    joblib.dump((clf, le, FEATURE_NAMES), model_path)
    print(f"\nSaved: {model_path}")

    # Export to CoreML
    if HAS_COREML:
        print("\nCoreML Export...")
        try:
            mlmodel = ct.converters.sklearn.convert(
                clf,
                input_features=FEATURE_NAMES,
                output_feature_names="mode",
            )
            mlmodel.author = "Amateur Digital"
            mlmodel.short_description = "Classifies digital mode signals from spectral features"

            mlmodel_path = os.path.join(script_dir, "ModeClassifier.mlmodel")
            mlmodel.save(mlmodel_path)
            print(f"  Saved: {mlmodel_path}")

            # Compile
            import subprocess
            result = subprocess.run(
                ["xcrun", "coremlcompiler", "compile", mlmodel_path, script_dir],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                print("  Compiled to .mlmodelc")

                # Copy to Swift package
                import shutil
                dst = os.path.join(script_dir, "..", "AmateurDigital", "ModeClassifierModel",
                                   "Sources", "ModeClassifierModel", "Resources", "ModeClassifier.mlmodelc")
                if os.path.exists(dst):
                    shutil.rmtree(dst)
                src = os.path.join(script_dir, "ModeClassifier.mlmodelc")
                if os.path.exists(src):
                    shutil.copytree(src, dst)
                    print(f"  Copied to Swift package")
            else:
                print(f"  Compile failed: {result.stderr[:200]}")
        except Exception as e:
            print(f"  CoreML export error: {e}")

    print("\nDone.")


if __name__ == "__main__":
    main()
