#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate deterministic PCM16 fixtures and onset labels for P0 evaluation."""

from __future__ import annotations

import argparse
import csv
import hashlib
import math
import random
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence


SAMPLE_RATE = 48_000
PCM_MAX = 32_767


@dataclass(frozen=True)
class Case:
    case_id: str
    category: str
    description: str
    channels: int
    duration_seconds: float
    labels_ms: tuple[float, ...]
    renderer: Callable[[int, int], Sequence[float]]


def clamp(value: float) -> float:
    return max(-1.0, min(1.0, value))


def add_mono_burst(
    signal: list[float],
    start_ms: float,
    duration_ms: float,
    sample_fn: Callable[[float, int], float],
) -> None:
    start = round(start_ms * SAMPLE_RATE / 1000.0)
    length = round(duration_ms * SAMPLE_RATE / 1000.0)
    for local_index in range(length):
        index = start + local_index
        if index >= len(signal):
            break
        t = local_index / SAMPLE_RATE
        signal[index] += sample_fn(t, local_index)


def render_impulse_train(frame_count: int, channels: int) -> Sequence[float]:
    signal = [0.0] * frame_count
    rng = random.Random(10_001)
    for event_ms in (500, 1000, 1500, 2000, 2500):
        noise = [rng.uniform(-1.0, 1.0) for _ in range(round(0.012 * SAMPLE_RATE))]

        def click(t: float, index: int, source=noise) -> float:
            return 0.90 * math.exp(-t / 0.0035) * source[index]

        add_mono_burst(signal, event_ms, 12.0, click)
    return signal


def render_kick_train(frame_count: int, channels: int) -> Sequence[float]:
    left = [0.0] * frame_count
    right = [0.0] * frame_count
    for event_index, event_ms in enumerate((500, 1000, 1500, 2250, 3000, 3500)):
        pan = -0.35 if event_index % 2 == 0 else 0.35

        def kick(t: float, _: int) -> float:
            frequency = 78.0 - 32.0 * min(t / 0.12, 1.0)
            body = math.sin(2.0 * math.pi * frequency * t) * math.exp(-t / 0.055)
            attack = math.sin(2.0 * math.pi * 1100.0 * t) * math.exp(-t / 0.0025)
            return 0.78 * body + 0.20 * attack

        mono = [0.0] * frame_count
        add_mono_burst(mono, event_ms, 160.0, kick)
        for i, value in enumerate(mono):
            left[i] += value * (1.0 - max(0.0, pan))
            right[i] += value * (1.0 + min(0.0, pan))
    interleaved: list[float] = []
    for l_value, r_value in zip(left, right):
        interleaved.extend((l_value, r_value))
    return interleaved


def render_antiphase(frame_count: int, channels: int) -> Sequence[float]:
    mono = [0.0] * frame_count
    rng = random.Random(20_002)
    for event_ms in (500, 1000, 1500, 2000):
        noise = [rng.uniform(-1.0, 1.0) for _ in range(round(0.010 * SAMPLE_RATE))]

        def click(t: float, index: int, source=noise) -> float:
            return 0.82 * math.exp(-t / 0.003) * source[index]

        add_mono_burst(mono, event_ms, 10.0, click)
    interleaved: list[float] = []
    for value in mono:
        interleaved.extend((value, -value))
    return interleaved


def render_silence_then_hit(frame_count: int, channels: int) -> Sequence[float]:
    signal = [0.0] * frame_count
    rng = random.Random(30_003)
    noise = [rng.uniform(-1.0, 1.0) for _ in range(round(0.080 * SAMPLE_RATE))]

    def impact(t: float, index: int) -> float:
        low = math.sin(2.0 * math.pi * 55.0 * t) * math.exp(-t / 0.050)
        attack = noise[index] * math.exp(-t / 0.004)
        return 0.75 * low + 0.30 * attack

    add_mono_burst(signal, 2000.0, 80.0, impact)
    return signal


def render_steady_tone(frame_count: int, channels: int) -> Sequence[float]:
    interleaved: list[float] = []
    for index in range(frame_count):
        t = index / SAMPLE_RATE
        gain = min(1.0, t / 0.30) * 0.22
        value = gain * math.sin(2.0 * math.pi * 60.0 * t)
        interleaved.extend((value, value))
    return interleaved


def render_speech_like(frame_count: int, channels: int) -> Sequence[float]:
    signal: list[float] = []
    rng = random.Random(40_004)
    for index in range(frame_count):
        t = index / SAMPLE_RATE
        syllable_phase = t % 0.42
        envelope = 0.0
        if syllable_phase < 0.26:
            attack = min(1.0, syllable_phase / 0.025)
            release = min(1.0, (0.26 - syllable_phase) / 0.060)
            envelope = min(attack, release)
        pitch = 125.0 + 12.0 * math.sin(2.0 * math.pi * 0.8 * t)
        voiced = (
            math.sin(2.0 * math.pi * pitch * t)
            + 0.45 * math.sin(2.0 * math.pi * pitch * 2.0 * t)
            + 0.22 * math.sin(2.0 * math.pi * pitch * 3.0 * t)
        )
        noise = rng.uniform(-1.0, 1.0) * 0.04
        signal.append(0.16 * envelope * voiced + envelope * noise)
    return signal


CASES = (
    Case(
        "impulse_train_mono",
        "positive/transient",
        "Five broadband decaying clicks with clean spacing",
        1,
        3.0,
        (500, 1000, 1500, 2000, 2500),
        render_impulse_train,
    ),
    Case(
        "kick_train_stereo",
        "positive/low-frequency",
        "Six low-frequency kick bursts with alternating stereo pan",
        2,
        4.0,
        (500, 1000, 1500, 2250, 3000, 3500),
        render_kick_train,
    ),
    Case(
        "antiphase_impulses_stereo",
        "edge/phase-cancellation",
        "Four clicks with right channel exactly inverted; exposes waveform downmix cancellation",
        2,
        2.6,
        (500, 1000, 1500, 2000),
        render_antiphase,
    ),
    Case(
        "silence_then_hit_mono",
        "edge/state-recovery",
        "One impact after two seconds of digital silence",
        1,
        3.0,
        (2000,),
        render_silence_then_hit,
    ),
    Case(
        "steady_tone_stereo",
        "negative/continuous",
        "Slow fade-in 60 Hz tone with no annotated transient",
        2,
        3.0,
        (),
        render_steady_tone,
    ),
    Case(
        "speech_like_mono",
        "negative/speech-like",
        "Deterministic voiced syllable-like signal with no haptic onset labels",
        1,
        4.0,
        (),
        render_speech_like,
    ),
)


def float_to_pcm16(value: float) -> int:
    return round(clamp(value) * PCM_MAX)


def write_wav(path: Path, case: Case) -> None:
    frame_count = round(case.duration_seconds * SAMPLE_RATE)
    samples = case.renderer(frame_count, case.channels)
    expected_sample_count = frame_count * case.channels
    if len(samples) != expected_sample_count:
        raise ValueError(
            f"{case.case_id}: renderer returned {len(samples)} samples, "
            f"expected {expected_sample_count}"
        )
    pcm = bytearray()
    for sample in samples:
        pcm.extend(float_to_pcm16(sample).to_bytes(2, "little", signed=True))
    with wave.open(str(path), "wb") as output:
        output.setnchannels(case.channels)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm)


def write_labels(path: Path, labels_ms: Sequence[float]) -> None:
    with path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.writer(output, lineterminator="\n")
        writer.writerow(("time_ms", "event_type", "importance"))
        for time_ms in labels_ms:
            writer.writerow((f"{time_ms:.3f}", "onset", "1.0"))


def generate(output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_rows = []
    for case in CASES:
        wav_name = f"{case.case_id}.wav"
        labels_name = f"{case.case_id}.labels.csv"
        write_wav(output_dir / wav_name, case)
        write_labels(output_dir / labels_name, case.labels_ms)
        wav_sha256 = hashlib.sha256((output_dir / wav_name).read_bytes()).hexdigest()
        labels_sha256 = hashlib.sha256((output_dir / labels_name).read_bytes()).hexdigest()
        expected_haptic = "none" if case.category.startswith("negative/") else "transient"
        critical = "yes" if expected_haptic == "transient" else "no"
        manifest_rows.append(
            (
                case.case_id,
                wav_name,
                labels_name,
                case.category,
                case.channels,
                SAMPLE_RATE,
                f"{case.duration_seconds:.3f}",
                len(case.labels_ms),
                case.description,
                "synthetic",
                "project-generated",
                "yes",
                critical,
                expected_haptic,
                "test",
                wav_sha256,
                labels_sha256,
            )
        )

    with (output_dir / "manifest.csv").open("w", newline="", encoding="utf-8") as output:
        writer = csv.writer(output, lineterminator="\n")
        writer.writerow(
            (
                "case_id",
                "wav",
                "labels",
                "category",
                "channels",
                "sample_rate",
                "duration_seconds",
                "label_count",
                "description",
                "dataset_kind",
                "rights",
                "redistributable",
                "critical",
                "expected_haptic",
                "split",
                "audio_sha256",
                "labels_sha256",
            )
        )
        writer.writerows(manifest_rows)

    print(f"Generated {len(CASES)} deterministic fixtures in {output_dir.resolve()}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "fixtures" / "generated",
    )
    args = parser.parse_args()
    generate(args.output_dir)


if __name__ == "__main__":
    main()
