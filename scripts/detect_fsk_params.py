#!/usr/bin/env python3
"""Precisely detect FSK parameters (mark freq, space freq, baud rate) from a WAV file."""

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

def goertzel(samples, freq, sr):
    """Compute Goertzel magnitude for a specific frequency."""
    N = len(samples)
    k = int(0.5 + N * freq / sr)
    w = 2 * np.pi * k / N
    coeff = 2 * np.cos(w)
    s0 = 0.0
    s1 = 0.0
    s2 = 0.0
    for x in samples:
        s0 = x + coeff * s1 - s2
        s2 = s1
        s1 = s0
    return np.sqrt(s1*s1 + s2*s2 - coeff*s1*s2) / N

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <wav_file>")
        sys.exit(1)

    path = sys.argv[1]
    samples, sr = read_wav(path)
    duration = len(samples) / sr
    print(f"File: {path}")
    print(f"Sample rate: {sr} Hz, Duration: {duration:.1f}s")

    # Step 1: High-resolution FFT of the full signal
    print("\n=== Step 1: High-Resolution FFT (1 Hz bins) ===")
    # Use 1-second chunks and average for ~1 Hz resolution
    chunk_size = sr  # 1 second = 1 Hz resolution
    n_chunks = int(len(samples) / chunk_size)
    avg_spectrum = None
    freqs = np.fft.rfftfreq(chunk_size, 1.0 / sr)

    for i in range(n_chunks):
        chunk = samples[i * chunk_size:(i+1) * chunk_size]
        window = np.hanning(len(chunk))
        spectrum = np.abs(np.fft.rfft(chunk * window))
        if avg_spectrum is None:
            avg_spectrum = spectrum
        else:
            avg_spectrum += spectrum
    avg_spectrum /= n_chunks

    # Focus on 500-3500 Hz
    mask = (freqs >= 500) & (freqs <= 3500)
    mf = freqs[mask]
    ms = avg_spectrum[mask]
    ms_db = 20 * np.log10(ms / ms.max() + 1e-10)

    # Find the top peaks with at least 20 Hz separation
    peaks = []
    for i in range(2, len(ms_db) - 2):
        if (ms_db[i] > ms_db[i-1] and ms_db[i] > ms_db[i+1] and
            ms_db[i] > ms_db[i-2] and ms_db[i] > ms_db[i+2] and
            ms_db[i] > -30):
            # Check minimum separation from existing peaks
            too_close = False
            for pf, _ in peaks:
                if abs(mf[i] - pf) < 20:
                    too_close = True
                    break
            if not too_close:
                peaks.append((mf[i], ms_db[i]))

    peaks.sort(key=lambda x: -x[1])
    print("Top frequency peaks (1 Hz resolution):")
    for freq, db in peaks[:15]:
        print(f"  {freq:8.1f} Hz: {db:6.1f} dB")

    # Step 2: Find the actual two FSK tones using sliding window Goertzel
    print("\n=== Step 2: Sliding Window FSK Tone Detection ===")
    # Use 50ms windows with Goertzel for precise frequency tracking
    window_ms = 50
    window_size = int(sr * window_ms / 1000)
    hop_size = window_size // 2

    # Test frequencies 1 Hz apart in the range 500-3500 Hz
    test_freqs = np.arange(500, 3500, 2)

    # Compute energy at each test frequency for each window
    n_windows = (len(samples) - window_size) // hop_size
    print(f"Testing {len(test_freqs)} frequencies across {n_windows} windows...")

    # Use FFT approach for speed (Goertzel for each freq would be too slow)
    energy_map = np.zeros((n_windows, len(test_freqs)))

    for w in range(n_windows):
        start = w * hop_size
        chunk = samples[start:start + window_size] * np.hanning(window_size)
        spectrum = np.abs(np.fft.rfft(chunk))
        fft_freqs = np.fft.rfftfreq(window_size, 1.0 / sr)
        # Interpolate to our test frequencies
        energy_map[w] = np.interp(test_freqs, fft_freqs, spectrum)

    # For each window, find which two frequencies are dominant
    # Group into "mark" and "space" by looking at which freq pairs toggle
    # First, identify candidate tone frequencies from the energy map
    avg_energy = np.mean(energy_map, axis=0)
    avg_energy_db = 20 * np.log10(avg_energy / avg_energy.max() + 1e-10)

    # Find prominent frequency regions
    threshold = -15
    tone_regions = []
    in_region = False
    region_start = 0
    for i, db in enumerate(avg_energy_db):
        if db > threshold and not in_region:
            in_region = True
            region_start = i
        elif db <= threshold and in_region:
            in_region = False
            # Find peak in this region
            region = avg_energy[region_start:i]
            peak_idx = region_start + np.argmax(region)
            tone_regions.append((test_freqs[peak_idx], avg_energy_db[peak_idx]))

    print(f"Detected {len(tone_regions)} tone regions:")
    for freq, db in tone_regions:
        print(f"  {freq:.0f} Hz ({db:.1f} dB)")

    # Step 3: Fine-grained tone pair detection
    print("\n=== Step 3: Instantaneous Frequency Tracking ===")
    # Use analytic signal to track instantaneous frequency
    # Focus on the region with the most energy

    # Bandpass filter around the strongest region first
    # The energy is concentrated 800-1400 Hz based on earlier analysis
    # Let's look at 800-1400 Hz and also 500-3500 Hz

    from scipy.signal import hilbert, butter, filtfilt
    has_scipy = True

    for band_name, lo, hi in [("800-1400 Hz", 800, 1400), ("500-3500 Hz", 500, 3500)]:
        try:
            b, a = butter(4, [lo / (sr/2), hi / (sr/2)], btype='band')
            filtered = filtfilt(b, a, samples)

            # Compute instantaneous frequency via analytic signal
            analytic = hilbert(filtered)
            inst_phase = np.unwrap(np.angle(analytic))
            inst_freq = np.diff(inst_phase) * sr / (2 * np.pi)

            # Smooth instantaneous frequency
            kernel_size = int(sr * 0.005)  # 5ms smoothing
            kernel = np.ones(kernel_size) / kernel_size
            inst_freq_smooth = np.convolve(inst_freq, kernel, mode='valid')

            # Histogram of instantaneous frequencies
            freq_min, freq_max = lo, hi
            valid = (inst_freq_smooth > freq_min) & (inst_freq_smooth < freq_max)
            valid_freqs = inst_freq_smooth[valid]

            if len(valid_freqs) == 0:
                continue

            print(f"\nBand {band_name}:")
            # High-res histogram
            bins = np.arange(freq_min, freq_max, 1)
            hist, edges = np.histogram(valid_freqs, bins=bins)
            hist_smooth = np.convolve(hist, np.ones(5)/5, mode='same')

            # Find peaks in histogram (the two FSK tones)
            hist_peaks = []
            for i in range(5, len(hist_smooth) - 5):
                if (hist_smooth[i] > hist_smooth[i-1] and hist_smooth[i] > hist_smooth[i+1] and
                    hist_smooth[i] > hist_smooth[i-3] and hist_smooth[i] > hist_smooth[i+3] and
                    hist_smooth[i] > np.max(hist_smooth) * 0.1):
                    center = (edges[i] + edges[i+1]) / 2
                    # Check separation from existing peaks
                    too_close = False
                    for pf, _ in hist_peaks:
                        if abs(center - pf) < 30:
                            too_close = True
                            break
                    if not too_close:
                        hist_peaks.append((center, hist_smooth[i]))

            hist_peaks.sort(key=lambda x: -x[1])
            print(f"  Instantaneous frequency peaks:")
            for freq, count in hist_peaks[:6]:
                print(f"    {freq:.1f} Hz (count={count:.0f})")

            if len(hist_peaks) >= 2:
                f1, c1 = hist_peaks[0]
                f2, c2 = hist_peaks[1]
                mark = max(f1, f2)
                space = min(f1, f2)
                shift = mark - space
                print(f"\n  >> Detected: Mark={mark:.1f} Hz, Space={space:.1f} Hz, Shift={shift:.1f} Hz")

        except ImportError:
            print(f"  scipy not available, skipping instantaneous freq analysis")
            break

    # Step 4: Baud rate detection via autocorrelation of the FSK correlation signal
    print("\n=== Step 4: Baud Rate Detection ===")

    # Use the best pair from tone detection
    # From the spectrogram, likely around 1000/1200 Hz
    # Test multiple candidate pairs
    candidate_pairs = []

    # Add pairs from the histogram peaks
    if len(hist_peaks) >= 2:
        f1 = hist_peaks[0][0]
        f2 = hist_peaks[1][0]
        candidate_pairs.append((max(f1,f2), min(f1,f2)))

    # Add some standard pairs to test
    candidate_pairs.extend([
        (2295, 2125),  # 170 Hz shift, 2295 mark
        (2125, 1955),  # 170 Hz shift, standard
        (1275, 1105),  # 170 Hz shift
    ])

    for mark_f, space_f in candidate_pairs:
        shift = mark_f - space_f
        print(f"\n  Testing Mark={mark_f:.0f} Hz, Space={space_f:.0f} Hz (shift={shift:.0f} Hz):")

        # Compute mark/space correlation per sample using Goertzel in blocks
        block_size = int(sr / 200)  # 5ms blocks
        n_blocks = len(samples) // block_size
        correlation = np.zeros(n_blocks)

        for i in range(n_blocks):
            chunk = samples[i*block_size:(i+1)*block_size]
            m = goertzel(chunk, mark_f, sr)
            s = goertzel(chunk, space_f, sr)
            if m + s > 0:
                correlation[i] = (m - s) / (m + s)

        # Autocorrelation to find periodicity (= baud rate)
        corr_binary = (correlation > 0).astype(float)  # Mark=1, Space=0
        transitions = np.diff(corr_binary)
        transition_indices = np.where(transitions != 0)[0]

        if len(transition_indices) < 2:
            print(f"    Too few transitions ({len(transition_indices)})")
            continue

        intervals = np.diff(transition_indices)
        intervals_ms = intervals * (block_size / sr) * 1000

        print(f"    Transitions: {len(transition_indices)}")
        print(f"    Min interval: {np.min(intervals_ms):.1f} ms")
        print(f"    Percentile 5th: {np.percentile(intervals_ms, 5):.1f} ms")
        print(f"    Percentile 10th: {np.percentile(intervals_ms, 10):.1f} ms")
        print(f"    Median: {np.median(intervals_ms):.1f} ms")

        # The shortest intervals should correspond to single-bit transitions
        # Find the fundamental bit period
        min_interval = np.percentile(intervals_ms, 5)

        # Compare with known baud rates
        for baud in [45.45, 50.0, 75.0, 100.0]:
            bit_ms = 1000.0 / baud
            ratio = min_interval / bit_ms
            print(f"    Baud {baud}: bit={bit_ms:.2f}ms, ratio={ratio:.2f}")

if __name__ == '__main__':
    main()
