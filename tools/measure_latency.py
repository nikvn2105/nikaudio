#!/usr/bin/env python3
"""Measure NiKAudio test pulses in a two-channel PCM recording."""

import argparse
import math
import statistics
import sys
import wave
from array import array


def pulse_times(samples, rate):
    peak = max(map(abs, samples), default=0)
    if peak == 0:
        return []
    threshold = peak * 0.25
    times = []
    quiet_until = 0
    for index, value in enumerate(samples):
        if index >= quiet_until and abs(value) >= threshold:
            times.append(index / rate)
            quiet_until = index + round(rate * 0.75)
    return times


def delays_ms(reference, received):
    delays = []
    received_index = 0
    for index, sent in enumerate(reference):
        # Leave room for small alignment error, but reject hits from the next pulse.
        window_end = min(sent + 0.9, reference[index + 1] - 0.05) if index + 1 < len(reference) else sent + 0.9
        while received_index < len(received) and received[received_index] < sent - 0.01:
            received_index += 1
        if received_index < len(received) and received[received_index] <= window_end:
            delays.append(1000 * (received[received_index] - sent))
            received_index += 1
    return delays


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", help="16-bit stereo PCM WAV, PC on left, iPhone on right")
    args = parser.parse_args()
    try:
        with wave.open(args.recording, "rb") as recording:
            if recording.getnchannels() != 2 or recording.getsampwidth() != 2:
                parser.error("recording must be a stereo 16-bit PCM WAV")
            rate = recording.getframerate()
            samples = array("h", recording.readframes(recording.getnframes()))
    except (OSError, EOFError, wave.Error) as error:
        parser.error(str(error))
    if sys.byteorder == "big":
        samples.byteswap()
    reference = pulse_times(samples[::2], rate)
    received = pulse_times(samples[1::2], rate)
    if not 3 <= len(reference) <= 20 or len(received) > 20:
        parser.error("unexpected pulse count; record one pass in a quiet environment")
    delays = sorted(delays_ms(reference, received))
    if len(delays) < 3:
        parser.error("fewer than three pairs found; check channel order and recording levels")
    p95 = delays[math.ceil(len(delays) * 0.95) - 1]
    print(f"Matched {len(delays)}/{len(reference)} PC pulses ({len(received)} iPhone pulses detected).")
    print(f"Median {statistics.median(delays):.1f} ms, p95 {p95:.1f} ms, "
          f"range {delays[0]:.1f}–{delays[-1]:.1f} ms.")


if __name__ == "__main__":
    main()
