#!/usr/bin/env python3
"""
Convert Panoradio HF dataset IQ samples to 48kHz WAV files for decoder testing.

Generates WAV files for modes matching our decoders:
  morse, psk31, psk63, qpsk31, rtty45_170, rtty50_170

Each WAV is frequency-shifted to the expected audio tone and resampled to 48kHz.

Usage:
    python3 scripts/panoradio_to_wav.py                    # 10 samples per mode per SNR
    python3 scripts/panoradio_to_wav.py --count 50         # 50 samples per mode per SNR
    python3 scripts/panoradio_to_wav.py --snr 10 15 20     # specific SNR levels only
    python3 scripts/panoradio_to_wav.py --output /tmp/wav  # custom output dir
"""

import argparse
import csv
import json
import os
import sys
import wave
import struct

import numpy as np
from scipy.signal import resample_poly

# Modes we can decode, mapped to audio center frequencies
SUPPORTED_MODES = {
    "morse":      {"tone_hz": 700,  "our_mode": "CW"},
    "psk31":      {"tone_hz": 1000, "our_mode": "PSK31"},
    "psk63":      {"tone_hz": 1000, "our_mode": "BPSK63"},
    "qpsk31":     {"tone_hz": 1000, "our_mode": "QPSK31"},
    "rtty45_170": {"tone_hz": 2040, "our_mode": "RTTY"},  # midpoint of mark 2125, space 1955
    "rtty50_170": {"tone_hz": 2040, "our_mode": "RTTY"},
}

# Modes that are NOT ours — useful for false positive testing
NON_SUPPORTED_MODES = [
    "rtty100_850", "olivia8_250", "olivia16_500", "olivia16_1000",
    "olivia32_1000", "dominoex11", "mt63_1000", "navtex",
    "usb", "lsb", "am", "fax"
]


def load_dataset(panoradio_dir):
    """Load the Panoradio dataset and tags."""
    npy_path = os.path.join(panoradio_dir, "dataset_hf_radio.npy")
    tags_path = os.path.join(panoradio_dir, "dataset_panoradio_hf_tags.csv")

    if not os.path.exists(npy_path):
        print(f"Error: {npy_path} not found")
        sys.exit(1)

    print(f"Loading tags from {tags_path}...")
    tags = []
    with open(tags_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            tags.append({
                "idx": int(row[" idx"] if " idx" in row else row["idx"]),
                "mode": row[" mode"].strip() if " mode" in row else row["mode"].strip(),
                "snr": int(row[" snr"].strip() if " snr" in row else row["snr"].strip()),
            })

    print(f"Loaded {len(tags)} tags")
    return npy_path, tags


def iq_to_audio(iq_samples, tone_hz, input_rate=6000, output_rate=48000):
    """Convert baseband IQ to real audio at output_rate with tone at tone_hz."""
    # Upsample from 6kHz to 48kHz (ratio 8:1)
    ratio = output_rate // input_rate
    iq_48k = resample_poly(iq_samples, ratio, 1)

    # Frequency-shift to tone frequency
    t = np.arange(len(iq_48k)) / output_rate
    shifted = iq_48k * np.exp(2j * np.pi * tone_hz * t)

    # Extract real part
    audio = np.real(shifted).astype(np.float32)

    # Normalize to prevent clipping
    peak = np.max(np.abs(audio))
    if peak > 0:
        audio = audio / peak * 0.8

    return audio


def write_wav(filepath, audio, sample_rate=48000):
    """Write float32 audio to 16-bit WAV."""
    audio_int16 = np.clip(audio * 32767, -32768, 32767).astype(np.int16)
    with wave.open(filepath, 'w') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(audio_int16.tobytes())


def main():
    parser = argparse.ArgumentParser(description="Convert Panoradio IQ to WAV for decoder testing")
    parser.add_argument("--panoradio", default="panoradio", help="Path to panoradio directory")
    parser.add_argument("--output", default="samples/panoradio", help="Output directory for WAV files")
    parser.add_argument("--count", type=int, default=10, help="Samples per mode per SNR level")
    parser.add_argument("--snr", type=int, nargs="*", default=None, help="SNR levels to include (default: all)")
    parser.add_argument("--include-nonsupported", action="store_true", help="Also generate WAVs for non-supported modes (for false positive testing)")
    args = parser.parse_args()

    npy_path, tags = load_dataset(args.panoradio)

    # Build index: mode -> snr -> [indices]
    index = {}
    for tag in tags:
        mode = tag["mode"]
        snr = tag["snr"]
        if mode not in index:
            index[mode] = {}
        if snr not in index[mode]:
            index[mode][snr] = []
        index[mode][snr].append(tag["idx"])

    # Determine which modes and SNR levels to process
    modes_to_process = dict(SUPPORTED_MODES)
    if args.include_nonsupported:
        for m in NON_SUPPORTED_MODES:
            modes_to_process[m] = {"tone_hz": 1500, "our_mode": "NONE"}

    snr_levels = args.snr if args.snr else sorted(set(t["snr"] for t in tags))

    # Create output directory
    os.makedirs(args.output, exist_ok=True)

    # Memory-map the numpy array (avoid loading 5.3 GB into RAM)
    print(f"Memory-mapping {npy_path}...")
    data = np.load(npy_path, mmap_mode='r')
    print(f"Dataset shape: {data.shape}, dtype: {data.dtype}")

    manifest = []
    total = 0

    for mode_name, mode_info in sorted(modes_to_process.items()):
        if mode_name not in index:
            print(f"  Skipping {mode_name} (not in dataset)")
            continue

        tone_hz = mode_info["tone_hz"]
        our_mode = mode_info["our_mode"]
        mode_dir = os.path.join(args.output, mode_name)
        os.makedirs(mode_dir, exist_ok=True)

        for snr in sorted(snr_levels):
            if snr not in index[mode_name]:
                continue

            available = index[mode_name][snr]
            count = min(args.count, len(available))
            selected = available[:count]

            for i, idx in enumerate(selected):
                iq = data[idx]
                audio = iq_to_audio(iq, tone_hz)

                filename = f"{mode_name}_snr{snr:+d}dB_{i:03d}.wav"
                filepath = os.path.join(mode_dir, filename)
                write_wav(filepath, audio)

                manifest.append({
                    "file": os.path.relpath(filepath, args.output),
                    "mode": mode_name,
                    "our_mode": our_mode,
                    "snr_db": snr,
                    "panoradio_idx": idx,
                    "tone_hz": tone_hz,
                })
                total += 1

        print(f"  {mode_name}: {sum(1 for m in manifest if m['mode'] == mode_name)} WAV files")

    # Write manifest
    manifest_path = os.path.join(args.output, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"\nGenerated {total} WAV files in {args.output}/")
    print(f"Manifest: {manifest_path}")
    print(f"\nTo decode with our tools:")
    print(f"  cd AmateurDigital/AmateurDigitalCore")
    print(f"  swift run DecodeWAV ../../{args.output}/<mode>/<file>.wav")


if __name__ == "__main__":
    main()
