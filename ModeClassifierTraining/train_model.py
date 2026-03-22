#!/usr/bin/env python3
"""
Mode Classifier Training — CNN on mel spectrograms

Trains a lightweight CNN to classify amateur radio digital mode signals
from 2-second audio clips. Exports to CoreML for iOS Neural Engine inference.

Usage:
    # 1. Generate training data (Swift):
    #    cd AmateurDigital/AmateurDigitalCore && swift run GenerateModeTrainingData --count 20
    #
    # 2. Train model (Python):
    #    cd ModeClassifierTraining && python3 train_model.py
    #
    # 3. Train with custom data dir:
    #    python3 train_model.py --data /path/to/mode_training_data

Requires: torch, torchaudio, coremltools, numpy, scikit-learn
    pip install torch torchaudio coremltools numpy scikit-learn
"""

import os
import sys
import argparse
import csv
import numpy as np
from pathlib import Path

import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader
import scipy.io.wavfile as wavfile

# Try importing coremltools (optional for training, required for export)
try:
    import coremltools as ct
    HAS_COREML = True
except ImportError:
    HAS_COREML = False
    print("Warning: coremltools not installed. Model will be saved as .pt only.")

from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report, confusion_matrix

# ============================================================================
# Configuration
# ============================================================================

SAMPLE_RATE = 48000
DURATION = 2.0
NUM_SAMPLES = int(SAMPLE_RATE * DURATION)

# Mel spectrogram parameters (tuned for HF digital modes 0-4kHz)
N_MELS = 64
N_FFT = 2048
HOP_LENGTH = 512
F_MIN = 100
F_MAX = 4000

# Mode labels
MODE_LABELS = ["rtty", "psk31", "bpsk63", "qpsk31", "qpsk63", "cw", "js8call", "noise"]
NUM_CLASSES = len(MODE_LABELS)

# Training parameters
BATCH_SIZE = 32
LEARNING_RATE = 0.001
NUM_EPOCHS = 30
WEIGHT_DECAY = 1e-4

# ============================================================================
# Dataset
# ============================================================================

def compute_mel_spectrogram(samples, sr=SAMPLE_RATE):
    """Compute log-mel spectrogram using numpy/scipy (no torchaudio dependency)."""
    from scipy.signal import stft

    # STFT
    freqs, times, Zxx = stft(samples, fs=sr, nperseg=N_FFT, noverlap=N_FFT - HOP_LENGTH,
                              window='hann', boundary=None, padded=False)

    # Power spectrum
    power = np.abs(Zxx) ** 2

    # Build mel filterbank
    def hz_to_mel(hz):
        return 2595 * np.log10(1 + hz / 700)
    def mel_to_hz(mel):
        return 700 * (10 ** (mel / 2595) - 1)

    mel_min = hz_to_mel(F_MIN)
    mel_max = hz_to_mel(F_MAX)
    mel_points = mel_to_hz(np.linspace(mel_min, mel_max, N_MELS + 2))

    fft_freqs = freqs
    filterbank = np.zeros((N_MELS, len(fft_freqs)))
    for m in range(N_MELS):
        f_low, f_center, f_high = mel_points[m], mel_points[m+1], mel_points[m+2]
        for k, f in enumerate(fft_freqs):
            if f_low <= f <= f_center and f_center > f_low:
                filterbank[m, k] = (f - f_low) / (f_center - f_low)
            elif f_center < f <= f_high and f_high > f_center:
                filterbank[m, k] = (f_high - f) / (f_high - f_center)

    # Apply filterbank
    mel_spec = filterbank @ power  # (N_MELS, num_frames)

    # Log scale
    mel_spec = 10 * np.log10(np.maximum(mel_spec, 1e-10))

    # Normalize to [0, 1]
    mel_min_val = mel_spec.min()
    mel_max_val = mel_spec.max()
    if mel_max_val > mel_min_val:
        mel_spec = (mel_spec - mel_min_val) / (mel_max_val - mel_min_val)

    return mel_spec.astype(np.float32)


class ModeDataset(Dataset):
    """Loads WAV files and computes mel spectrograms."""

    def __init__(self, file_paths, labels, data_dir, augment=False, cache=None):
        self.file_paths = file_paths
        self.labels = labels
        self.data_dir = data_dir
        self.augment = augment
        self.cache = cache  # Optional precomputed spectrogram cache

    def __len__(self):
        return len(self.file_paths)

    def __getitem__(self, idx):
        fp = self.file_paths[idx]

        if self.augment:
            # For augmented training: load raw audio, apply augmentations, recompute mel
            path = os.path.join(self.data_dir, fp)
            sr, data = wavfile.read(path)
            if data.dtype == np.int16:
                samples = data.astype(np.float32) / 32768.0
            elif data.dtype == np.int32:
                samples = data.astype(np.float32) / 2147483648.0
            else:
                samples = data.astype(np.float32)
            if samples.ndim > 1:
                samples = samples.mean(axis=1)
            if len(samples) < NUM_SAMPLES:
                samples = np.pad(samples, (0, NUM_SAMPLES - len(samples)))
            else:
                samples = samples[:NUM_SAMPLES]

            # Random gain ±6 dB
            gain_db = (np.random.random() - 0.5) * 12
            samples = samples * (10 ** (gain_db / 20))

            # Random time shift ±2000 samples
            shift = int((np.random.random() - 0.5) * 4000)
            if shift > 0:
                samples = np.pad(samples[shift:], (0, shift))
            elif shift < 0:
                samples = np.pad(samples[:shift], (-shift, 0))

            # 50% chance: add extra noise
            if np.random.random() > 0.5:
                rms = np.sqrt(np.mean(samples ** 2))
                if rms > 1e-6:
                    snr = np.random.uniform(3, 15)
                    noise_rms = rms / (10 ** (snr / 20))
                    samples = samples + np.random.randn(len(samples)).astype(np.float32) * noise_rms

            # 30% chance: small frequency offset
            if np.random.random() > 0.7:
                offset_hz = (np.random.random() - 0.5) * 60
                t = np.arange(len(samples), dtype=np.float32) / SAMPLE_RATE
                samples = samples * np.cos(2 * np.pi * offset_hz * t).astype(np.float32)

            mel = compute_mel_spectrogram(samples, sr)
        elif self.cache is not None and fp in self.cache:
            # Use cached spectrogram
            mel = self.cache[fp]
        else:
            path = os.path.join(self.data_dir, fp)
            sr, data = wavfile.read(path)
            if data.dtype == np.int16:
                samples = data.astype(np.float32) / 32768.0
            else:
                samples = data.astype(np.float32)
            if samples.ndim > 1:
                samples = samples.mean(axis=1)
            if len(samples) < NUM_SAMPLES:
                samples = np.pad(samples, (0, NUM_SAMPLES - len(samples)))
            else:
                samples = samples[:NUM_SAMPLES]
            mel = compute_mel_spectrogram(samples, sr)

        # Shape: (1, N_MELS, num_frames)
        mel_tensor = torch.from_numpy(mel).unsqueeze(0)
        return mel_tensor, self.labels[idx]

# ============================================================================
# Model — Lightweight CNN
# ============================================================================

class ModeClassifierCNN(nn.Module):
    """
    Lightweight CNN for mode classification from mel spectrograms.
    ~100K parameters — fast inference on iPhone Neural Engine via CoreML.

    Input: (1, 64, T) mel spectrogram where T = ceil(NUM_SAMPLES / HOP_LENGTH)
    Output: (NUM_CLASSES,) logits
    """

    def __init__(self, num_classes=NUM_CLASSES):
        super().__init__()

        self.features = nn.Sequential(
            # Block 1: (1, 64, T) -> (32, 32, T/2)
            nn.Conv2d(1, 32, kernel_size=3, padding=1),
            nn.BatchNorm2d(32),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),

            # Block 2: (32, 32, T/2) -> (64, 16, T/4)
            nn.Conv2d(32, 64, kernel_size=3, padding=1),
            nn.BatchNorm2d(64),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),

            # Block 3: (64, 16, T/4) -> (128, 8, T/8)
            nn.Conv2d(64, 128, kernel_size=3, padding=1),
            nn.BatchNorm2d(128),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),

            # Block 4: (128, 8, T/8) -> (128, 4, T/16)
            nn.Conv2d(128, 128, kernel_size=3, padding=1),
            nn.BatchNorm2d(128),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),
        )

        self.classifier = nn.Sequential(
            nn.AdaptiveAvgPool2d((1, 1)),
            nn.Flatten(),
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
# Training
# ============================================================================

def train_epoch(model, loader, criterion, optimizer, device):
    model.train()
    total_loss = 0
    correct = 0
    total = 0

    for mel, labels in loader:
        mel, labels = mel.to(device), labels.to(device)
        optimizer.zero_grad()
        outputs = model(mel)
        loss = criterion(outputs, labels)
        loss.backward()
        optimizer.step()

        total_loss += loss.item() * mel.size(0)
        _, predicted = outputs.max(1)
        total += labels.size(0)
        correct += predicted.eq(labels).sum().item()

    return total_loss / total, correct / total

def evaluate(model, loader, device):
    model.eval()
    correct = 0
    total = 0
    all_preds = []
    all_labels = []

    with torch.no_grad():
        for mel, labels in loader:
            mel, labels = mel.to(device), labels.to(device)
            outputs = model(mel)
            _, predicted = outputs.max(1)
            total += labels.size(0)
            correct += predicted.eq(labels).sum().item()
            all_preds.extend(predicted.cpu().numpy())
            all_labels.extend(labels.cpu().numpy())

    return correct / total, np.array(all_preds), np.array(all_labels)

# ============================================================================
# CoreML Export
# ============================================================================

def export_coreml(model, output_path, mel_time_steps):
    """Export trained model to CoreML format."""
    model.eval()
    model.cpu()

    # Trace the model
    dummy_input = torch.randn(1, 1, N_MELS, mel_time_steps)
    traced = torch.jit.trace(model, dummy_input)

    # Convert to CoreML
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mel_spectrogram", shape=(1, 1, N_MELS, mel_time_steps))],
        classifier_config=ct.ClassifierConfig(MODE_LABELS),
        minimum_deployment_target=ct.target.iOS16,
    )

    # Set metadata
    mlmodel.author = "Amateur Digital"
    mlmodel.short_description = "Classifies amateur radio digital mode signals from mel spectrograms"
    mlmodel.input_description["mel_spectrogram"] = "Log-mel spectrogram (1x1x64xT), normalized to [0,1]"

    # Save .mlmodel
    mlmodel_path = output_path.replace(".mlmodelc", ".mlmodel")
    mlmodel.save(mlmodel_path)
    print(f"  Saved CoreML model: {mlmodel_path}")

    # Compile to .mlmodelc
    import subprocess
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", mlmodel_path, os.path.dirname(output_path)],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        print(f"  Compiled: {output_path}")
    else:
        print(f"  Warning: compilation failed: {result.stderr}")
        print(f"  .mlmodel saved at {mlmodel_path} — compile manually with Xcode")

    return mlmodel_path

# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Train mode classifier CNN")
    parser.add_argument("--data", default="/tmp/mode_training_data", help="Training data directory")
    parser.add_argument("--epochs", type=int, default=NUM_EPOCHS, help="Training epochs")
    parser.add_argument("--batch", type=int, default=BATCH_SIZE, help="Batch size")
    parser.add_argument("--lr", type=float, default=LEARNING_RATE, help="Learning rate")
    parser.add_argument("--output", default=None, help="Output directory for model")
    args = parser.parse_args()

    data_dir = args.data
    output_dir = args.output or os.path.dirname(os.path.abspath(__file__))

    print("Mode Classifier Training")
    print("=" * 60)

    # Load labels
    labels_path = os.path.join(data_dir, "labels.csv")
    if not os.path.exists(labels_path):
        print(f"Error: {labels_path} not found.")
        print("Run: cd AmateurDigital/AmateurDigitalCore && swift run GenerateModeTrainingData")
        sys.exit(1)

    file_paths = []
    labels = []
    with open(labels_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            mode = row["mode"]
            if mode in MODE_LABELS:
                file_paths.append(row["file"])
                labels.append(MODE_LABELS.index(mode))

    print(f"  Loaded {len(file_paths)} samples from {data_dir}")

    # Class distribution
    for i, mode in enumerate(MODE_LABELS):
        count = labels.count(i)
        print(f"    {mode:10s} {count:5d} samples")

    # Train/test split (stratified)
    X_train, X_test, y_train, y_test = train_test_split(
        file_paths, labels, test_size=0.2, stratify=labels, random_state=42
    )
    print(f"  Train: {len(X_train)}, Test: {len(X_test)}")

    # Compute expected time steps for the mel spectrogram
    # scipy.signal.stft with boundary=None produces (NUM_SAMPLES - N_FFT) // HOP_LENGTH + 1 frames
    mel_time_steps = (NUM_SAMPLES - N_FFT) // HOP_LENGTH + 1

    # Precompute spectrograms to speed up training (cache them in memory)
    print("\n  Precomputing spectrograms...")
    import time
    cache_start = time.time()
    all_mels = {}
    total_files = len(file_paths)
    for i, fp in enumerate(file_paths):
        path = os.path.join(data_dir, fp)
        sr, data = wavfile.read(path)
        if data.dtype == np.int16:
            samples = data.astype(np.float32) / 32768.0
        else:
            samples = data.astype(np.float32)
        if samples.ndim > 1:
            samples = samples.mean(axis=1)
        if len(samples) < NUM_SAMPLES:
            samples = np.pad(samples, (0, NUM_SAMPLES - len(samples)))
        else:
            samples = samples[:NUM_SAMPLES]
        all_mels[fp] = compute_mel_spectrogram(samples, sr)
        if (i + 1) % 500 == 0:
            print(f"    {i+1}/{total_files}...")
    print(f"  Cached {len(all_mels)} spectrograms in {time.time()-cache_start:.0f}s")

    # Datasets
    train_dataset = ModeDataset(X_train, y_train, data_dir, augment=True, cache=all_mels)
    test_dataset = ModeDataset(X_test, y_test, data_dir, augment=False, cache=all_mels)

    train_loader = DataLoader(train_dataset, batch_size=args.batch, shuffle=True, num_workers=0)
    test_loader = DataLoader(test_dataset, batch_size=args.batch, shuffle=False, num_workers=0)

    # Model
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"  Device: {device}")

    model = ModeClassifierCNN(NUM_CLASSES).to(device)
    param_count = sum(p.numel() for p in model.parameters())
    print(f"  Model parameters: {param_count:,}")

    criterion = nn.CrossEntropyLoss()
    optimizer = optim.Adam(model.parameters(), lr=args.lr, weight_decay=WEIGHT_DECAY)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)

    # Training loop
    print()
    print("Training")
    print("-" * 60)

    best_acc = 0
    best_state = None

    for epoch in range(args.epochs):
        train_loss, train_acc = train_epoch(model, train_loader, criterion, optimizer, device)
        test_acc, _, _ = evaluate(model, test_loader, device)
        scheduler.step()

        lr = optimizer.param_groups[0]["lr"]
        print(f"  Epoch {epoch+1:3d}/{args.epochs}  loss={train_loss:.4f}  "
              f"train={train_acc:.1%}  test={test_acc:.1%}  lr={lr:.6f}")

        if test_acc > best_acc:
            best_acc = test_acc
            best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}

    # Load best model
    model.load_state_dict(best_state)
    model.to(device)

    # Final evaluation
    print()
    print("Final Evaluation")
    print("-" * 60)

    test_acc, preds, true_labels = evaluate(model, test_loader, device)
    print(f"  Test accuracy: {test_acc:.1%}")
    print()
    print(classification_report(true_labels, preds, target_names=MODE_LABELS, zero_division=0))
    print("Confusion matrix:")
    cm = confusion_matrix(true_labels, preds)
    header = "          " + " ".join(f"{m[:6]:>6s}" for m in MODE_LABELS)
    print(header)
    for i, row in enumerate(cm):
        cells = " ".join(f"{v:6d}" for v in row)
        print(f"  {MODE_LABELS[i]:8s} {cells}")

    # Save PyTorch model
    pt_path = os.path.join(output_dir, "ModeClassifier.pt")
    torch.save(best_state, pt_path)
    print(f"\n  Saved PyTorch model: {pt_path}")

    # Export to CoreML
    if HAS_COREML:
        print()
        print("CoreML Export")
        print("-" * 60)
        mlmodelc_path = os.path.join(output_dir, "ModeClassifier.mlmodelc")
        export_coreml(model, mlmodelc_path, mel_time_steps)

        # Also copy to the Swift package location
        swift_pkg_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "AmateurDigital", "ModeClassifierModel", "Sources", "ModeClassifierModel", "Resources"
        )
        if os.path.exists(os.path.dirname(swift_pkg_dir)):
            os.makedirs(swift_pkg_dir, exist_ok=True)
            import shutil
            src = os.path.join(output_dir, "ModeClassifier.mlmodelc")
            if os.path.exists(src):
                dst = os.path.join(swift_pkg_dir, "ModeClassifier.mlmodelc")
                if os.path.exists(dst):
                    shutil.rmtree(dst)
                shutil.copytree(src, dst)
                print(f"  Copied to Swift package: {dst}")

    print()
    print(f"Best test accuracy: {best_acc:.1%}")
    print("Done.")

if __name__ == "__main__":
    main()
