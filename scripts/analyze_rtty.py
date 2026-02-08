#!/usr/bin/env python3
"""Analyze an RTTY WAV file to detect mark/space frequencies, shift, and baud rate."""

import sys
import wave
import struct
import numpy as np

def read_wav(path):
    with wave.open(path, 'rb') as w:
        nch = w.getnchannels()
        sw = w.getsampwidth()
        sr = w.getframerate()
        nf = w.getnframes()
        raw = w.readframes(nf)

    if sw == 2:
        samples = np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0
    elif sw == 1:
        samples = np.frombuffer(raw, dtype=np.uint8).astype(np.float64) / 128.0 - 1.0
    elif sw == 4:
        samples = np.frombuffer(raw, dtype=np.int32).astype(np.float64) / 2147483648.0
    else:
        raise ValueError(f"Unsupported sample width: {sw}")

    if nch > 1:
        samples = samples.reshape(-1, nch).mean(axis=1)

    return samples, sr

def analyze_spectrum(samples, sr):
    """Find dominant frequencies using FFT."""
    N = len(samples)
    # Use a window to reduce spectral leakage
    window = np.hanning(N)
    spectrum = np.abs(np.fft.rfft(samples * window))
    freqs = np.fft.rfftfreq(N, 1.0 / sr)

    # Focus on 200-4000 Hz range
    mask = (freqs >= 200) & (freqs <= 4000)
    spectrum = spectrum[mask]
    freqs = freqs[mask]

    # Convert to dB
    spectrum_db = 20 * np.log10(spectrum / spectrum.max() + 1e-10)

    # Find peaks (local maxima above -20 dB)
    threshold = -20
    peaks = []
    for i in range(1, len(spectrum_db) - 1):
        if (spectrum_db[i] > spectrum_db[i-1] and
            spectrum_db[i] > spectrum_db[i+1] and
            spectrum_db[i] > threshold):
            peaks.append((freqs[i], spectrum_db[i]))

    peaks.sort(key=lambda x: -x[1])
    return peaks[:20], freqs, spectrum_db

def analyze_baud_rate(samples, sr, mark_freq, space_freq):
    """Estimate baud rate by analyzing envelope transitions."""
    # Goertzel-like approach: compute mark and space energy in sliding windows
    window_ms = 5  # 5ms windows
    window_samples = int(sr * window_ms / 1000)
    hop = window_samples // 2

    mark_energy = []
    space_energy = []

    t_mark = 2 * np.pi * mark_freq / sr
    t_space = 2 * np.pi * space_freq / sr

    for start in range(0, len(samples) - window_samples, hop):
        chunk = samples[start:start + window_samples]
        n = np.arange(len(chunk))

        # Goertzel-style correlation
        me = np.abs(np.sum(chunk * np.exp(-1j * t_mark * n)))
        se = np.abs(np.sum(chunk * np.exp(-1j * t_space * n)))

        mark_energy.append(me)
        space_energy.append(se)

    mark_energy = np.array(mark_energy)
    space_energy = np.array(space_energy)

    # Compute correlation difference
    total = mark_energy + space_energy + 1e-10
    correlation = (mark_energy - space_energy) / total

    # Find zero crossings (transitions between mark and space)
    crossings = []
    for i in range(1, len(correlation)):
        if correlation[i-1] * correlation[i] < 0:
            crossings.append(i)

    if len(crossings) < 2:
        return None, correlation

    # Compute intervals between crossings
    intervals = np.diff(crossings) * (hop / sr)  # in seconds

    # The minimum interval should be roughly 1 bit period
    # Filter out very short intervals (noise)
    intervals = intervals[intervals > 0.005]  # > 5ms

    if len(intervals) == 0:
        return None, correlation

    # Histogram of intervals to find the fundamental bit period
    min_interval = np.percentile(intervals, 5)

    # Common RTTY baud rates and their bit periods
    baud_rates = {
        45.45: 1/45.45,
        50.0: 1/50.0,
        75.0: 1/75.0,
        100.0: 1/100.0,
    }

    print(f"\n  Transition analysis:")
    print(f"  Total transitions: {len(crossings)}")
    print(f"  Min interval: {min_interval*1000:.1f} ms")
    print(f"  Median interval: {np.median(intervals)*1000:.1f} ms")
    print(f"  Mean interval: {np.mean(intervals)*1000:.1f} ms")

    # Check which baud rate best matches
    best_baud = None
    best_score = float('inf')
    for baud, period in baud_rates.items():
        # Check if intervals are multiples of the bit period
        remainders = np.mod(intervals, period) / period
        remainders = np.minimum(remainders, 1 - remainders)  # distance to nearest multiple
        score = np.mean(remainders)
        print(f"  Baud {baud}: fit score {score:.4f} (lower=better), bit period={period*1000:.2f} ms")
        if score < best_score:
            best_score = score
            best_baud = baud

    return best_baud, correlation

def analyze_short_segments(samples, sr):
    """Analyze spectrum in short segments to find consistent tones."""
    segment_len = int(sr * 0.5)  # 500ms segments
    all_peaks = {}

    for start in range(0, len(samples) - segment_len, segment_len):
        segment = samples[start:start + segment_len]
        window = np.hanning(len(segment))
        spectrum = np.abs(np.fft.rfft(segment * window))
        freqs = np.fft.rfftfreq(len(segment), 1.0 / sr)

        mask = (freqs >= 200) & (freqs <= 4000)
        spectrum = spectrum[mask]
        freqs = freqs[mask]

        spectrum_db = 20 * np.log10(spectrum / spectrum.max() + 1e-10)

        # Find peaks
        for i in range(1, len(spectrum_db) - 1):
            if (spectrum_db[i] > spectrum_db[i-1] and
                spectrum_db[i] > spectrum_db[i+1] and
                spectrum_db[i] > -15):
                freq = round(freqs[i])
                if freq not in all_peaks:
                    all_peaks[freq] = 0
                all_peaks[freq] += 1

    # Sort by consistency (how many segments had this peak)
    n_segments = len(range(0, len(samples) - segment_len, segment_len))
    consistent = [(f, c, c/n_segments*100) for f, c in all_peaks.items() if c > n_segments * 0.1]
    consistent.sort(key=lambda x: -x[1])

    return consistent, n_segments

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <wav_file>")
        sys.exit(1)

    path = sys.argv[1]
    print(f"Reading: {path}")
    samples, sr = read_wav(path)
    print(f"Sample rate: {sr} Hz, Duration: {len(samples)/sr:.1f}s, Samples: {len(samples)}")

    # Full spectrum analysis
    print("\n=== Full Spectrum Analysis ===")
    peaks, freqs, spectrum_db = analyze_spectrum(samples, sr)
    print("Top peaks (frequency, dB):")
    for freq, db in peaks:
        print(f"  {freq:.1f} Hz: {db:.1f} dB")

    # Short segment analysis for consistency
    print("\n=== Segment Consistency Analysis (500ms segments) ===")
    consistent, n_seg = analyze_short_segments(samples, sr)
    print(f"Analyzed {n_seg} segments. Frequencies present in >10% of segments:")
    for freq, count, pct in consistent[:20]:
        print(f"  {freq} Hz: present in {count}/{n_seg} segments ({pct:.0f}%)")

    # Try to identify mark/space pairs
    print("\n=== Possible Mark/Space Pairs ===")
    top_freqs = [f for f, _, p in consistent if p > 30]
    common_shifts = [170, 200, 425, 450, 850]

    pairs = []
    for i, f1 in enumerate(top_freqs):
        for f2 in top_freqs[i+1:]:
            shift = abs(f2 - f1)
            for cs in common_shifts:
                if abs(shift - cs) < 20:
                    mark = max(f1, f2)
                    space = min(f1, f2)
                    pairs.append((mark, space, shift))

    if pairs:
        for mark, space, shift in pairs[:10]:
            print(f"  Mark={mark} Hz, Space={space} Hz, Shift={shift} Hz")
    else:
        print("  No standard shift pairs found. Checking all pairs within 100-1000 Hz...")
        for i, f1 in enumerate(top_freqs[:10]):
            for f2 in top_freqs[i+1:10]:
                shift = abs(f2 - f1)
                if 100 <= shift <= 1000:
                    print(f"  {max(f1,f2)} Hz / {min(f1,f2)} Hz = {shift} Hz shift")

    # Baud rate analysis using the two strongest consistent frequencies
    if len(consistent) >= 2:
        # Try top pair
        f1 = consistent[0][0]
        f2 = consistent[1][0]
        if abs(f1 - f2) < 50:  # Too close, try next
            if len(consistent) > 2:
                f2 = consistent[2][0]

        mark = max(f1, f2)
        space = min(f1, f2)
        shift = mark - space
        print(f"\n=== Baud Rate Analysis (using {mark}/{space} Hz, shift={shift} Hz) ===")
        baud, _ = analyze_baud_rate(samples, sr, mark, space)
        if baud:
            print(f"\n  Best matching baud rate: {baud}")

    # Also try with the most likely pair if found
    if pairs:
        mark, space, shift = pairs[0]
        print(f"\n=== Baud Rate Analysis (using best pair {mark}/{space} Hz, shift={shift} Hz) ===")
        baud, _ = analyze_baud_rate(samples, sr, mark, space)
        if baud:
            print(f"\n  Best matching baud rate: {baud}")

if __name__ == '__main__':
    main()
