#!/usr/bin/env python3
"""Generate a text-based spectrogram to visualize RTTY FSK tones."""

import sys
import wave
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
    elif sw == 4:
        samples = np.frombuffer(raw, dtype=np.int32).astype(np.float64) / 2147483648.0
    else:
        raise ValueError(f"Unsupported sample width: {sw}")
    if nch > 1:
        samples = samples.reshape(-1, nch).mean(axis=1)
    return samples, sr

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <wav_file>")
        sys.exit(1)

    path = sys.argv[1]
    samples, sr = read_wav(path)
    print(f"Sample rate: {sr} Hz, Duration: {len(samples)/sr:.1f}s")

    # Spectrogram parameters
    window_ms = 20   # 20ms windows
    hop_ms = 10      # 10ms hop
    window_size = int(sr * window_ms / 1000)
    hop_size = int(sr * hop_ms / 1000)

    # Frequency range of interest
    freq_min = 200
    freq_max = 3500

    # Compute spectrogram
    n_frames = (len(samples) - window_size) // hop_size
    freqs = np.fft.rfftfreq(window_size, 1.0 / sr)
    freq_mask = (freqs >= freq_min) & (freqs <= freq_max)
    masked_freqs = freqs[freq_mask]

    spectrogram = np.zeros((n_frames, np.sum(freq_mask)))
    window = np.hanning(window_size)

    for i in range(n_frames):
        start = i * hop_size
        chunk = samples[start:start + window_size] * window
        spectrum = np.abs(np.fft.rfft(chunk))
        spectrogram[i] = spectrum[freq_mask]

    # Convert to dB
    spectrogram_db = 20 * np.log10(spectrogram + 1e-10)

    # Find peak frequency per time frame
    peak_freqs = masked_freqs[np.argmax(spectrogram, axis=1)]

    # Print summary of peak frequencies over time
    print(f"\n=== Peak Frequency Over Time (first 5 seconds) ===")
    n_show = min(n_frames, int(5000 / hop_ms))
    for i in range(0, n_show, 5):  # every 50ms
        t = i * hop_ms / 1000
        pf = peak_freqs[i]
        # Also find top 3 peaks
        top3_idx = np.argsort(spectrogram[i])[-3:][::-1]
        top3 = [(masked_freqs[j], spectrogram_db[i][j]) for j in top3_idx]
        bar = "#" * int(max(0, (spectrogram_db[i][np.argmax(spectrogram[i])] + 60)) / 2)
        print(f"  t={t:5.2f}s  peak={pf:7.1f} Hz  top3: {top3[0][0]:.0f}({top3[0][1]:.0f}dB) {top3[1][0]:.0f}({top3[1][1]:.0f}dB) {top3[2][0]:.0f}({top3[2][1]:.0f}dB)")

    # Aggregate: average spectrum across all frames
    avg_spectrum = np.mean(spectrogram_db, axis=0)
    print(f"\n=== Average Spectrum (top 20 peaks) ===")
    # Find local maxima in average spectrum
    peaks = []
    for i in range(2, len(avg_spectrum) - 2):
        if (avg_spectrum[i] > avg_spectrum[i-1] and
            avg_spectrum[i] > avg_spectrum[i+1] and
            avg_spectrum[i] > avg_spectrum[i-2] and
            avg_spectrum[i] > avg_spectrum[i+2]):
            peaks.append((masked_freqs[i], avg_spectrum[i]))
    peaks.sort(key=lambda x: -x[1])
    for freq, db in peaks[:20]:
        print(f"  {freq:7.1f} Hz: {db:6.1f} dB")

    # Histogram of peak frequencies
    print(f"\n=== Peak Frequency Histogram ===")
    # Bin into 10 Hz bins
    bin_size = 10
    bins = {}
    for pf in peak_freqs:
        b = round(pf / bin_size) * bin_size
        bins[b] = bins.get(b, 0) + 1
    sorted_bins = sorted(bins.items(), key=lambda x: -x[1])
    print(f"Top frequency bins ({bin_size} Hz resolution):")
    for freq, count in sorted_bins[:20]:
        pct = count / len(peak_freqs) * 100
        bar = "#" * int(pct)
        print(f"  {freq:7.0f} Hz: {count:5d} ({pct:5.1f}%) {bar}")

    # Look for toggling between two frequencies (FSK signature)
    print(f"\n=== FSK Tone Detection ===")
    # Use Goertzel-like approach: test many frequency pairs
    # For each candidate mark frequency, test common shifts
    shifts = [170, 200, 425, 450, 850]

    best_pairs = []
    test_freqs = np.arange(300, 3200, 5)

    for mark_f in test_freqs:
        for shift in shifts:
            space_f = mark_f - shift
            if space_f < 200:
                continue

            # Compute Goertzel energy for both frequencies across all time frames
            mark_idx = np.argmin(np.abs(masked_freqs - mark_f))
            space_idx = np.argmin(np.abs(masked_freqs - space_f))

            mark_energy = spectrogram[:, mark_idx]
            space_energy = spectrogram[:, space_idx]

            # FSK signature: when one is high, the other should be low
            # Compute anti-correlation
            both = mark_energy + space_energy
            active_mask = both > np.percentile(both, 50)

            if np.sum(active_mask) < 10:
                continue

            me = mark_energy[active_mask]
            se = space_energy[active_mask]

            # Normalize
            me_n = (me - me.mean()) / (me.std() + 1e-10)
            se_n = (se - se.mean()) / (se.std() + 1e-10)

            # Anti-correlation (negative correlation = good FSK)
            corr = np.mean(me_n * se_n)

            # Also check that both frequencies have significant energy
            combined_energy = np.mean(both[active_mask])

            if corr < -0.3 and combined_energy > 0:
                best_pairs.append((mark_f, space_f, shift, corr, combined_energy))

    best_pairs.sort(key=lambda x: x[3])  # Most anti-correlated first

    if best_pairs:
        print(f"Best FSK pairs (anti-correlation, more negative = better):")
        seen = set()
        count = 0
        for mark_f, space_f, shift, corr, energy in best_pairs:
            # Deduplicate nearby frequencies
            key = (round(mark_f/20)*20, shift)
            if key in seen:
                continue
            seen.add(key)
            print(f"  Mark={mark_f:.0f} Hz, Space={space_f:.0f} Hz, Shift={shift} Hz, corr={corr:.3f}, energy={energy:.1f}")
            count += 1
            if count >= 15:
                break
    else:
        print("  No strong FSK pairs detected with standard shifts.")
        print("  Trying arbitrary shifts (50-1000 Hz)...")

        for mark_f in np.arange(500, 3200, 20):
            for space_f in np.arange(max(200, mark_f - 1000), mark_f - 50, 20):
                mark_idx = np.argmin(np.abs(masked_freqs - mark_f))
                space_idx = np.argmin(np.abs(masked_freqs - space_f))

                mark_energy = spectrogram[:, mark_idx]
                space_energy = spectrogram[:, space_idx]

                both = mark_energy + space_energy
                active_mask = both > np.percentile(both, 50)

                if np.sum(active_mask) < 10:
                    continue

                me = mark_energy[active_mask]
                se = space_energy[active_mask]

                me_n = (me - me.mean()) / (me.std() + 1e-10)
                se_n = (se - se.mean()) / (se.std() + 1e-10)

                corr = np.mean(me_n * se_n)
                combined_energy = np.mean(both[active_mask])

                if corr < -0.5:
                    shift = mark_f - space_f
                    best_pairs.append((mark_f, space_f, shift, corr, combined_energy))

        best_pairs.sort(key=lambda x: x[3])
        if best_pairs:
            print(f"  Found pairs with arbitrary shifts:")
            seen = set()
            count = 0
            for mark_f, space_f, shift, corr, energy in best_pairs:
                key = (round(mark_f/30)*30, round(shift/30)*30)
                if key in seen:
                    continue
                seen.add(key)
                print(f"    Mark={mark_f:.0f} Hz, Space={space_f:.0f} Hz, Shift={shift:.0f} Hz, corr={corr:.3f}")
                count += 1
                if count >= 15:
                    break

if __name__ == '__main__':
    main()
