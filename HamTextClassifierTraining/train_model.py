#!/usr/bin/env python3
"""Train HamTextClassifier and export to CoreML."""

import json
import math
import os
import re
import string
import subprocess
import sys

import coremltools
import numpy as np
import pandas as pd
from sklearn.feature_extraction import DictVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, classification_report
from sklearn.pipeline import Pipeline

# --- Feature extraction (must match Swift implementation exactly) ---

CALLSIGN_RE = re.compile(r"[A-Z]{1,2}[0-9][A-Z]{1,3}")
RST_RE = re.compile(r"\b[1-5][1-9][1-9]?\b")
GRID_RE = re.compile(r"\b[A-R]{2}[0-9]{2}(?:[a-x]{2})?\b", re.IGNORECASE)
CQ_RE = re.compile(r"\bCQ\b", re.IGNORECASE)
DE_RE = re.compile(r"\bDE\b", re.IGNORECASE)
SEVENTY_THREE_RE = re.compile(r"\b73\b")
DB_REPORT_RE = re.compile(r"[+-]\d{2}\b")
RRR_RE = re.compile(r"\bR(?:RR|R73)\b")


def shannon_entropy(text):
    """Calculate Shannon entropy of text."""
    if not text:
        return 0.0
    freq = {}
    for ch in text:
        freq[ch] = freq.get(ch, 0) + 1
    length = len(text)
    entropy = 0.0
    for count in freq.values():
        p = count / length
        if p > 0:
            entropy -= p * math.log2(p)
    return entropy


def extract_features(text):
    """Extract character-level features from text. Returns Dict[str, float]."""
    features = {}

    length = len(text)
    if length == 0:
        features["len"] = 0.0
        features["alpha_ratio"] = 0.0
        features["digit_ratio"] = 0.0
        features["space_ratio"] = 0.0
        features["upper_ratio"] = 0.0
        features["special_ratio"] = 0.0
        features["entropy"] = 0.0
        return features

    alpha_count = sum(1 for c in text if c.isalpha())
    digit_count = sum(1 for c in text if c.isdigit())
    space_count = sum(1 for c in text if c == " ")
    upper_count = sum(1 for c in text if c.isupper())
    special_count = length - alpha_count - digit_count - space_count

    # Statistical features
    features["len"] = min(length / 200.0, 1.0)
    features["alpha_ratio"] = alpha_count / length
    features["digit_ratio"] = digit_count / length
    features["space_ratio"] = space_count / length
    features["upper_ratio"] = upper_count / length if alpha_count > 0 else 0.0
    features["special_ratio"] = special_count / length
    features["entropy"] = shannon_entropy(text) / 8.0  # Normalize to ~[0,1]

    # Character bigrams on uppercased text
    upper_text = text.upper()
    for i in range(len(upper_text) - 1):
        bigram = upper_text[i : i + 2]
        # Only count bigrams with alphanumeric or space chars
        if all(c.isalnum() or c == " " for c in bigram):
            key = f"bi_{bigram}"
            features[key] = features.get(key, 0.0) + 1.0

    # Character trigrams on uppercased text
    for i in range(len(upper_text) - 2):
        trigram = upper_text[i : i + 3]
        if all(c.isalnum() or c == " " for c in trigram):
            key = f"tri_{trigram}"
            features[key] = features.get(key, 0.0) + 1.0

    # Pattern matches
    features["has_callsign"] = 1.0 if CALLSIGN_RE.search(upper_text) else 0.0
    features["has_rst"] = 1.0 if RST_RE.search(text) else 0.0
    features["has_grid"] = 1.0 if GRID_RE.search(text) else 0.0
    features["has_cq"] = 1.0 if CQ_RE.search(text) else 0.0
    features["has_de"] = 1.0 if DE_RE.search(text) else 0.0
    features["has_73"] = 1.0 if SEVENTY_THREE_RE.search(text) else 0.0
    features["has_db_report"] = 1.0 if DB_REPORT_RE.search(text) else 0.0
    features["has_rrr"] = 1.0 if RRR_RE.search(text) else 0.0

    return features


def train():
    # Load data
    print("Loading training data...")
    train_df = pd.read_csv("data/train.csv")
    test_df = pd.read_csv("data/test.csv")

    print(f"Train: {len(train_df)} samples, Test: {len(test_df)} samples")

    # Extract features
    print("Extracting features...")
    X_train_dicts = [extract_features(str(t)) for t in train_df["text"]]
    X_test_dicts = [extract_features(str(t)) for t in test_df["text"]]
    y_train = train_df["label"].values
    y_test = test_df["label"].values

    # Build pipeline
    print("Training model...")
    vectorizer = DictVectorizer(sparse=False)
    X_train = vectorizer.fit_transform(X_train_dicts)
    X_test = vectorizer.transform(X_test_dicts)

    model = LogisticRegression(C=1.0, max_iter=1000, solver="lbfgs", multi_class="ovr")
    model.fit(X_train, y_train)

    # Evaluate
    y_pred = model.predict(X_test)
    accuracy = accuracy_score(y_test, y_pred)
    print(f"\nTest Accuracy: {accuracy:.4f}")
    print("\nClassification Report:")
    print(classification_report(y_test, y_pred, target_names=["garbage", "legitimate"]))

    if accuracy < 0.95:
        print(f"WARNING: Accuracy {accuracy:.4f} is below 95% target!")

    # Create sklearn pipeline for coremltools
    pipeline = Pipeline([
        ("vectorizer", vectorizer),
        ("classifier", model),
    ])

    # Export to CoreML
    print("Exporting to CoreML...")
    coreml_model = coremltools.converters.sklearn.convert(
        pipeline,
        input_features="input",
        output_feature_names="label",
    )
    coreml_model.short_description = "Ham radio text legitimacy classifier"
    coreml_model.input_description["input"] = "Feature dictionary from text analysis"

    mlmodel_path = "HamTextClassifier.mlmodel"
    coreml_model.save(mlmodel_path)
    print(f"Saved {mlmodel_path}")

    model_size = os.path.getsize(mlmodel_path)
    print(f"Model size: {model_size / 1024:.1f} KB")

    # Compile with xcrun
    print("Compiling CoreML model...")
    package_dir = os.path.join(os.path.dirname(__file__), "..", "AmateurDigital", "HamTextClassifier")
    resources_dir = os.path.join(package_dir, "Sources", "HamTextClassifier", "Resources")
    os.makedirs(resources_dir, exist_ok=True)

    # Remove old compiled model if it exists
    compiled_path = os.path.join(resources_dir, "HamTextClassifier.mlmodelc")
    if os.path.exists(compiled_path):
        import shutil
        shutil.rmtree(compiled_path)

    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", mlmodel_path, resources_dir],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"coremlcompiler failed: {result.stderr}")
        sys.exit(1)
    print(f"Compiled model to {compiled_path}")

    # Generate golden test pairs
    print("Generating golden test pairs...")
    golden_pairs = []

    legit_samples = [
        "CQ CQ CQ DE W1AW K",
        "CQ CQ CQ DE W1AW W1AW K",
        "W1AW DE K3LR UR RST 599 599 NAME IS BOB QTH IS PITTSBURGH K",
        "CQ W1AW FN31",
        "W1AW K3LR -15",
        "W1AW K3LR RR73",
        "W1AW K3LR 73",
        "CQ DX VK2ABC QF56",
        "Hello Bob, thanks for the call. Your RST is 599. de W1AW",
        "W1AW position 40.7128 -74.0060",
        "Net check-in de W1AW all ok",
        "VVV VVV VVV DE W1AW W1AW BEACON FN31 QSL VIA BUREAU",
        "My rig is a IC-7300 running 100w into a dipole on 20M.",
        "CQ TEST W1AW FN31",
        "TU W1AW DE K3LR QRZ?",
        "CQ POTA W1AW FN31",
        "EMERGENCY de W1AW: Need assistance at grid FN31pr",
        "K3LR DE W1AW 5NN 0001 0001",
        "Weather in Boston is clear, temperature 72F. Nice day for radio!",
        "Been a ham for 25 years now. Running IC-7300 into a 3 el yagi.",
    ]

    garbage_samples = [
        "xkjr89#$@mz!pq",
        "aaaaaaaaaaaaaaaaaaa",
        "QQQQQQQQQQQQQ",
        "123456789012345",
        "!@#$%^&*()_+-=[]{}|",
        "asjkdf lqwer poiuyt",
        "zxcvbnm asdfghjkl qwertyuiop",
        ".........",
        "###!!!***&&&",
        "q w e r t y u i o p",
        "8f#kL!mN@pQ3",
        "jjjjjjjjjjjjjjjjjjjj",
        "XYZXYZXYZXYZXYZ",
        ")(*&^%$#@!~`",
        "1a2b3c4d5e6f7g8h",
        "   ...   ...   ",
        "zzzzzzzzzzzzzzzzzzzz",
        "ab12cd34ef56gh78ij",
        "!a@b#c$d%e^f&g*h",
        "mnbvcxzlkjhgfdsa",
    ]

    for text in legit_samples:
        feats = extract_features(text)
        fv = vectorizer.transform([feats])
        pred = model.predict(fv)[0]
        prob = model.predict_proba(fv)[0]
        golden_pairs.append({
            "text": text,
            "expected_label": 1,
            "predicted_label": int(pred),
            "confidence": float(max(prob)),
        })

    for text in garbage_samples:
        feats = extract_features(text)
        fv = vectorizer.transform([feats])
        pred = model.predict(fv)[0]
        prob = model.predict_proba(fv)[0]
        golden_pairs.append({
            "text": text,
            "expected_label": 0,
            "predicted_label": int(pred),
            "confidence": float(max(prob)),
        })

    golden_dir = os.path.join(package_dir, "Tests", "HamTextClassifierTests", "Resources")
    os.makedirs(golden_dir, exist_ok=True)
    golden_path = os.path.join(golden_dir, "golden_test_pairs.json")
    with open(golden_path, "w") as f:
        json.dump(golden_pairs, f, indent=2)
    print(f"Saved {len(golden_pairs)} golden test pairs to {golden_path}")

    # Print some golden pair stats
    correct = sum(1 for p in golden_pairs if p["expected_label"] == p["predicted_label"])
    print(f"Golden pairs accuracy: {correct}/{len(golden_pairs)} ({100*correct/len(golden_pairs):.1f}%)")

    return accuracy


if __name__ == "__main__":
    acc = train()
    sys.exit(0 if acc >= 0.95 else 1)
