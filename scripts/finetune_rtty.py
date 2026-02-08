#!/usr/bin/env python3
"""Fine-tune RTTY decode parameters to find best baud rate and frequencies."""

import sys
import wave
import numpy as np
import re

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

def goertzel_power(samples, freq, sr):
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
    samples_per_bit = sr / baud_rate
    block_size = max(64, int(samples_per_bit / 4))
    n_blocks = len(samples) // block_size
    correlations = np.zeros(n_blocks)

    for i in range(n_blocks):
        chunk = samples[i*block_size:(i+1)*block_size]
        mark_power = goertzel_power(chunk, mark_freq, sr)
        space_power = goertzel_power(chunk, space_freq, sr)
        total = mark_power + space_power
        if total > 1e-10:
            correlations[i] = (mark_power - space_power) / total
        if invert:
            correlations[i] = -correlations[i]

    blocks_per_bit = samples_per_bit / block_size
    threshold = 0.2

    text = ""
    shift = 'letters'
    i = 0

    while i < len(correlations):
        if correlations[i] >= -threshold:
            i += 1
            continue

        start_block = i
        end_start = int(start_block + blocks_per_bit)
        if end_start >= len(correlations):
            break

        start_samples = correlations[start_block:end_start]
        if np.mean(start_samples < 0) < 0.5:
            i += 1
            continue

        bits = []
        for bit_n in range(5):
            center = start_block + (1.5 + bit_n) * blocks_per_bit
            center_idx = int(center)
            if center_idx >= len(correlations):
                break
            avg_start = max(0, center_idx - 1)
            avg_end = min(len(correlations), center_idx + 2)
            avg_corr = np.mean(correlations[avg_start:avg_end])
            bits.append(1 if avg_corr > 0 else 0)

        if len(bits) < 5:
            break

        code = 0
        for bit_n, bit_val in enumerate(bits):
            code |= (bit_val << bit_n)

        if code == 0x1F:
            shift = 'letters'
        elif code == 0x1B:
            shift = 'figures'
        else:
            table = LETTERS if shift == 'letters' else FIGURES
            ch = table[code]
            if ch is not None:
                text += ch

        i = int(start_block + 7.5 * blocks_per_bit)

    return text

def score_text(text):
    """Score decoded text - higher = more likely to be real RTTY."""
    if len(text) < 5:
        return 0

    # Count common ham radio patterns
    score = 0
    upper = text.upper()

    # Look for callsign-like patterns
    callsigns = re.findall(r'[A-Z0-9]{1,2}[0-9][A-Z]{1,3}', upper)
    score += len(callsigns) * 20

    # Look for common ham radio words/sequences
    ham_words = ['CQ', 'DE', 'RST', 'UR', 'QTH', 'QSL', 'QRZ', 'BK', 'KN', 'SK',
                 'NAME', 'OP', 'RIG', 'ANT', 'WX', 'HR', 'HW', 'CPY', 'PSE',
                 'AGN', 'FB', 'ES', 'TNX', 'TU', 'BTU']
    for word in ham_words:
        if word in upper:
            score += 10

    # Consecutive real words (3+ letters that are actual words)
    words = re.findall(r'[A-Z]{2,}', upper)
    score += len(words)

    # Penalty for too many figure characters in a row
    fig_runs = re.findall(r'[0-9!@#$%^&*()\-+=:;,.<>?/]{5,}', text)
    score -= len(fig_runs) * 5

    # Ratio of letters vs figures (RTTY text is mostly letters)
    letters = sum(1 for c in text if c.isalpha())
    score += int(letters / max(1, len(text)) * 20)

    return score

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <wav_file>")
        sys.exit(1)

    path = sys.argv[1]
    samples, sr = read_wav(path)
    print(f"File: {path}")
    print(f"Sample rate: {sr} Hz, Duration: {len(samples)/sr:.1f}s\n")

    # Sweep baud rate from 40-55 in fine steps
    print("=== Baud Rate Sweep (40-55, mark=1188, space=1019) ===")
    results = []

    for baud_x10 in range(400, 551, 5):
        baud = baud_x10 / 10.0
        text = decode_rtty(samples, sr, 1187.5, 1018.5, baud)
        s = score_text(text)
        results.append((baud, text, s))

    results.sort(key=lambda x: -x[2])
    for baud, text, s in results[:10]:
        printable = text.replace('\n', '\\n').replace('\r', '\\r')
        printable = ''.join(c if 32 <= ord(c) < 127 else '.' for c in printable)
        print(f"  Baud {baud:5.1f}: score={s:3d}, chars={len(text):3d}: \"{printable[:120]}\"")

    # Sweep mark frequency with best baud rate
    best_baud = results[0][0]
    print(f"\n=== Frequency Sweep (mark=1100-1280 Hz, baud={best_baud}) ===")
    results2 = []

    for mark_x10 in range(11000, 12800, 10):
        mark = mark_x10 / 10.0
        space = mark - 170.0
        text = decode_rtty(samples, sr, mark, space, best_baud)
        s = score_text(text)
        results2.append((mark, space, text, s))

    results2.sort(key=lambda x: -x[3])
    for mark, space, text, s in results2[:10]:
        printable = text.replace('\n', '\\n').replace('\r', '\\r')
        printable = ''.join(c if 32 <= ord(c) < 127 else '.' for c in printable)
        print(f"  Mark={mark:.0f}/Space={space:.0f}: score={s:3d}, chars={len(text):3d}: \"{printable[:120]}\"")

    # Final best decode with optimal parameters
    best_mark = results2[0][0]
    best_space = results2[0][1]
    print(f"\n=== Best decode: mark={best_mark:.1f}, space={best_space:.1f}, baud={best_baud} ===")

    # Also try with inverted polarity
    text_normal = decode_rtty(samples, sr, best_mark, best_space, best_baud, invert=False)
    text_invert = decode_rtty(samples, sr, best_mark, best_space, best_baud, invert=True)

    for label, text in [("Normal", text_normal), ("Inverted", text_invert)]:
        printable = text.replace('\n', '\\n').replace('\r', '\\r')
        printable = ''.join(c if 32 <= ord(c) < 127 else '.' for c in printable)
        s = score_text(text)
        print(f"\n{label} (score={s}):")
        print(f"  \"{printable}\"")

    # Try again with a wider baud range around the best
    print(f"\n=== Ultra-fine baud sweep ({best_baud-2:.1f} to {best_baud+2:.1f}, step 0.1) ===")
    results3 = []
    for baud_x100 in range(int((best_baud-2)*100), int((best_baud+2)*100+1), 10):
        baud = baud_x100 / 100.0
        text = decode_rtty(samples, sr, best_mark, best_space, baud)
        s = score_text(text)
        results3.append((baud, text, s))

    results3.sort(key=lambda x: -x[2])
    for baud, text, s in results3[:5]:
        printable = text.replace('\n', '\\n').replace('\r', '\\r')
        printable = ''.join(c if 32 <= ord(c) < 127 else '.' for c in printable)
        print(f"  Baud {baud:6.2f}: score={s:3d}, chars={len(text):3d}: \"{printable[:150]}\"")

if __name__ == '__main__':
    main()
