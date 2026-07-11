#!/usr/bin/env python3
"""
Mode Classifier Training — CNN on Panoradio HF IQ Dataset

Trains a lightweight CNN to classify amateur radio digital mode signals
from the Panoradio HF dataset (172,800 complex IQ vectors, 18 modes, 8 SNR levels).

Dataset: Panoradio HF Radio Signals (Scholl et al.)
  - 6 kHz sample rate, complex128 IQ, 2048 samples per clip (341ms)
  - 18 modes at SNR -10 to +25 dB

Our mode mapping:
  morse      -> CW
  psk31      -> PSK31
  psk63      -> BPSK63
  qpsk31     -> QPSK31
  rtty45_170 -> RTTY
  rtty50_170 -> RTTY
  everything else -> other

Usage:
    python3 train_panoradio_cnn.py                     # Train + save .pt
    python3 train_panoradio_cnn.py --export-only       # Export existing .pt to CoreML
    python3 train_panoradio_cnn.py --epochs 50         # More epochs

Requires: torch, numpy, scikit-learn
Export:   coremltools (use /tmp/coreml_venv for export step)
"""

import os
import sys
import argparse
import time
import json
import numpy as np

import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader

from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report, confusion_matrix

# ============================================================================
# Configuration
# ============================================================================

PANORADIO_DIR = "/Users/asm/d/Amateur-Digital/panoradio"
DATASET_NPY = os.path.join(PANORADIO_DIR, "dataset_hf_radio.npy")
DATASET_CSV = os.path.join(PANORADIO_DIR, "dataset_panoradio_hf_tags.csv")

SAMPLE_RATE = 6000       # 6 kHz IQ
NUM_IQ_SAMPLES = 2048    # samples per clip

# Mode mapping: panoradio label -> our label
MODE_MAP = {
    "morse":      "cw",
    "psk31":      "psk31",
    "psk63":      "bpsk63",
    "qpsk31":     "qpsk31",
    "rtty45_170": "rtty",
    "rtty50_170": "rtty",
}

# Class labels for the model
CLASS_LABELS = ["cw", "psk31", "bpsk63", "qpsk31", "rtty", "other"]
NUM_CLASSES = len(CLASS_LABELS)

# Training parameters
BATCH_SIZE = 64
LEARNING_RATE = 1e-3
NUM_EPOCHS = 30
WEIGHT_DECAY = 1e-4

# ============================================================================
# Dataset
# ============================================================================

class PanoradioDataset(Dataset):
    """
    Loads Panoradio IQ data as 2-channel (real, imag) tensors.

    Input shape per sample: (2, 2048) — real and imaginary channels.
    """

    def __init__(self, indices, labels, mmap_data, augment=False):
        self.indices = indices
        self.labels = labels
        self.mmap_data = mmap_data
        self.augment = augment

    def __len__(self):
        return len(self.indices)

    def __getitem__(self, idx):
        data_idx = self.indices[idx]
        iq = self.mmap_data[data_idx]  # complex128, shape (2048,)

        # Convert to float32 real + imag channels
        real = iq.real.astype(np.float32)
        imag = iq.imag.astype(np.float32)

        if self.augment:
            # Random phase rotation (equivalent to frequency offset for narrow signals)
            phase = np.random.uniform(0, 2 * np.pi)
            cos_p, sin_p = np.cos(phase).astype(np.float32), np.sin(phase).astype(np.float32)
            real_new = real * cos_p - imag * sin_p
            imag_new = real * sin_p + imag * cos_p
            real, imag = real_new, imag_new

            # Random frequency offset ±50 Hz
            freq_offset = np.random.uniform(-50, 50)
            t = np.arange(NUM_IQ_SAMPLES, dtype=np.float32) / SAMPLE_RATE
            shift_real = np.cos(2 * np.pi * freq_offset * t).astype(np.float32)
            shift_imag = np.sin(2 * np.pi * freq_offset * t).astype(np.float32)
            real_new = real * shift_real - imag * shift_imag
            imag_new = real * shift_imag + imag * shift_real
            real, imag = real_new, imag_new

            # Random gain ±6 dB
            gain_db = np.random.uniform(-6, 6)
            gain = 10 ** (gain_db / 20)
            real *= gain
            imag *= gain

            # 30% chance: add Gaussian noise
            if np.random.random() < 0.3:
                rms = np.sqrt(np.mean(real**2 + imag**2))
                if rms > 1e-10:
                    snr_add = np.random.uniform(5, 20)
                    noise_rms = rms / (10 ** (snr_add / 20))
                    real += np.random.randn(NUM_IQ_SAMPLES).astype(np.float32) * noise_rms
                    imag += np.random.randn(NUM_IQ_SAMPLES).astype(np.float32) * noise_rms

        # Normalize per-sample to zero mean, unit variance (each channel independently)
        for ch in [real, imag]:
            m = ch.mean()
            s = ch.std()
            if s > 1e-10:
                ch -= m
                ch /= s
            else:
                ch -= m

        # Stack to (2, 2048)
        x = np.stack([real, imag], axis=0)
        return torch.from_numpy(x), self.labels[idx]


# ============================================================================
# Model — 1D CNN on raw IQ
# ============================================================================

class PanoradioCNN(nn.Module):
    """
    Lightweight 1D CNN for IQ-based mode classification.

    Input:  (batch, 2, 2048) — real + imaginary IQ channels
    Output: (batch, num_classes) logits

    Architecture: 4 conv blocks with increasing channels, global avg pool, FC head.
    ~180K parameters — fast inference on iPhone Neural Engine.
    """

    def __init__(self, num_classes=NUM_CLASSES):
        super().__init__()

        self.features = nn.Sequential(
            # Block 1: (2, 2048) -> (32, 512)
            nn.Conv1d(2, 32, kernel_size=7, padding=3),
            nn.BatchNorm1d(32),
            nn.ReLU(inplace=True),
            nn.MaxPool1d(4),

            # Block 2: (32, 512) -> (64, 128)
            nn.Conv1d(32, 64, kernel_size=5, padding=2),
            nn.BatchNorm1d(64),
            nn.ReLU(inplace=True),
            nn.MaxPool1d(4),

            # Block 3: (64, 128) -> (128, 32)
            nn.Conv1d(64, 128, kernel_size=3, padding=1),
            nn.BatchNorm1d(128),
            nn.ReLU(inplace=True),
            nn.MaxPool1d(4),

            # Block 4: (128, 32) -> (128, 8)
            nn.Conv1d(128, 128, kernel_size=3, padding=1),
            nn.BatchNorm1d(128),
            nn.ReLU(inplace=True),
            nn.MaxPool1d(4),
        )

        self.classifier = nn.Sequential(
            nn.AdaptiveAvgPool1d(1),     # (128, 1)
            nn.Flatten(),                 # (128,)
            nn.Dropout(0.3),
            nn.Linear(128, 64),
            nn.ReLU(inplace=True),
            nn.Dropout(0.2),
            nn.Linear(64, num_classes),
        )

    def forward(self, x):
        x = self.features(x)
        x = self.classifier(x)
        return x


# ============================================================================
# Training utilities
# ============================================================================

def train_epoch(model, loader, criterion, optimizer, device):
    model.train()
    total_loss = 0
    correct = 0
    total = 0

    for batch_x, batch_y in loader:
        batch_x, batch_y = batch_x.to(device), batch_y.to(device)
        optimizer.zero_grad()
        outputs = model(batch_x)
        loss = criterion(outputs, batch_y)
        loss.backward()
        optimizer.step()

        total_loss += loss.item() * batch_x.size(0)
        _, predicted = outputs.max(1)
        total += batch_y.size(0)
        correct += predicted.eq(batch_y).sum().item()

    return total_loss / total, correct / total


def evaluate(model, loader, device):
    model.eval()
    correct = 0
    total = 0
    all_preds = []
    all_labels = []

    with torch.no_grad():
        for batch_x, batch_y in loader:
            batch_x, batch_y = batch_x.to(device), batch_y.to(device)
            outputs = model(batch_x)
            _, predicted = outputs.max(1)
            total += batch_y.size(0)
            correct += predicted.eq(batch_y).sum().item()
            all_preds.extend(predicted.cpu().numpy())
            all_labels.extend(batch_y.cpu().numpy())

    return correct / total, np.array(all_preds), np.array(all_labels)


# ============================================================================
# Data loading
# ============================================================================

def load_panoradio_data():
    """Load and prepare the Panoradio dataset."""
    import csv

    print(f"  Loading labels from {DATASET_CSV}...")
    indices = []
    labels = []

    with open(DATASET_CSV) as f:
        reader = csv.DictReader(f)
        for row in reader:
            idx = int(row['idx'])
            mode = row[' mode'].strip()  # Note: space-prefixed header
            snr = int(row[' snr'].strip())

            # Map to our labels
            our_mode = MODE_MAP.get(mode, "other")
            label_idx = CLASS_LABELS.index(our_mode)

            indices.append(idx)
            labels.append(label_idx)

    indices = np.array(indices)
    labels = np.array(labels)

    print(f"  Total samples: {len(indices)}")
    print(f"  Class distribution:")
    for i, name in enumerate(CLASS_LABELS):
        count = (labels == i).sum()
        print(f"    {name:10s} {count:6d}")

    # Memory-map the .npy file (5.3 GB)
    print(f"\n  Memory-mapping {DATASET_NPY}...")
    mmap_data = np.load(DATASET_NPY, mmap_mode='r')
    print(f"  Shape: {mmap_data.shape}, dtype: {mmap_data.dtype}")

    return indices, labels, mmap_data


# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Train CNN on Panoradio HF dataset")
    parser.add_argument("--epochs", type=int, default=NUM_EPOCHS)
    parser.add_argument("--batch", type=int, default=BATCH_SIZE)
    parser.add_argument("--lr", type=float, default=LEARNING_RATE)
    parser.add_argument("--export-only", action="store_true",
                        help="Skip training, just export existing .pt to CoreML")
    parser.add_argument("--no-other", action="store_true",
                        help="Exclude 'other' class, only train on our supported modes")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    pt_path = os.path.join(script_dir, "PanoradioCNN.pt")
    meta_path = os.path.join(script_dir, "PanoradioCNN_meta.json")

    if args.export_only:
        print("Export-only mode: loading existing model...")
        if not os.path.exists(pt_path):
            print(f"Error: {pt_path} not found. Train first.")
            sys.exit(1)
        export_coreml_separate(pt_path, meta_path, script_dir)
        return

    print("Panoradio CNN Mode Classifier Training")
    print("=" * 60)

    # Load data
    indices, labels, mmap_data = load_panoradio_data()

    # Optionally exclude 'other' class
    if args.no_other:
        other_idx = CLASS_LABELS.index("other")
        mask = labels != other_idx
        indices = indices[mask]
        labels = labels[mask]
        # Remap labels to be contiguous
        active_labels = sorted(set(labels))
        label_map = {old: new for new, old in enumerate(active_labels)}
        labels = np.array([label_map[l] for l in labels])
        active_class_names = [CLASS_LABELS[i] for i in active_labels]
        num_classes = len(active_class_names)
        print(f"\n  Excluding 'other': {len(indices)} samples, {num_classes} classes")
        print(f"  Classes: {active_class_names}")
    else:
        active_class_names = CLASS_LABELS
        num_classes = NUM_CLASSES

    # Stratified split: 70% train, 15% val, 15% test
    idx_trainval, idx_test, y_trainval, y_test = train_test_split(
        np.arange(len(indices)), labels,
        test_size=0.15, stratify=labels, random_state=42
    )
    idx_train, idx_val, y_train, y_val = train_test_split(
        idx_trainval, y_trainval,
        test_size=0.15/0.85, stratify=y_trainval, random_state=42
    )

    train_indices = indices[idx_train]
    val_indices = indices[idx_val]
    test_indices = indices[idx_test]
    train_labels = labels[idx_train]
    val_labels = labels[idx_val]
    test_labels = labels[idx_test]

    print(f"\n  Split: train={len(train_indices)}, val={len(val_indices)}, test={len(test_indices)}")

    # Compute class weights for imbalanced data (our modes ~9600 each, other ~115200)
    class_counts = np.bincount(labels, minlength=num_classes).astype(np.float32)
    # Inverse frequency weighting, normalized
    class_weights = 1.0 / np.maximum(class_counts, 1)
    class_weights = class_weights / class_weights.sum() * num_classes
    print(f"  Class weights: {dict(zip(active_class_names, [f'{w:.2f}' for w in class_weights]))}")

    # Datasets
    train_dataset = PanoradioDataset(train_indices, train_labels, mmap_data, augment=True)
    val_dataset = PanoradioDataset(val_indices, val_labels, mmap_data, augment=False)
    test_dataset = PanoradioDataset(test_indices, test_labels, mmap_data, augment=False)

    train_loader = DataLoader(train_dataset, batch_size=args.batch, shuffle=True,
                              num_workers=4, pin_memory=True, persistent_workers=True)
    val_loader = DataLoader(val_dataset, batch_size=args.batch, shuffle=False,
                            num_workers=2, pin_memory=True, persistent_workers=True)
    test_loader = DataLoader(test_dataset, batch_size=args.batch, shuffle=False,
                             num_workers=2, pin_memory=True, persistent_workers=True)

    # Device
    if torch.backends.mps.is_available():
        device = torch.device("mps")
    elif torch.cuda.is_available():
        device = torch.device("cuda")
    else:
        device = torch.device("cpu")
    print(f"  Device: {device}")

    # Model
    model = PanoradioCNN(num_classes).to(device)
    param_count = sum(p.numel() for p in model.parameters())
    print(f"  Model parameters: {param_count:,}")

    # Loss with class weights
    weight_tensor = torch.from_numpy(class_weights).to(device)
    criterion = nn.CrossEntropyLoss(weight=weight_tensor)

    optimizer = optim.Adam(model.parameters(), lr=args.lr, weight_decay=WEIGHT_DECAY)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)

    # Training loop
    print()
    print("Training")
    print("-" * 60)

    best_val_acc = 0
    best_state = None
    best_epoch = 0
    patience = 10
    no_improve = 0

    for epoch in range(args.epochs):
        t0 = time.time()
        train_loss, train_acc = train_epoch(model, train_loader, criterion, optimizer, device)
        val_acc, _, _ = evaluate(model, val_loader, device)
        scheduler.step()
        elapsed = time.time() - t0

        lr = optimizer.param_groups[0]["lr"]
        marker = ""
        if val_acc > best_val_acc:
            best_val_acc = val_acc
            best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}
            best_epoch = epoch + 1
            no_improve = 0
            marker = " *"
        else:
            no_improve += 1

        print(f"  Epoch {epoch+1:3d}/{args.epochs}  loss={train_loss:.4f}  "
              f"train={train_acc:.1%}  val={val_acc:.1%}  lr={lr:.6f}  "
              f"({elapsed:.1f}s){marker}")

        if no_improve >= patience:
            print(f"\n  Early stopping at epoch {epoch+1} (no improvement for {patience} epochs)")
            break

    # Load best model
    model.load_state_dict(best_state)
    model.to(device)

    # Final evaluation on test set
    print()
    print(f"Final Evaluation (best model from epoch {best_epoch})")
    print("-" * 60)

    test_acc, preds, true_labels = evaluate(model, test_loader, device)
    print(f"  Test accuracy: {test_acc:.1%}")
    print()
    print(classification_report(true_labels, preds,
                                target_names=active_class_names, zero_division=0))

    # Confusion matrix
    print("Confusion matrix:")
    cm = confusion_matrix(true_labels, preds)
    header = "          " + " ".join(f"{m[:6]:>6s}" for m in active_class_names)
    print(header)
    for i, row in enumerate(cm):
        cells = " ".join(f"{v:6d}" for v in row)
        print(f"  {active_class_names[i]:8s} {cells}")

    # Per-SNR accuracy analysis
    print()
    print("Per-SNR accuracy (test set):")
    print("-" * 40)

    # Reload SNR info for test indices
    import csv
    snr_map = {}
    with open(DATASET_CSV) as f:
        reader = csv.DictReader(f)
        for row in reader:
            snr_map[int(row['idx'])] = int(row[' snr'].strip())

    test_snrs = np.array([snr_map[int(test_indices[i])] for i in range(len(test_indices))])
    for snr in sorted(set(test_snrs)):
        mask = test_snrs == snr
        snr_acc = (preds[mask] == true_labels[mask]).mean()
        print(f"  SNR {snr:+3d} dB:  {snr_acc:.1%}  ({mask.sum()} samples)")

    # Save model
    torch.save(best_state, pt_path)
    print(f"\n  Saved PyTorch model: {pt_path}")

    # Save metadata for export
    meta = {
        "class_labels": active_class_names,
        "num_classes": num_classes,
        "num_iq_samples": NUM_IQ_SAMPLES,
        "sample_rate": SAMPLE_RATE,
        "test_accuracy": float(test_acc),
        "best_epoch": best_epoch,
        "param_count": param_count,
    }
    with open(meta_path, 'w') as f:
        json.dump(meta, f, indent=2)
    print(f"  Saved metadata: {meta_path}")

    # Try CoreML export inline (may fail if coremltools not in this env)
    try:
        import coremltools
        export_coreml(model, active_class_names, num_classes, script_dir)
    except ImportError:
        print("\n  coremltools not available in this Python environment.")
        print("  To export to CoreML, run:")
        print(f"    /tmp/coreml_venv/bin/python3 {os.path.abspath(__file__)} --export-only")

    print()
    print(f"Best validation accuracy: {best_val_acc:.1%}")
    print(f"Test accuracy: {test_acc:.1%}")
    print("Done.")


def export_coreml(model, class_labels, num_classes, output_dir):
    """Export PyTorch model to CoreML."""
    import coremltools as ct

    print()
    print("CoreML Export")
    print("-" * 60)

    model.eval()
    model.cpu()

    # Trace with dummy input: (1, 2, 2048)
    dummy = torch.randn(1, 2, NUM_IQ_SAMPLES)
    traced = torch.jit.trace(model, dummy)

    # Convert to CoreML neuralnetwork (works with coremltools 8.x)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="iq_samples", shape=(1, 2, NUM_IQ_SAMPLES))],
        classifier_config=ct.ClassifierConfig(class_labels),
        convert_to='neuralnetwork',
    )

    mlmodel.author = "Amateur Digital"
    mlmodel.short_description = (
        "CNN mode classifier trained on Panoradio HF dataset. "
        "Input: 2-channel IQ (real+imag), 2048 samples at 6 kHz."
    )
    mlmodel.input_description["iq_samples"] = (
        "Complex IQ as 2 channels (real, imag) x 2048 samples at 6 kHz sample rate. "
        "Per-channel zero-mean unit-variance normalized."
    )

    # Save .mlmodel
    mlmodel_path = os.path.join(output_dir, "PanoradioCNN.mlmodel")
    mlmodel.save(mlmodel_path)
    print(f"  Saved CoreML model: {mlmodel_path}")

    # Check size
    model_size = os.path.getsize(mlmodel_path) / 1024 / 1024
    print(f"  Model size: {model_size:.1f} MB")

    # Compile to .mlmodelc
    import subprocess
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", mlmodel_path, output_dir],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        mlmodelc_path = os.path.join(output_dir, "PanoradioCNN.mlmodelc")
        print(f"  Compiled: {mlmodelc_path}")

        # Copy to Swift package
        import shutil
        dst = os.path.join(output_dir, "..", "AmateurDigital", "ModeClassifierModel",
                           "Sources", "ModeClassifierModel", "Resources", "PanoradioCNN.mlmodelc")
        if os.path.exists(os.path.dirname(os.path.dirname(dst))):
            if os.path.exists(dst):
                shutil.rmtree(dst)
            if os.path.exists(mlmodelc_path):
                shutil.copytree(mlmodelc_path, dst)
                print(f"  Copied to Swift package: {dst}")
    else:
        print(f"  Compile warning: {result.stderr[:300]}")

    return mlmodel_path


def export_coreml_separate(pt_path, meta_path, output_dir):
    """Export from saved .pt file (for use with coreml_venv)."""
    import json

    # Load metadata
    with open(meta_path) as f:
        meta = json.load(f)

    class_labels = meta["class_labels"]
    num_classes = meta["num_classes"]

    print(f"  Classes: {class_labels}")
    print(f"  Num classes: {num_classes}")

    # Rebuild model and load weights
    # Need torch for this — check if available
    try:
        import torch
    except ImportError:
        print("Error: torch required for export. Install or use system Python to train first.")
        sys.exit(1)

    model = PanoradioCNN(num_classes)
    state_dict = torch.load(pt_path, map_location='cpu', weights_only=True)
    model.load_state_dict(state_dict)
    model.eval()

    export_coreml(model, class_labels, num_classes, output_dir)
    print("Export done.")


if __name__ == "__main__":
    main()
