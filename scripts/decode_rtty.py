#!/usr/bin/env python3
"""Simple RTTY decoder to validate demodulation against the Swift implementation."""

import sys
import wave
import numpy as np
from collections import defaultdict

# ITA2 Baudot tables
LETTERS = [
    None,  'E', '\n', 'A', ' ',  'S', 'I', 'U',
    '\r',  'D', 'R',  'J', 'N',  'F', 'C', 'K',
    'T',   'Z', 'L',  'W', 'H',  'Y', 'P', 'Q',
    'O',   'B', 'G',  None,'M',  'X', 'V', None,  # 0x1B=FIGS, 0x1F=LTRS
]
FIGURES = [
    None,  '3', '\n', '-', ' ',  "'", '8', '7',
    '\r',  '$', '4',  '\x07', ',', '!', ':', '(',
    '5',   '+', ')',  '2', '#',  '6', '0', '1',
    '9',   '?', '&',  None,'.', '/', ';', None,  # 0x1B=FIGS, 0x1F=LTRS
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

def goertzel_power(samples, freq, sr):
    """Compute Goertzel power for a specific frequency."""
    N = len(samples)
    k = round(N * freq / sr)
    w = 2 * np.pi * k / N
    coeff = 2 * np.cos(w)
    s1, s2 = 0.0, 0.0
    for x in samples:
        s0 = x + coeff * s1 - s2
        s2 = s1
        s1 = s0
    return s1*s1 + s2*s2 - coeff*s1*s2

def decode_rtty(samples, sr, mark_freq, space_freq, baud_rate, invert=False):
    """Decode RTTY from audio samples.

    Args:
        samples: audio samples
        sr: sample rate
        mark_freq: mark frequency (Hz)
        space_freq: space frequency (Hz)
        baud_rate: baud rate
        invert: if True, swap mark/space polarity

    Returns:
        decoded text string
    """
    samples_per_bit = sr / baud_rate
    # Use 1/4 bit period for Goertzel block size
    block_size = max(64, int(samples_per_bit / 4))

    # Compute correlation for each block
    n_blocks = len(samples) // block_size
    correlations = []

    for i in range(n_blocks):
        chunk = samples[i*block_size:(i+1)*block_size]
        mark_power = goertzel_power(chunk, mark_freq, sr)
        space_power = goertzel_power(chunk, space_freq, sr)
        total = mark_power + space_power
        if total > 1e-10:
            corr = (mark_power - space_power) / total
        else:
            corr = 0.0
        if invert:
            corr = -corr
        correlations.append(corr)

    correlations = np.array(correlations)

    # State machine
    blocks_per_bit = samples_per_bit / block_size
    threshold = 0.2

    text = ""
    shift = 'letters'  # letters or figures

    i = 0
    while i < len(correlations):
        # Wait for start bit (space = negative correlation)
        if correlations[i] >= -threshold:
            i += 1
            continue

        # Found potential start bit
        start_block = i

        # Verify start bit persists for most of the bit period
        valid_start = True
        end_start = int(start_block + blocks_per_bit)
        if end_start >= len(correlations):
            break

        # Check that the start bit is mostly space
        start_samples = correlations[start_block:end_start]
        if np.mean(start_samples < 0) < 0.5:
            i += 1
            continue

        # Sample 5 data bits at their centers
        bits = []
        for bit_n in range(5):
            # Center of bit: start + (1 + bit_n + 0.5) * blocks_per_bit
            center = start_block + (1.5 + bit_n) * blocks_per_bit
            center_idx = int(center)
            if center_idx >= len(correlations):
                break

            # Average a few blocks around center for noise resilience
            avg_start = max(0, center_idx - 1)
            avg_end = min(len(correlations), center_idx + 2)
            avg_corr = np.mean(correlations[avg_start:avg_end])

            bits.append(1 if avg_corr > 0 else 0)

        if len(bits) < 5:
            break

        # Assemble Baudot code (LSB first)
        code = 0
        for bit_n, bit_val in enumerate(bits):
            code |= (bit_val << bit_n)

        # Decode character
        if code == 0x1F:  # LTRS
            shift = 'letters'
        elif code == 0x1B:  # FIGS
            shift = 'figures'
        else:
            table = LETTERS if shift == 'letters' else FIGURES
            ch = table[code]
            if ch is not None:
                text += ch

        # Skip past stop bits (1.5 bit periods)
        i = int(start_block + 7.5 * blocks_per_bit)

    return text

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <wav_file>")
        sys.exit(1)

    path = sys.argv[1]
    samples, sr = read_wav(path)
    print(f"File: {path}")
    print(f"Sample rate: {sr} Hz, Duration: {len(samples)/sr:.1f}s")

    # From our analysis: Mark=1187.5 Hz, Space=1018.5 Hz
    mark_freq = 1187.5
    space_freq = 1018.5

    # Test different combinations
    test_configs = [
        # (mark, space, baud, invert, label)
        (mark_freq, space_freq, 45.45, False, "Standard (mark=1188, space=1019, 45.45 baud)"),
        (mark_freq, space_freq, 45.45, True,  "Inverted (mark=1188, space=1019, 45.45 baud, INV)"),
        (space_freq, mark_freq, 45.45, False, "Swapped (mark=1019, space=1188, 45.45 baud)"),
        (mark_freq, space_freq, 50.0, False,  "50 baud (mark=1188, space=1019)"),
        (mark_freq, space_freq, 50.0, True,   "50 baud inverted (mark=1188, space=1019, INV)"),
        (mark_freq, space_freq, 75.0, False,  "75 baud (mark=1188, space=1019)"),
        (mark_freq, space_freq, 75.0, True,   "75 baud inverted"),
        (mark_freq, space_freq, 100.0, False, "100 baud (mark=1188, space=1019)"),
        (mark_freq, space_freq, 100.0, True,  "100 baud inverted"),
        # Also try 2997/2828 (second signal from our analysis)
        (2997.0, 2828.0, 45.45, False, "Signal 2: mark=2997, space=2828, 45.45 baud"),
        (2997.0, 2828.0, 45.45, True,  "Signal 2: inverted"),
    ]

    for mark, space, baud, invert, label in test_configs:
        text = decode_rtty(samples, sr, mark, space, baud, invert)
        # Only show printable version
        printable = ""
        for c in text:
            if c == '\n':
                printable += "\\n"
            elif c == '\r':
                printable += "\\r"
            elif 32 <= ord(c) < 127:
                printable += c
            else:
                printable += "."

        # Count "word-like" sequences (3+ consecutive letters)
        import re
        words = re.findall(r'[A-Z]{3,}', text)
        word_chars = sum(len(w) for w in words)

        # Score: ratio of characters in word-like sequences
        word_score = word_chars / max(1, len(text)) * 100

        print(f"\n=== {label} ===")
        print(f"  Chars: {len(text)}, Word-like sequences: {len(words)}, Word score: {word_score:.0f}%")
        print(f"  Text: \"{printable[:200]}\"")
        if words:
            print(f"  Words: {' '.join(words[:20])}")

if __name__ == '__main__':
    main()
