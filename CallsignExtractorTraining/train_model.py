#!/usr/bin/env python3
"""Train a callsign extraction model and export to CoreML.

The model is a binary classifier that scores candidate callsigns found in text.
For each candidate, contextual features are extracted and the model predicts
whether it is the TARGET station (the one the user wants to work).

Pipeline:
  1. Load training data (text, target_callsign) pairs.
  2. Extract all candidate callsigns from each text via regex.
  3. For each candidate, compute contextual features.
  4. Train a Gradient Boosting classifier on (features -> is_target).
  5. Export to CoreML (.mlmodel) and compile to .mlmodelc in the package.
"""

import csv
import os
import re
import shutil
import subprocess
import sys

import numpy as np
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report, accuracy_score

import coremltools as ct

# ---------------------------------------------------------------------------
# Callsign regex — matches standard amateur radio callsigns
# ---------------------------------------------------------------------------

# Pattern: 1-2 letters, 1 digit, 1-4 letters (covers virtually all callsigns)
CALLSIGN_RE = re.compile(r'\b([A-Z]{1,2}\d[A-Z]{1,4})\b')

# Extended pattern that also catches 2-letter + digit + letters and special formats
CALLSIGN_RE_EXTENDED = re.compile(
    r'\b([A-Z]{1,2}\d{1,2}[A-Z]{1,4})\b'
)

# QSO keywords for context features
CQ_WORDS = {"CQ"}
DE_WORDS = {"DE"}
END_WORDS = {"K", "KN", "SK", "AR", "BK", "BTU"}
EXCHANGE_WORDS = {"RST", "599", "579", "559", "589", "569", "549", "NAME", "QTH", "UR"}
ACTIVITY_WORDS = {"POTA", "SOTA", "WWFF", "IOTA", "TEST", "CONTEST", "DX"}
GREETING_WORDS = {"GE", "GM", "GA", "GN", "TNX", "TU", "73", "HPE", "CU", "AGN", "HW", "CPY"}


def extract_candidates(text: str) -> list[tuple[str, int]]:
    """Extract candidate callsigns and their character positions from text."""
    candidates = []
    seen = set()
    for m in CALLSIGN_RE_EXTENDED.finditer(text):
        call = m.group(1)
        # Filter out things that look like callsigns but aren't
        # Must have at least 1 letter before digit and 1 after
        if not re.match(r'^[A-Z]{1,2}\d', call):
            continue
        if not re.search(r'\d[A-Z]+$', call):
            continue
        # Skip very short matches that are likely noise
        if len(call) < 3:
            continue
        key = (call, m.start())
        if key not in seen:
            seen.add(key)
            candidates.append((call, m.start()))
    return candidates


def tokenize(text: str) -> list[str]:
    """Split text into tokens."""
    return text.upper().split()


def compute_features(text: str, candidate: str, char_pos: int) -> list[float]:
    """Compute contextual features for a candidate callsign in text.

    Returns a feature vector of length 16.
    """
    tokens = tokenize(text)
    text_upper = text.upper()
    text_len = max(len(text_upper), 1)

    # Find which token index the candidate is at
    candidate_token_idx = -1
    running_pos = 0
    for i, tok in enumerate(tokens):
        tok_start = text_upper.find(tok, running_pos)
        if tok_start <= char_pos <= tok_start + len(tok):
            candidate_token_idx = i
            break
        running_pos = tok_start + len(tok)

    n_tokens = len(tokens)

    def get_token(idx: int) -> str:
        if 0 <= idx < n_tokens:
            return tokens[idx]
        return ""

    prev1 = get_token(candidate_token_idx - 1)
    prev2 = get_token(candidate_token_idx - 2)
    next1 = get_token(candidate_token_idx + 1)
    next2 = get_token(candidate_token_idx + 2)

    # Count callsigns in text
    all_candidates = extract_candidates(text_upper)
    n_callsigns = len(set(c for c, _ in all_candidates))

    # Count occurrences of this candidate
    candidate_count = sum(1 for c, _ in all_candidates if c == candidate)

    # Is this the first callsign?
    is_first = 1.0 if all_candidates and all_candidates[0][0] == candidate else 0.0

    # Is this the last callsign?
    is_last = 1.0 if all_candidates and all_candidates[-1][0] == candidate else 0.0

    features = [
        # F0: preceded by DE
        1.0 if prev1 in DE_WORDS else 0.0,
        # F1: preceded by CQ (directly or via chain)
        1.0 if prev1 in CQ_WORDS or prev2 in CQ_WORDS else 0.0,
        # F2: followed by DE
        1.0 if next1 in DE_WORDS else 0.0,
        # F3: followed by K/KN/end marker
        1.0 if next1 in END_WORDS else 0.0,
        # F4: CQ anywhere in text
        1.0 if "CQ" in tokens else 0.0,
        # F5: is first callsign in text
        is_first,
        # F6: is last callsign in text
        is_last,
        # F7: normalized position in text (0.0 = start, 1.0 = end)
        char_pos / text_len,
        # F8: number of unique callsigns in text
        float(min(n_callsigns, 6)),
        # F9: candidate appears more than once
        1.0 if candidate_count > 1 else 0.0,
        # F10: activity word nearby (POTA, SOTA, TEST, DX, etc.)
        1.0 if any(w in ACTIVITY_WORDS for w in tokens) else 0.0,
        # F11: exchange words nearby (RST, NAME, QTH) — indicates this is mid-QSO
        1.0 if any(w in EXCHANGE_WORDS for w in tokens) else 0.0,
        # F12: preceded by another callsign (i.e. "THEIRCALL DE MYCALL" pattern)
        1.0 if prev1 in DE_WORDS and candidate_token_idx >= 2 and
             CALLSIGN_RE.match(get_token(candidate_token_idx - 2)) else 0.0,
        # F13: followed by another callsign (i.e., this call is being called)
        1.0 if next1 and CALLSIGN_RE.match(next1) and next1 != candidate else 0.0,
        # F14: text looks like a CQ call (starts with CQ)
        1.0 if tokens and tokens[0] == "CQ" else 0.0,
        # F15: 73/SK in text (tail end of QSO)
        1.0 if "73" in tokens or "SK" in tokens else 0.0,
    ]

    return features


NUM_FEATURES = 16


def build_dataset(data_path: str):
    """Build feature matrix and labels from training CSV."""
    texts = []
    targets = []

    with open(data_path, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            texts.append(row["text"])
            targets.append(row["target_callsign"])

    X_list = []
    y_list = []
    skipped = 0

    for text, target in zip(texts, targets):
        candidates = extract_candidates(text.upper())
        if not candidates:
            skipped += 1
            continue

        target_upper = target.upper()
        has_target = any(c == target_upper for c, _ in candidates)

        for cand, pos in candidates:
            features = compute_features(text.upper(), cand, pos)
            is_target = 1 if cand == target_upper else 0
            X_list.append(features)
            y_list.append(is_target)

    X = np.array(X_list, dtype=np.float32)
    y = np.array(y_list, dtype=np.int32)

    print(f"Dataset: {len(X)} candidate samples from {len(texts)} texts ({skipped} skipped)")
    print(f"  Positive (target): {y.sum()}")
    print(f"  Negative (other):  {(1 - y).sum()}")
    return X, y


def train_and_export(X, y, output_dir: str):
    """Train gradient boosting classifier and export to CoreML."""

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.15, random_state=42, stratify=y
    )

    print(f"\nTraining set: {len(X_train)} samples")
    print(f"Test set:     {len(X_test)} samples")

    # Train
    clf = GradientBoostingClassifier(
        n_estimators=150,
        max_depth=5,
        learning_rate=0.1,
        subsample=0.8,
        random_state=42,
    )
    print("\nTraining model...")
    clf.fit(X_train, y_train)

    # Evaluate
    y_pred = clf.predict(X_test)
    print(f"\nTest accuracy: {accuracy_score(y_test, y_pred):.4f}")
    print("\nClassification report:")
    print(classification_report(y_test, y_pred, target_names=["other", "target"]))

    # Feature importances
    feature_names = [
        "preceded_by_DE", "preceded_by_CQ", "followed_by_DE", "followed_by_K",
        "CQ_in_text", "is_first_call", "is_last_call", "position_norm",
        "n_unique_calls", "appears_multiple", "activity_word", "exchange_word",
        "preceded_by_call_DE", "followed_by_call", "text_starts_CQ", "has_73_SK",
    ]
    importances = clf.feature_importances_
    print("\nFeature importances:")
    for name, imp in sorted(zip(feature_names, importances), key=lambda x: -x[1]):
        print(f"  {name:25s} {imp:.4f}")

    # Convert to CoreML
    print("\nConverting to CoreML...")
    coreml_model = ct.converters.sklearn.convert(
        clf,
        input_features=feature_names,
        output_feature_names="is_target",
    )

    # Set model metadata
    coreml_model.author = "CallsignExtractor Training Pipeline"
    coreml_model.short_description = (
        "Classifies candidate callsigns as target (station to work) or not, "
        "based on contextual features from decoded amateur radio digital mode text."
    )
    coreml_model.input_description["preceded_by_DE"] = "1.0 if token before candidate is DE"
    coreml_model.input_description["preceded_by_CQ"] = "1.0 if CQ precedes candidate"
    coreml_model.input_description["followed_by_DE"] = "1.0 if DE follows candidate"
    coreml_model.input_description["followed_by_K"] = "1.0 if end marker (K/KN/SK) follows"
    coreml_model.input_description["CQ_in_text"] = "1.0 if CQ appears anywhere in text"
    coreml_model.input_description["is_first_call"] = "1.0 if this is the first callsign"
    coreml_model.input_description["is_last_call"] = "1.0 if this is the last callsign"
    coreml_model.input_description["position_norm"] = "Normalized position in text (0-1)"
    coreml_model.input_description["n_unique_calls"] = "Count of unique callsigns in text"
    coreml_model.input_description["appears_multiple"] = "1.0 if candidate appears more than once"
    coreml_model.input_description["activity_word"] = "1.0 if POTA/SOTA/TEST/DX nearby"
    coreml_model.input_description["exchange_word"] = "1.0 if RST/NAME/QTH nearby"
    coreml_model.input_description["preceded_by_call_DE"] = "1.0 if pattern is CALL DE <this>"
    coreml_model.input_description["followed_by_call"] = "1.0 if another callsign follows"
    coreml_model.input_description["text_starts_CQ"] = "1.0 if text starts with CQ"
    coreml_model.input_description["has_73_SK"] = "1.0 if 73 or SK in text"

    # Save .mlmodel in this training directory
    mlmodel_path = os.path.join(output_dir, "CallsignModel.mlmodel")
    coreml_model.save(mlmodel_path)
    print(f"\nModel saved to {mlmodel_path}")

    # Compile to .mlmodelc and deploy to the Swift package
    package_dir = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", "AmateurDigital", "CallsignExtractor",
    )
    resources_dir = os.path.join(
        package_dir, "Sources", "CallsignExtractor", "Resources",
    )
    os.makedirs(resources_dir, exist_ok=True)

    compiled_path = os.path.join(resources_dir, "CallsignModel.mlmodelc")
    if os.path.exists(compiled_path):
        print(f"Removing old compiled model at {compiled_path}")
        shutil.rmtree(compiled_path)

    print("Compiling model with xcrun coremlcompiler...")
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", mlmodel_path, resources_dir],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"Warning: coremlcompiler failed: {result.stderr}")
        print("The .mlmodel was saved but could not be compiled to .mlmodelc")
    else:
        print(f"Compiled model to {compiled_path}")

    return clf


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_path = os.path.join(script_dir, "data", "training_data.csv")

    if not os.path.exists(data_path):
        print(f"Training data not found at {data_path}")
        print("Run generate_training_data.py first.")
        sys.exit(1)

    # Build dataset
    X, y = build_dataset(data_path)

    # Train and export (save .mlmodel in this directory)
    clf = train_and_export(X, y, script_dir)

    # Quick sanity check
    print("\n--- Sanity Check ---")
    test_texts = [
        "CQ CQ CQ DE W1AW W1AW K",
        "CQ POTA CQ POTA DE K4SWL K4SWL K",
        "W1AW W1AW DE VK3ABC VK3ABC K",
        "VK3ABC DE W1AW UR RST 599 599 NAME JOHN QTH CT BK",
        "CQ TEST N5KO N5KO",
        "73 W1AW DE VK3ABC SK  CQ CQ DE JA1XYZ JA1XYZ K",
    ]
    expected = ["W1AW", "K4SWL", "W1AW", "W1AW", "N5KO", "JA1XYZ"]

    correct = 0
    for text, exp in zip(test_texts, expected):
        candidates = extract_candidates(text.upper())
        if not candidates:
            print(f"  FAIL (no candidates): {text}")
            continue

        best_call = None
        best_score = -1.0
        for cand, pos in candidates:
            feats = compute_features(text.upper(), cand, pos)
            prob = clf.predict_proba(np.array([feats]))[0][1]
            if prob > best_score:
                best_score = prob
                best_call = cand

        status = "OK" if best_call == exp else "FAIL"
        if best_call == exp:
            correct += 1
        print(f"  {status}: '{text}' -> {best_call} (expected {exp}, conf={best_score:.3f})")

    print(f"\nSanity check: {correct}/{len(test_texts)} correct")


if __name__ == "__main__":
    main()
