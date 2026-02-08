#!/usr/bin/env python3
"""RTTY decoder with proper bit clock recovery (PLL) for accurate decoding."""

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

def compute_correlation_stream(samples, sr, mark_freq, space_freq, block_size):
    """Compute mark/space correlation for each small block of samples."""
    n_blocks = len(samples) // block_size
    correlations = np.zeros(n_blocks)
    magnitudes = np.zeros(n_blocks)

    for i in range(n_blocks):
        chunk = samples[i*block_size:(i+1)*block_size]
        N = len(chunk)

        # Goertzel for mark
        k_m = round(N * mark_freq / sr)
        w_m = 2 * np.pi * k_m / N
        coeff_m = 2 * np.cos(w_m)
        s1m, s2m = 0.0, 0.0
        for x in chunk:
            s0 = x + coeff_m * s1m - s2m
            s2m = s1m
            s1m = s0
        mp = s1m*s1m + s2m*s2m - coeff_m*s1m*s2m

        # Goertzel for space
        k_s = round(N * space_freq / sr)
        w_s = 2 * np.pi * k_s / N
        coeff_s = 2 * np.cos(w_s)
        s1s, s2s = 0.0, 0.0
        for x in chunk:
            s0 = x + coeff_s * s1s - s2s
            s2s = s1s
            s1s = s0
        sp = s1s*s1s + s2s*s2s - coeff_s*s1s*s2s

        total = mp + sp
        if total > 1e-10:
            correlations[i] = (mp - sp) / total
            magnitudes[i] = total
        else:
            correlations[i] = 0
            magnitudes[i] = 0

    return correlations, magnitudes

def decode_with_pll(correlations, blocks_per_bit, baud_rate):
    """Decode RTTY using a PLL-based bit clock recovery.

    The PLL tracks the bit transitions to maintain synchronization.
    """
    threshold = 0.15

    # PLL state
    bit_phase = 0.0       # 0.0 to 1.0, wraps at 1.0
    phase_inc = 1.0 / blocks_per_bit  # nominal phase increment per block
    pll_gain = 0.05       # phase correction gain

    # Decoder state
    state = 'idle'  # idle, start, data, stop
    bit_count = 0
    accumulator = 0
    shift = 'letters'
    text = ""
    prev_corr = 0.0
    min_confidence = 1.0

    # For debugging
    bit_decisions = []

    for i in range(len(correlations)):
        corr = correlations[i]

        # Detect transitions for PLL
        if (prev_corr > threshold and corr < -threshold) or \
           (prev_corr < -threshold and corr > threshold):
            # Transition detected
            # The transition should happen near bit_phase = 0.0
            # Adjust phase toward 0
            phase_error = bit_phase
            if phase_error > 0.5:
                phase_error -= 1.0
            bit_phase -= phase_error * pll_gain

        prev_corr = corr

        # Advance phase
        bit_phase += phase_inc
        if bit_phase < 0:
            bit_phase += 1.0

        # Sample at center of bit (phase = 0.5)
        if bit_phase >= 1.0:
            bit_phase -= 1.0

            # This is a bit sampling point
            bit_val = 1 if corr > 0 else 0  # mark=1, space=0
            confidence = abs(corr)

            if state == 'idle':
                if bit_val == 0:  # Start bit (space)
                    state = 'start_verify'
                    # We'll verify this is really a start bit at next sample
                    bit_count = 0
                    accumulator = 0
                    min_confidence = confidence

            elif state == 'start_verify':
                # The start bit should still be space at this point
                if bit_val == 0:
                    state = 'data'
                    bit_count = 0
                    accumulator = 0
                else:
                    state = 'idle'

            elif state == 'data':
                accumulator |= (bit_val << bit_count)
                min_confidence = min(min_confidence, confidence)
                bit_count += 1
                if bit_count >= 5:
                    state = 'stop'
                    bit_count = 0

            elif state == 'stop':
                # Expect mark (1) during stop bits
                bit_count += 1
                if bit_count >= 1:  # After 1 stop bit sample
                    # Decode character
                    code = accumulator & 0x1F
                    if code == 0x1F:
                        shift = 'letters'
                    elif code == 0x1B:
                        shift = 'figures'
                    else:
                        table = LETTERS if shift == 'letters' else FIGURES
                        ch = table[code]
                        if ch is not None:
                            text += ch
                            bit_decisions.append((i, code, ch, min_confidence))
                    state = 'idle'

    return text, bit_decisions

def decode_simple(correlations, blocks_per_bit, offset_blocks=0):
    """Simple decoder with fixed bit timing, starting from a given offset."""
    threshold = 0.15
    text = ""
    shift = 'letters'
    i = offset_blocks

    while i < len(correlations):
        # Wait for start bit
        if correlations[i] >= -threshold:
            i += 1
            continue

        start = i

        # Sample 5 data bits at their centers
        bits = []
        valid = True
        for bit_n in range(5):
            center = start + (1.5 + bit_n) * blocks_per_bit
            ci = int(center)
            if ci >= len(correlations):
                valid = False
                break
            # Average nearby blocks
            lo = max(0, ci - 1)
            hi = min(len(correlations), ci + 2)
            avg = np.mean(correlations[lo:hi])
            bits.append(1 if avg > 0 else 0)

        if not valid or len(bits) < 5:
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

        i = int(start + 7.5 * blocks_per_bit)

    return text

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

    # Block size must be large enough for Goertzel to resolve mark/space
    # Minimum: sr / shift ≈ 48000/170 ≈ 282 samples for one cycle difference
    # Use samplesPerBit / 4 like the Swift code, but ensure enough resolution
    baud_ref = 45.45
    block_size = max(256, int(sr / baud_ref / 4))  # ~264 samples at 45.45 baud
    correlations, magnitudes = compute_correlation_stream(
        samples, sr, mark_freq, space_freq, block_size
    )
    print(f"Computed {len(correlations)} correlation blocks ({block_size} samples/block, {block_size/sr*1000:.1f}ms/block)")

    # Test with different baud rates using PLL decoder
    print("\n=== PLL-based decoder sweep ===")
    for baud in [45.0, 45.45, 45.5, 46.0, 47.0, 48.0, 48.5, 49.0, 50.0]:
        blocks_per_bit = sr / baud / block_size
        text, decisions = decode_with_pll(correlations, blocks_per_bit, baud)
        printable = text.replace('\n', '\\n').replace('\r', '\\r')
        printable = ''.join(c if 32 <= ord(c) < 127 else '.' for c in printable)
        print(f"  Baud {baud:5.1f}: {len(text):3d} chars: \"{printable[:180]}\"")

    # Also test simple decoder with finer block size
    print("\n=== Simple decoder with 1ms blocks ===")
    for baud in [45.0, 45.45, 45.5, 46.0, 47.0, 48.0, 48.5, 49.0, 50.0]:
        blocks_per_bit = sr / baud / block_size
        text = decode_simple(correlations, blocks_per_bit)
        printable = text.replace('\n', '\\n').replace('\r', '\\r')
        printable = ''.join(c if 32 <= ord(c) < 127 else '.' for c in printable)
        print(f"  Baud {baud:5.1f}: {len(text):3d} chars: \"{printable[:180]}\"")

    # Use the best baud rate and dump full decoded text
    best_baud = 45.45
    blocks_per_bit = sr / best_baud / block_size
    print(f"\n=== Full decode at {best_baud} baud with PLL ===")
    text, decisions = decode_with_pll(correlations, blocks_per_bit, best_baud)
    printable = text.replace('\n', '\\n').replace('\r', '\\r')
    printable = ''.join(c if 32 <= ord(c) < 127 else '.' for c in printable)
    print(f"Full text ({len(text)} chars):")
    print(f"  \"{printable}\"")

    # Dump the correlation trace around the "CQ" region
    # Find where signal strength is highest
    print(f"\n=== Signal strength analysis ===")
    window = int(sr / block_size)  # 1-second windows
    for sec in range(int(len(correlations) * block_size / sr)):
        start = sec * window
        end = min(start + window, len(correlations))
        if end <= start:
            break
        seg_mag = magnitudes[start:end]
        seg_corr = correlations[start:end]
        avg_mag = np.mean(seg_mag)
        mark_pct = np.mean(seg_corr > 0.2) * 100
        space_pct = np.mean(seg_corr < -0.2) * 100
        noise_pct = np.mean(np.abs(seg_corr) <= 0.2) * 100
        print(f"  t={sec:2d}s: avg_mag={avg_mag:.1f}, mark={mark_pct:.0f}%, space={space_pct:.0f}%, noise={noise_pct:.0f}%")

if __name__ == '__main__':
    main()
