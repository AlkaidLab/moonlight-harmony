#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate a versioned audio-haptics dataset without copying audio."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import wave
from pathlib import Path


REQUIRED_COLUMNS = {
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
}
BOOLEAN_VALUES = {"yes", "no"}
EXPECTED_HAPTICS = {"transient", "continuous", "mixed", "none"}
DATASET_KINDS = {"synthetic", "real_world"}


def _resolve_child(root: Path, relative: str) -> Path:
    if not relative:
        raise ValueError("empty dataset path")
    path = (root / relative).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as error:
        raise ValueError(f"path escapes dataset root: {relative}") from error
    return path


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as input_file:
        for block in iter(lambda: input_file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _label_count(path: Path) -> int:
    with path.open(encoding="utf-8", newline="") as input_file:
        reader = csv.DictReader(input_file)
        if reader.fieldnames is None or "time_ms" not in reader.fieldnames:
            raise ValueError(f"{path.name}: labels require time_ms")
        count = 0
        previous = -1.0
        for row in reader:
            time_ms = float(row["time_ms"])
            if time_ms < 0.0 or time_ms < previous:
                raise ValueError(f"{path.name}: label times must be non-negative and sorted")
            previous = time_ms
            count += 1
        return count


def validate_manifest(manifest_path: Path, require_real_world: bool = False) -> dict:
    manifest_path = manifest_path.resolve()
    root = manifest_path.parent
    errors: list[str] = []
    cases: list[dict[str, str]] = []
    try:
        with manifest_path.open(encoding="utf-8", newline="") as input_file:
            reader = csv.DictReader(input_file)
            columns = set(reader.fieldnames or ())
            missing = sorted(REQUIRED_COLUMNS - columns)
            if missing:
                errors.append("missing columns: " + ", ".join(missing))
            cases = list(reader)
    except (OSError, UnicodeError) as error:
        return {"valid": False, "errors": [str(error)], "case_count": 0}

    seen: set[str] = set()
    real_world_count = 0
    for row_number, row in enumerate(cases, start=2):
        case_id = row.get("case_id", "").strip()
        prefix = f"row {row_number} ({case_id or 'missing case_id'})"
        try:
            if not case_id or case_id in seen:
                raise ValueError("case_id is empty or duplicated")
            seen.add(case_id)
            dataset_kind = row["dataset_kind"].strip()
            if dataset_kind not in DATASET_KINDS:
                raise ValueError(f"dataset_kind must be one of {sorted(DATASET_KINDS)}")
            real_world_count += int(dataset_kind == "real_world")
            if row["redistributable"].strip() not in BOOLEAN_VALUES:
                raise ValueError("redistributable must be yes or no")
            if row["critical"].strip() not in BOOLEAN_VALUES:
                raise ValueError("critical must be yes or no")
            if row["expected_haptic"].strip() not in EXPECTED_HAPTICS:
                raise ValueError(f"expected_haptic must be one of {sorted(EXPECTED_HAPTICS)}")
            if not row["rights"].strip():
                raise ValueError("rights must document the audio usage basis")

            wav_path = _resolve_child(root, row["wav"].strip())
            labels_path = _resolve_child(root, row["labels"].strip())
            if not wav_path.is_file() or not labels_path.is_file():
                raise ValueError("WAV or labels file is missing")
            if _sha256(wav_path) != row["audio_sha256"].strip().lower():
                raise ValueError("audio_sha256 mismatch")
            if _sha256(labels_path) != row["labels_sha256"].strip().lower():
                raise ValueError("labels_sha256 mismatch")

            with wave.open(str(wav_path), "rb") as wav_file:
                channels = wav_file.getnchannels()
                sample_rate = wav_file.getframerate()
                frames = wav_file.getnframes()
                if wav_file.getsampwidth() != 2 or wav_file.getcomptype() != "NONE":
                    raise ValueError("audio must be uncompressed PCM16 WAV")
            if channels != int(row["channels"]) or sample_rate != int(row["sample_rate"]):
                raise ValueError("WAV format does not match manifest")
            expected_duration = float(row["duration_seconds"])
            if abs(frames / sample_rate - expected_duration) > 1.0 / sample_rate:
                raise ValueError("WAV duration does not match manifest")
            if _label_count(labels_path) != int(row["label_count"]):
                raise ValueError("label_count does not match labels file")
        except (KeyError, OSError, ValueError, wave.Error) as error:
            errors.append(f"{prefix}: {error}")

    if not cases:
        errors.append("manifest contains no cases")
    if require_real_world and real_world_count == 0:
        errors.append("manifest contains no real_world cases")
    return {
        "valid": not errors,
        "manifest": str(manifest_path),
        "case_count": len(cases),
        "real_world_case_count": real_world_count,
        "errors": errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--require-real-world", action="store_true")
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args()
    result = validate_manifest(args.manifest, args.require_real_world)
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if result["valid"]:
        print(
            f"dataset-check: {result['case_count']} cases, "
            f"{result['real_world_case_count']} real-world, manifest OK"
        )
        return 0
    for error in result["errors"]:
        print(f"dataset-check: {error}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
