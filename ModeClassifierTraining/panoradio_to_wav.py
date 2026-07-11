#!/usr/bin/env python3
"""
Convert Panoradio HF dataset IQ samples to 48 kHz mono WAV files
for use with our mode detection trainer and feature extractor.

Pipeline: IQ (6 kHz baseband) → upsample 8x → freq shift to tone center → real part → WAV

Usage:
    python3 panoradio_to_wav.py                    # Convert all supported modes, 10 per SNR
    python3 panoradio_to_wav.py --count 50         # 50 samples per mode per SNR
    python3 panoradio_to_wav.py --snr 10 --count 5 # Only SNR=10, 5 samples
    python3 panoradio_to_wav.py --output /tmp/panoradio_wav
"""

import numpy as np
import csv
import os
import sys
import struct
import argparse
from scipy.signal import resample_poly

# Mode mapping: panoradio label → (our_mode, tone_center_hz)
# Tone center is where we place the signal in the audio spectrum
MODE_MAP = {
    "morse":       ("CW",     700),
    "psk31":       ("PSK31",  1000),
    "psk63":       ("BPSK63", 1000),
    "qpsk31":      ("QPSK31", 1000),
    "rtty45_170":  ("RTTY",   2040),   # midpoint of mark 2125, space 1955
    "rtty50_170":  ("RTTY",   2040),   # same shift, different baud
    # Modes we don't decode but should classify as "other/unknown"
    "rtty100_850": ("other",  2040),
    "olivia8_250": ("other",  1500),
    "olivia16_500":("other",  1500),
    "olivia16_1000":("other", 1500),
    "olivia32_1000":("other", 1500),
    "dominoex11":  ("other",  1500),
    "mt63_1000":   ("other",  1500),
    "navtex":      ("other",  2040),
    "usb":         ("other",  1500),
    "lsb":         ("other",  1500),
    "am":          ("other",  1500),
    "fax":         ("other",  1500),
}

INPUT_SR = 6000
OUTPUT_SR = 48000
UPSAMPLE_FACTOR = OUTPUT_SR // INPUT_SR  # 8

DATASET_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "panoradio")


def iq_to_audio(iq_samples, tone_hz):
    """Convert baseband IQ to real audio at 48 kHz."""
    # Upsample 6 kHz → 48 kHz
    iq_48k = resample_poly(iq_samples, UPSAMPLE_FACTOR, 1)

    # Frequency-shift to tone center
    t = np.arange(len(iq_48k)) / OUTPUT_SR
    audio = np.real(iq_48k * np.exp(2j * np.pi * tone_hz * t))

    # Normalize to [-0.9, 0.9]
    peak = np.max(np.abs(audio))
    if peak > 0:
        audio = audio / peak * 0.9

    return audio.astype(np.float32)


def write_wav(path, samples, sr=48000):
    """Write mono 16-bit WAV."""
    n = len(samples)
    data_size = n * 2
    with open(path, "wb") as f:
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + data_size))
        f.write(b"WAVE")
        f.write(b"fmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, sr, sr * 2, 2, 16))
        f.write(b"data")
        f.write(struct.pack("<I", data_size))
        for s in samples:
            v = max(-1.0, min(1.0, float(s)))
            f.write(struct.pack("<h", int(v * 32767)))


def main():
    parser = argparse.ArgumentParser(description="Convert Panoradio IQ to WAV")
    parser.add_argument("--count", type=int, default=10, help="Samples per mode per SNR")
    parser.add_argument("--snr", type=int, default=None, help="Single SNR level (default: all)")
    parser.add_argument("--output", default="/tmp/panoradio_wav", help="Output directory")
    parser.add_argument("--modes", default="supported", choices=["supported", "all"],
                        help="'supported' = only our modes, 'all' = include 'other' category")
    args = parser.parse_args()

    output_dir = args.output
    os.makedirs(output_dir, exist_ok=True)

    print("Panoradio IQ → WAV Converter")
    print("=" * 60)

    # Load tags
    tags_path = os.path.join(DATASET_DIR, "dataset_panoradio_hf_tags.csv")
    tags = []
    with open(tags_path) as f:
        reader = csv.DictReader(f, skipinitialspace=True)
        for row in reader:
            tags.append({
                "idx": int(row["idx"]),
                "mode": row["mode"].strip(),
                "snr": int(row["snr"].strip()),
            })
    print(f"  Tags: {len(tags)} entries")

    # Filter by SNR
    if args.snr is not None:
        tags = [t for t in tags if t["snr"] == args.snr]
        print(f"  Filtered to SNR={args.snr}: {len(tags)} entries")

    # Group by mode
    by_mode = {}
    for t in tags:
        by_mode.setdefault(t["mode"], []).append(t)

    # Filter modes
    if args.modes == "supported":
        target_modes = {k for k, (our_mode, _) in MODE_MAP.items() if our_mode != "other"}
    else:
        target_modes = set(MODE_MAP.keys())

    # Load dataset (memory-mapped to avoid loading 5.3 GB into RAM)
    npy_path = os.path.join(DATASET_DIR, "dataset_hf_radio.npy")
    print(f"  Loading dataset (memory-mapped)...")
    dataset = np.load(npy_path, mmap_mode="r")
    print(f"  Dataset shape: {dataset.shape}, dtype: {dataset.dtype}")

    # Convert
    total_files = 0
    for panoradio_mode in sorted(target_modes):
        if panoradio_mode not in by_mode:
            continue

        our_mode, tone_hz = MODE_MAP[panoradio_mode]
        mode_dir = os.path.join(output_dir, our_mode.lower())
        os.makedirs(mode_dir, exist_ok=True)

        # Group by SNR within this mode
        by_snr = {}
        for t in by_mode[panoradio_mode]:
            by_snr.setdefault(t["snr"], []).append(t)

        for snr in sorted(by_snr.keys()):
            entries = by_snr[snr][:args.count]
            for i, entry in enumerate(entries):
                idx = entry["idx"]
                iq = dataset[idx]
                audio = iq_to_audio(iq, tone_hz)

                filename = f"{panoradio_mode}_snr{snr:+d}_{i:03d}.wav"
                path = os.path.join(mode_dir, filename)
                write_wav(path, audio)
                total_files += 1

        count_for_mode = sum(min(len(v), args.count) for v in by_snr.values())
        print(f"  {panoradio_mode:20s} → {our_mode:8s}  {count_for_mode:4d} files  tone={tone_hz}Hz")

    # Write labels CSV
    labels_path = os.path.join(output_dir, "labels.csv")
    with open(labels_path, "w") as f:
        f.write("file,mode,condition\n")
        for mode_dir_name in sorted(os.listdir(output_dir)):
            full_dir = os.path.join(output_dir, mode_dir_name)
            if not os.path.isdir(full_dir):
                continue
            for wav_file in sorted(os.listdir(full_dir)):
                if wav_file.endswith(".wav"):
                    rel_path = f"{mode_dir_name}/{wav_file}"
                    f.write(f"{rel_path},{mode_dir_name},{wav_file.replace('.wav','')}\n")

    print(f"\n  Total: {total_files} WAV files")
    print(f"  Labels: {labels_path}")
    print(f"  Output: {output_dir}")


if __name__ == "__main__":
    main()
