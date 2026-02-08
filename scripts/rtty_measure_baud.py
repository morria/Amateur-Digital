#!/usr/bin/env python3
"""Precisely measure RTTY baud rate from actual bit transitions and test decoding."""

import sys
import wave
import numpy as np

# ITA2 Baudot tables
LETTERS = [
    None,  'E', '\n', 'A', ' ',  'S', 'I', 'U',
    '\r',  'D', 'R',  'J', 'N',  'F', 'C', 'K',
    'T',   'Z', 'L',  'W', 'H',  'Y', 'P', 'Q',
    'O',   'B', 'G',  None,'M',  'X', 'V', None,
]
FIGURES = [
    None,  '3', '\n', '-', ' ',  "'", '8', '7',
    '\r',  '$', '4',  '\x07', ',', '!', ':', '(',
    '5',   '+', ')',  '2', '#',  '6', '0', '1',
    '9',   '?', '&',  None,'.', '/', ';', None,
]

def read_wav(path):
    with wave.open(path, 'rb') as w:
        nch = w.getnchannels()
        sw = w.getsampwidth()
        sr = w.getframerate()
        nf = w.getnframes()
        raw = w.readframes(nf)
    if sw == 2:
        samples = np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0
    elif sw == 4:
        samples = np.frombuffer(raw, dtype=np.int32).astype(np.float64) / 2147483648.0
    else:
        raise ValueError(f"Unsupported sample width: {sw}")
    if nch > 1:
        samples = samples.reshape(-1, nch).mean(axis=1)
    return samples, sr

def sliding_goertzel(samples, sr, freq, block_size, hop_size):
    """Compute Goertzel power in overlapping blocks."""
    n_blocks = (len(samples) - block_size) // hop_size + 1
    powers = np.zeros(n_blocks)

    N = block_size
    k = round(N * freq / sr)
    w = 2 * np.pi * k / N
    coeff = 2 * np.cos(w)

    for i in range(n_blocks):
        start = i * hop_size
        chunk = samples[start:start+N]
        s1, s2 = 0.0, 0.0
        for x in chunk:
            s0 = x + coeff * s1 - s2
            s2 = s1
            s1 = s0
        powers[i] = s1*s1 + s2*s2 - coeff*s1*s2

    return powers

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <wav_file>")
        sys.exit(1)

    path = sys.argv[1]
    samples, sr = read_wav(path)
    print(f"File: {path}")
    print(f"Sample rate: {sr} Hz, Duration: {len(samples)/sr:.1f}s")

    mark_freq = 1187.5
    space_freq = 1018.5

    # Use longer block for better frequency resolution
    # Block size should be at least 2*sr/shift for good discrimination
    block_size = int(sr / 170 * 2)  # ~565 samples ≈ 11.8ms
    hop_size = 24  # 0.5ms hop for fine time resolution

    print(f"\nGoertzel block_size={block_size} ({block_size/sr*1000:.1f}ms)")
    print(f"Hop size={hop_size} ({hop_size/sr*1000:.1f}ms)")

    mark_power = sliding_goertzel(samples, sr, mark_freq, block_size, hop_size)
    space_power = sliding_goertzel(samples, sr, space_freq, block_size, hop_size)

    total = mark_power + space_power
    correlation = np.where(total > 1e-10, (mark_power - space_power) / total, 0.0)

    print(f"Correlation range: [{correlation.min():.3f}, {correlation.max():.3f}]")
    print(f"Mean: {correlation.mean():.3f}, Std: {correlation.std():.3f}")

    # Threshold to binary
    threshold = 0.0  # Use 0 threshold for cleaner transitions
    binary = (correlation > threshold).astype(float)

    # Find transitions (mark→space and space→mark)
    transitions = np.diff(binary)
    transition_indices = np.where(transitions != 0)[0]

    if len(transition_indices) < 2:
        print("Too few transitions!")
        return

    # Time between transitions (in samples)
    intervals = np.diff(transition_indices) * hop_size  # in samples

    # Convert to ms
    intervals_ms = intervals / sr * 1000.0

    print(f"\nTransitions: {len(transition_indices)}")
    print(f"Interval stats (ms):")
    print(f"  Min: {intervals_ms.min():.1f}")
    print(f"  5th percentile: {np.percentile(intervals_ms, 5):.1f}")
    print(f"  10th percentile: {np.percentile(intervals_ms, 10):.1f}")
    print(f"  25th percentile: {np.percentile(intervals_ms, 25):.1f}")
    print(f"  Median: {np.median(intervals_ms):.1f}")
    print(f"  Mean: {np.mean(intervals_ms):.1f}")

    # Histogram of intervals
    print(f"\nInterval histogram (1ms bins):")
    bins = np.arange(0, 200, 1)
    hist, edges = np.histogram(intervals_ms, bins=bins)
    for i in range(len(hist)):
        if hist[i] > 0:
            bar = "#" * min(80, hist[i])
            print(f"  {edges[i]:5.0f}-{edges[i+1]:5.0f}ms: {hist[i]:4d} {bar}")

    # For RTTY at 45.45 baud: bit period = 22.0ms
    # Intervals should cluster at multiples of the bit period
    # The shortest intervals = 1 bit
    # Find the fundamental period using autocorrelation of intervals
    print(f"\n=== Baud rate estimation ===")
    for baud in [45.0, 45.45, 46.0, 47.0, 48.0, 49.0, 50.0]:
        bit_ms = 1000.0 / baud
        # Check how well intervals align to multiples of bit_ms
        # Quantize each interval to nearest bit count
        bit_counts = np.round(intervals_ms / bit_ms)
        expected_ms = bit_counts * bit_ms
        errors = np.abs(intervals_ms - expected_ms)
        rms_error = np.sqrt(np.mean(errors**2))
        # Only count intervals that are 1-10 bits
        valid = (bit_counts >= 1) & (bit_counts <= 10)
        if valid.sum() > 0:
            rms_error_valid = np.sqrt(np.mean(errors[valid]**2))
        else:
            rms_error_valid = 999
        print(f"  Baud {baud:5.1f} (bit={bit_ms:.2f}ms): RMS error={rms_error_valid:.2f}ms, valid intervals={valid.sum()}/{len(intervals)}")

    # Focus on the strong signal region (t=0-11s based on signal strength analysis)
    print(f"\n=== Focused analysis on strong signal (t=0-11s) ===")
    max_block = int(11.0 * sr / hop_size)
    strong_transitions = transition_indices[transition_indices < max_block]
    if len(strong_transitions) < 2:
        print("Too few transitions in strong region")
    else:
        strong_intervals = np.diff(strong_transitions) * hop_size / sr * 1000.0
        print(f"Transitions in strong region: {len(strong_transitions)}")
        print(f"Interval stats (ms):")
        print(f"  Min: {strong_intervals.min():.1f}")
        print(f"  5th percentile: {np.percentile(strong_intervals, 5):.1f}")
        print(f"  Median: {np.median(strong_intervals):.1f}")

        for baud in [45.0, 45.45, 46.0, 47.0, 48.0, 49.0, 50.0]:
            bit_ms = 1000.0 / baud
            bit_counts = np.round(strong_intervals / bit_ms)
            expected_ms = bit_counts * bit_ms
            errors = np.abs(strong_intervals - expected_ms)
            valid = (bit_counts >= 1) & (bit_counts <= 10)
            if valid.sum() > 0:
                rms_error = np.sqrt(np.mean(errors[valid]**2))
            else:
                rms_error = 999
            print(f"  Baud {baud:5.1f}: RMS error={rms_error:.2f}ms, valid={valid.sum()}/{len(strong_intervals)}")

    # Now decode with better Goertzel (larger block) and the best baud rate
    print(f"\n=== Decoding with larger Goertzel block ===")

    for baud in [45.0, 45.45, 46.0, 48.5, 50.0]:
        text = decode_with_large_goertzel(samples, sr, mark_freq, space_freq, baud,
                                           block_size, hop_size, correlation)
        printable = text.replace('\n', '\\n').replace('\r', '\\r')
        printable = ''.join(c if 32 <= ord(c) < 127 else '.' for c in printable)
        print(f"  Baud {baud:5.2f}: {len(text):3d} chars: \"{printable[:200]}\"")

    # Try inverted polarity
    print(f"\n=== Inverted polarity ===")
    for baud in [45.0, 45.45, 48.5, 50.0]:
        text = decode_with_large_goertzel(samples, sr, mark_freq, space_freq, baud,
                                           block_size, hop_size, -correlation)
        printable = text.replace('\n', '\\n').replace('\r', '\\r')
        printable = ''.join(c if 32 <= ord(c) < 127 else '.' for c in printable)
        print(f"  Baud {baud:5.2f} INV: {len(text):3d} chars: \"{printable[:200]}\"")


def decode_with_large_goertzel(samples, sr, mark_freq, space_freq, baud_rate,
                                block_size, hop_size, correlation):
    """Decode RTTY using pre-computed correlation with fine time resolution."""
    samples_per_bit = sr / baud_rate
    hops_per_bit = samples_per_bit / hop_size
    threshold = 0.15

    text = ""
    shift = 'letters'
    i = 0

    while i < len(correlation):
        # Wait for start bit (space = negative correlation)
        if correlation[i] >= -threshold:
            i += 1
            continue

        start = i

        # Verify start bit persists for ~half a bit
        check_end = int(start + hops_per_bit * 0.5)
        if check_end >= len(correlation):
            break
        start_avg = np.mean(correlation[start:check_end])
        if start_avg >= -threshold:
            i += 1
            continue

        # Sample 5 data bits at their centers
        bits = []
        for bit_n in range(5):
            # Center of data bit = start + (1.0 + bit_n + 0.5) * hops_per_bit
            center = start + (1.5 + bit_n) * hops_per_bit
            ci = int(center)
            if ci >= len(correlation):
                break
            # Average over a window at bit center (±25% of bit period)
            half_window = max(1, int(hops_per_bit * 0.25))
            lo = max(0, ci - half_window)
            hi = min(len(correlation), ci + half_window + 1)
            avg_corr = np.mean(correlation[lo:hi])
            bits.append(1 if avg_corr > 0 else 0)

        if len(bits) < 5:
            break

        code = 0
        for bn, bv in enumerate(bits):
            code |= (bv << bn)

        if code == 0x1F:
            shift = 'letters'
        elif code == 0x1B:
            shift = 'figures'
        else:
            table = LETTERS if shift == 'letters' else FIGURES
            ch = table[code]
            if ch is not None:
                text += ch

        # Skip past character (7.5 bits from start)
        i = int(start + 7.5 * hops_per_bit)

    return text


if __name__ == '__main__':
    main()
