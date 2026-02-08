#!/usr/bin/env python3
"""RTTY decoder using I/Q demodulation for precise mark/space detection."""

import sys
import wave
import numpy as np
from scipy.signal import butter, filtfilt, lfilter

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

def iq_demod(samples, sr, freq, lpf_cutoff):
    """I/Q demodulate to extract envelope at a specific frequency.

    Multiply by exp(-j*2*pi*f*t) to shift the target frequency to DC,
    then low-pass filter to get the envelope.
    """
    t = np.arange(len(samples)) / sr
    # Mix down to baseband
    iq = samples * np.exp(-1j * 2 * np.pi * freq * t)
    # Low-pass filter
    b, a = butter(4, lpf_cutoff / (sr / 2), btype='low')
    iq_filtered = lfilter(b, a, iq)
    return np.abs(iq_filtered)

def decode_baudot(correlations, sr, baud_rate, threshold=0.15):
    """Decode Baudot characters from a correlation stream.

    correlations: array of values at sample rate sr
    positive = mark (1), negative = space (0)
    """
    samples_per_bit = sr / baud_rate
    text = ""
    shift = 'letters'
    i = 0

    while i < len(correlations):
        # Wait for start bit (space = negative)
        if correlations[i] >= -threshold:
            i += 1
            continue

        start = i

        # Verify start bit at its center
        center_start = int(start + samples_per_bit * 0.5)
        if center_start >= len(correlations):
            break
        # Average over center 50% of start bit
        quarter = int(samples_per_bit * 0.25)
        lo = max(0, center_start - quarter)
        hi = min(len(correlations), center_start + quarter)
        if np.mean(correlations[lo:hi]) >= 0:
            # Not really a start bit
            i += 1
            continue

        # Sample 5 data bits at their centers
        bits = []
        for bit_n in range(5):
            center = int(start + (1.5 + bit_n) * samples_per_bit)
            if center >= len(correlations):
                break
            quarter = int(samples_per_bit * 0.25)
            lo = max(0, center - quarter)
            hi = min(len(correlations), center + quarter)
            avg = np.mean(correlations[lo:hi])
            bits.append(1 if avg > 0 else 0)

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

        # Advance past stop bits
        i = int(start + 7.5 * samples_per_bit)

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
    baud_rate = 45.45

    # I/Q demodulation: get envelope at mark and space frequencies
    # LPF cutoff should be narrow enough to reject the other tone
    # but wide enough to pass the baud rate transitions
    # The baud rate is 45.45 Hz, so we need at least ~50 Hz bandwidth
    # The tone separation is 169 Hz
    # A good cutoff is about half the shift: ~85 Hz
    lpf_cutoff = 80.0

    print(f"\nI/Q demodulation: mark={mark_freq}, space={space_freq}, LPF={lpf_cutoff} Hz")

    mark_env = iq_demod(samples, sr, mark_freq, lpf_cutoff)
    space_env = iq_demod(samples, sr, space_freq, lpf_cutoff)

    # Compute correlation at full sample rate
    total = mark_env + space_env
    correlation = np.where(total > 1e-10, (mark_env - space_env) / total, 0.0)

    print(f"Correlation range: [{correlation.min():.3f}, {correlation.max():.3f}]")
    print(f"Mean: {correlation.mean():.3f}")

    # Test decoding
    print(f"\n=== I/Q decode at {baud_rate} baud ===")
    text = decode_baudot(correlation, sr, baud_rate)
    printable = text.replace('\n', '\\n').replace('\r', '\\r')
    printable = ''.join(c if 32 <= ord(c) < 127 else '.' for c in printable)
    print(f"  Normal: {len(text):3d} chars: \"{printable[:300]}\"")

    # Inverted
    text_inv = decode_baudot(-correlation, sr, baud_rate)
    printable_inv = text_inv.replace('\n', '\\n').replace('\r', '\\r')
    printable_inv = ''.join(c if 32 <= ord(c) < 127 else '.' for c in printable_inv)
    print(f"  Invert: {len(text_inv):3d} chars: \"{printable_inv[:300]}\"")

    # Try different LPF cutoffs
    print(f"\n=== LPF cutoff sweep ===")
    for cutoff in [30, 40, 50, 60, 70, 80, 100, 120, 150]:
        me = iq_demod(samples, sr, mark_freq, cutoff)
        se = iq_demod(samples, sr, space_freq, cutoff)
        tot = me + se
        corr = np.where(tot > 1e-10, (me - se) / tot, 0.0)
        text = decode_baudot(corr, sr, baud_rate)
        text_inv = decode_baudot(-corr, sr, baud_rate)
        p = text.replace('\n', '\\n').replace('\r', '\\r')
        p = ''.join(c if 32 <= ord(c) < 127 else '.' for c in p)
        pi = text_inv.replace('\n', '\\n').replace('\r', '\\r')
        pi = ''.join(c if 32 <= ord(c) < 127 else '.' for c in pi)
        best = text if len(text) >= len(text_inv) else text_inv
        best_label = "N" if len(text) >= len(text_inv) else "I"
        bp = best.replace('\n', '\\n').replace('\r', '\\r')
        bp = ''.join(c if 32 <= ord(c) < 127 else '.' for c in bp)
        print(f"  LPF={cutoff:3d}Hz [{best_label}]: {len(best):3d} chars: \"{bp[:200]}\"")

    # Try sweeping mark frequency with best LPF
    print(f"\n=== Mark frequency sweep (LPF=80 Hz) ===")
    best_text = ""
    best_mark = 0
    for mark_offset in range(-30, 31, 2):
        mf = mark_freq + mark_offset
        sf = mf - 170.0  # standard shift
        me = iq_demod(samples, sr, mf, 80)
        se = iq_demod(samples, sr, sf, 80)
        tot = me + se
        corr = np.where(tot > 1e-10, (me - se) / tot, 0.0)
        text = decode_baudot(corr, sr, baud_rate)
        if len(text) > len(best_text):
            best_text = text
            best_mark = mf
        if len(text) > 50:
            p = text.replace('\n', '\\n').replace('\r', '\\r')
            p = ''.join(c if 32 <= ord(c) < 127 else '.' for c in p)
            print(f"  Mark={mf:.1f}: {len(text):3d} chars: \"{p[:150]}\"")

    # Best result
    print(f"\n=== Best I/Q decode ===")
    mf = best_mark
    sf = mf - 170.0
    me = iq_demod(samples, sr, mf, 80)
    se = iq_demod(samples, sr, sf, 80)
    tot = me + se
    corr = np.where(tot > 1e-10, (me - se) / tot, 0.0)
    text = decode_baudot(corr, sr, baud_rate)
    p = text.replace('\n', '\\n').replace('\r', '\\r')
    p = ''.join(c if 32 <= ord(c) < 127 else '.' for c in p)
    print(f"Mark={mf:.1f}, Space={sf:.1f}, LPF=80Hz, Baud=45.45:")
    print(f"  {len(text):3d} chars: \"{p}\"")

    # Also try the second signal at ~3000 Hz
    print(f"\n=== Second signal (mark ≈ 3000 Hz) ===")
    for mf2 in [2980, 2990, 2997, 3000, 3010]:
        sf2 = mf2 - 170.0
        me2 = iq_demod(samples, sr, mf2, 80)
        se2 = iq_demod(samples, sr, sf2, 80)
        tot2 = me2 + se2
        corr2 = np.where(tot2 > 1e-10, (me2 - se2) / tot2, 0.0)
        text2 = decode_baudot(corr2, sr, baud_rate)
        text2_inv = decode_baudot(-corr2, sr, baud_rate)
        for label, t in [("N", text2), ("I", text2_inv)]:
            if len(t) > 3:
                p2 = t.replace('\n', '\\n').replace('\r', '\\r')
                p2 = ''.join(c if 32 <= ord(c) < 127 else '.' for c in p2)
                print(f"  Mark={mf2} [{label}]: {len(t):3d} chars: \"{p2[:200]}\"")

if __name__ == '__main__':
    main()
