#!/usr/bin/env python3
"""
Real-world decoder evaluation using Panoradio HF dataset.

Tests three critical capabilities for radio operation:
1. Signal detection: Does the decoder detect a signal is present?
2. Mode classification: Is the detected mode correct?
3. False positive rejection: Does the decoder stay silent on wrong-mode signals?

Also creates longer concatenated test signals (3-7 seconds) for decode testing.

Usage:
    python3 scripts/eval_real_world.py                          # Full evaluation
    python3 scripts/eval_real_world.py --quick                  # Quick (2 per mode/SNR)
    python3 scripts/eval_real_world.py --concat-only             # Only create concatenated WAVs
"""

import argparse
import csv
import json
import os
import subprocess
import sys
import wave

import numpy as np
from scipy.signal import resample_poly

# Our mode mapping
MODE_MAP = {
    "morse":      {"tone_hz": 700,  "our_mode": "CW",     "decoder": "cw"},
    "psk31":      {"tone_hz": 1000, "our_mode": "PSK31",   "decoder": "psk"},
    "psk63":      {"tone_hz": 1000, "our_mode": "BPSK63",  "decoder": "psk"},
    "qpsk31":     {"tone_hz": 1000, "our_mode": "QPSK31",  "decoder": "psk"},
    "rtty45_170": {"tone_hz": 2040, "our_mode": "RTTY",    "decoder": "rtty"},
    "rtty50_170": {"tone_hz": 2040, "our_mode": "RTTY",    "decoder": "rtty"},
}

NON_SUPPORTED = [
    "rtty100_850", "olivia8_250", "olivia16_500", "olivia16_1000",
    "olivia32_1000", "dominoex11", "mt63_1000", "navtex",
    "usb", "lsb", "am", "fax"
]


def iq_to_audio(iq_samples, tone_hz, input_rate=6000, output_rate=48000):
    ratio = output_rate // input_rate
    iq_48k = resample_poly(iq_samples, ratio, 1)
    t = np.arange(len(iq_48k)) / output_rate
    shifted = iq_48k * np.exp(2j * np.pi * tone_hz * t)
    audio = np.real(shifted).astype(np.float32)
    peak = np.max(np.abs(audio))
    if peak > 0:
        audio = audio / peak * 0.8
    return audio


def write_wav(filepath, audio, sample_rate=48000):
    audio_int16 = np.clip(audio * 32767, -32768, 32767).astype(np.int16)
    with wave.open(filepath, 'w') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(audio_int16.tobytes())


def create_concatenated_samples(data, tags, output_dir, count_per_concat=15, num_concat=3):
    """Create longer signals by concatenating multiple Panoradio samples."""
    os.makedirs(output_dir, exist_ok=True)

    # Build index
    index = {}
    for tag in tags:
        mode, snr = tag["mode"], tag["snr"]
        if mode not in index:
            index[mode] = {}
        if snr not in index[mode]:
            index[mode][snr] = []
        index[mode][snr].append(tag["idx"])

    manifest = []

    for mode_name, mode_info in sorted(MODE_MAP.items()):
        if mode_name not in index:
            continue

        tone_hz = mode_info["tone_hz"]
        mode_dir = os.path.join(output_dir, mode_name)
        os.makedirs(mode_dir, exist_ok=True)

        for snr in [25, 15, 5, 0, -5]:
            if snr not in index[mode_name]:
                continue

            available = index[mode_name][snr]

            for concat_i in range(min(num_concat, len(available) // count_per_concat)):
                # Take count_per_concat consecutive samples
                start = concat_i * count_per_concat
                sample_indices = available[start:start + count_per_concat]

                # Convert each to audio and concatenate
                audio_segments = []
                for idx in sample_indices:
                    iq = data[idx]
                    audio = iq_to_audio(iq, tone_hz)
                    audio_segments.append(audio)

                full_audio = np.concatenate(audio_segments)
                duration_s = len(full_audio) / 48000

                filename = f"{mode_name}_snr{snr:+d}dB_concat{concat_i:02d}_{duration_s:.1f}s.wav"
                filepath = os.path.join(mode_dir, filename)
                write_wav(filepath, full_audio)

                manifest.append({
                    "file": os.path.relpath(filepath, output_dir),
                    "mode": mode_name,
                    "our_mode": mode_info["our_mode"],
                    "snr_db": snr,
                    "duration_s": round(duration_s, 1),
                    "num_segments": len(sample_indices),
                })

    manifest_path = os.path.join(output_dir, "concat_manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    return manifest


def run_decode_wav(wav_path, core_dir):
    """Run DecodeWAV on a file and parse output."""
    try:
        result = subprocess.run(
            ["swift", "run", "-c", "release", "DecodeWAV", wav_path],
            cwd=core_dir,
            capture_output=True, text=True, timeout=30
        )
        output = result.stdout + result.stderr

        # Parse: look for signal detections and decoded text
        signals_found = output.count("Signal ")
        chars_decoded = 0
        detected_mode = None

        for line in output.split("\n"):
            if "chars" in line and "score" in line:
                # Parse "Signal N: freq Hz | N chars | score X | quality Y%"
                try:
                    parts = line.split("|")
                    for p in parts:
                        if "chars" in p:
                            chars_decoded += int(p.strip().split()[0])
                except (ValueError, IndexError):
                    pass

            if "Auto-detecting mode..." in line:
                # "Auto-detecting mode... PSK (159ms)"
                mode_part = line.split("...")[-1].strip()
                detected_mode = mode_part.split("(")[0].strip()

        return {
            "signals_found": signals_found,
            "chars_decoded": chars_decoded,
            "detected_mode": detected_mode,
            "returncode": result.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"signals_found": 0, "chars_decoded": 0, "detected_mode": None, "returncode": -1}
    except FileNotFoundError:
        return {"signals_found": 0, "chars_decoded": 0, "detected_mode": None, "returncode": -2}


def evaluate_decode(manifest, samples_dir, core_dir):
    """Run DecodeWAV on concatenated samples and measure real-world performance."""
    results = []

    for entry in manifest:
        wav_path = os.path.abspath(os.path.join(samples_dir, entry["file"]))
        mode = entry["mode"]
        snr = entry["snr_db"]
        our_mode = entry["our_mode"]

        decode = run_decode_wav(wav_path, core_dir)

        # Did we detect a signal?
        detected = decode["signals_found"] > 0

        # Did we classify the mode correctly?
        mode_correct = False
        if decode["detected_mode"]:
            dm = decode["detected_mode"].upper()
            if our_mode == "RTTY" and "RTTY" in dm:
                mode_correct = True
            elif our_mode == "CW" and ("CW" in dm or "MORSE" in dm):
                mode_correct = True
            elif our_mode in ["PSK31", "BPSK63", "QPSK31"] and "PSK" in dm:
                mode_correct = True

        results.append({
            **entry,
            "detected": detected,
            "mode_correct": mode_correct,
            "chars_decoded": decode["chars_decoded"],
            "detected_mode_raw": decode["detected_mode"],
        })

        status = "OK" if detected else "MISS"
        mode_status = "correct" if mode_correct else ("wrong" if decode["detected_mode"] else "none")
        print(f"  [{status}] {entry['file']:60s} det={detected} mode={mode_status} chars={decode['chars_decoded']}")

    return results


def print_summary(results):
    """Print per-mode, per-SNR summary table."""
    print("\n" + "=" * 80)
    print("REAL-WORLD EVALUATION SUMMARY")
    print("=" * 80)

    # Group by mode
    modes = sorted(set(r["mode"] for r in results))
    snrs = sorted(set(r["snr_db"] for r in results), reverse=True)

    print(f"\n{'Mode':<15s}", end="")
    for snr in snrs:
        print(f"  {snr:+3d} dB", end="")
    print("   Overall")
    print("-" * (15 + len(snrs) * 8 + 10))

    for mode in modes:
        print(f"{mode:<15s}", end="")
        mode_results = [r for r in results if r["mode"] == mode]

        for snr in snrs:
            snr_results = [r for r in mode_results if r["snr_db"] == snr]
            if snr_results:
                det_rate = sum(1 for r in snr_results if r["detected"]) / len(snr_results) * 100
                print(f"  {det_rate:5.0f}%", end="")
            else:
                print(f"      -", end="")

        total_det = sum(1 for r in mode_results if r["detected"])
        total = len(mode_results)
        print(f"   {total_det}/{total} ({total_det/total*100:.0f}%)" if total else "")

    # Mode classification accuracy
    detected_results = [r for r in results if r["detected"]]
    if detected_results:
        correct = sum(1 for r in detected_results if r["mode_correct"])
        print(f"\nMode classification: {correct}/{len(detected_results)} correct ({correct/len(detected_results)*100:.0f}%)")

    # Characters decoded
    total_chars = sum(r["chars_decoded"] for r in results)
    print(f"Total characters decoded: {total_chars}")

    # Per-mode chars
    for mode in modes:
        mode_chars = sum(r["chars_decoded"] for r in results if r["mode"] == mode)
        print(f"  {mode}: {mode_chars} chars")


def main():
    parser = argparse.ArgumentParser(description="Real-world decoder evaluation")
    parser.add_argument("--panoradio", default="panoradio", help="Panoradio dataset directory")
    parser.add_argument("--output", default="samples/panoradio_concat", help="Output directory for concatenated WAVs")
    parser.add_argument("--quick", action="store_true", help="Quick mode (fewer samples)")
    parser.add_argument("--concat-only", action="store_true", help="Only create concatenated WAVs, don't evaluate")
    args = parser.parse_args()

    # Load dataset
    npy_path = os.path.join(args.panoradio, "dataset_hf_radio.npy")
    tags_path = os.path.join(args.panoradio, "dataset_panoradio_hf_tags.csv")

    print("Loading tags...")
    tags = []
    with open(tags_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            tags.append({
                "idx": int(row.get(" idx", row.get("idx", "0")).strip()),
                "mode": row.get(" mode", row.get("mode", "")).strip(),
                "snr": int(row.get(" snr", row.get("snr", "0")).strip()),
            })

    print(f"Memory-mapping dataset...")
    data = np.load(npy_path, mmap_mode='r')

    # Create concatenated samples (~5 seconds each)
    count_per = 15  # 15 × 341ms ≈ 5.1 seconds
    num_concat = 1 if args.quick else 3

    print(f"\nCreating concatenated samples ({count_per} segments each, ~5s)...")
    manifest = create_concatenated_samples(data, tags, args.output, count_per, num_concat)
    print(f"Created {len(manifest)} concatenated WAV files")

    if args.concat_only:
        return

    # Evaluate
    core_dir = os.path.join(os.path.dirname(__file__), "..", "AmateurDigital", "AmateurDigitalCore")
    core_dir = os.path.abspath(core_dir)

    print(f"\nBuilding DecodeWAV...")
    subprocess.run(["swift", "build", "-c", "release"], cwd=core_dir, capture_output=True)

    print(f"\nEvaluating {len(manifest)} signals...\n")
    results = evaluate_decode(manifest, args.output, core_dir)

    print_summary(results)

    # Save results
    results_path = os.path.join(args.output, "eval_results.json")
    with open(results_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nDetailed results: {results_path}")


if __name__ == "__main__":
    main()
