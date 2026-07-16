#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the evaluator, validate a dataset, and run offline shadow A/B."""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import sys
from pathlib import Path

from shadow_compare import generate_shadow_report
from validate_dataset import validate_manifest


TOOL_DIR = Path(__file__).resolve().parent


def run(command: list[str]) -> None:
    print("+", subprocess.list2cmdline(command), flush=True)
    subprocess.run(command, check=True)


def build_evaluator(build_dir: Path) -> Path:
    cmake = shutil.which("cmake")
    if cmake is None:
        raise RuntimeError("cmake was not found in PATH")
    configure = [
        cmake,
        "-S",
        str(TOOL_DIR),
        "-B",
        str(build_dir),
        "-G",
        "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
    ]
    run(configure)
    run([cmake, "--build", str(build_dir), "--config", "Release"])

    candidates = (
        build_dir / "audio_haptics_eval.exe",
        build_dir / "audio_haptics_eval",
        build_dir / "Release" / "audio_haptics_eval.exe",
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise RuntimeError(f"evaluator executable not found under {build_dir}")


def generate_fixtures(fixtures_dir: Path) -> None:
    run(
        [
            sys.executable,
            str(TOOL_DIR / "generate_fixtures.py"),
            "--output-dir",
            str(fixtures_dir),
        ]
    )


def run_case(
    executable: Path,
    fixtures_dir: Path,
    output_dir: Path,
    row: dict[str, str],
    backend: str,
    runs: int,
    warmup_runs: int,
) -> dict:
    case_id = row["case_id"]
    case_output = output_dir / case_id
    case_output.mkdir(parents=True, exist_ok=True)
    summary_path = case_output / "summary.json"
    command = [
        str(executable),
        "--input",
        str(fixtures_dir / row["wav"]),
        "--labels",
        str(fixtures_dir / row["labels"]),
        "--backend",
        backend,
        "--events-out",
        str(case_output / "events.csv"),
        "--summary-out",
        str(summary_path),
        "--runs",
        str(runs),
        "--warmup-runs",
        str(warmup_runs),
    ]
    run(command)
    with summary_path.open(encoding="utf-8") as input_file:
        summary = json.load(input_file)
    summary["case"] = row
    return summary


def write_aggregate(output_dir: Path, summaries: list[dict]) -> None:
    aggregate_json = output_dir / "baseline.json"
    with aggregate_json.open("w", encoding="utf-8") as output:
        json.dump(
            {"schema_version": 1, "cases": summaries},
            output,
            ensure_ascii=False,
            indent=2,
        )
        output.write("\n")

    fields = (
        "case_id",
        "category",
        "backend",
        "labels",
        "events",
        "true_positive",
        "false_positive",
        "false_negative",
        "precision",
        "recall",
        "f1",
        "median_abs_error_ms",
        "p95_abs_error_ms",
        "call_p50_us",
        "call_p95_us",
        "call_p99_us",
        "call_max_us",
        "realtime_factor",
    )
    with (output_dir / "baseline.csv").open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for summary in summaries:
            for backend in summary["backends"]:
                metrics = backend["metrics"]
                benchmark = backend["benchmark"]
                writer.writerow(
                    {
                        "case_id": summary["case"]["case_id"],
                        "category": summary["case"]["category"],
                        "backend": backend["name"],
                        "labels": summary["label_count"],
                        "events": backend["event_count"],
                        "true_positive": metrics["true_positive"],
                        "false_positive": metrics["false_positive"],
                        "false_negative": metrics["false_negative"],
                        "precision": metrics["precision"],
                        "recall": metrics["recall"],
                        "f1": metrics["f1"],
                        "median_abs_error_ms": metrics["median_abs_error_ms"],
                        "p95_abs_error_ms": metrics["p95_abs_error_ms"],
                        "call_p50_us": benchmark["call_p50_us"],
                        "call_p95_us": benchmark["call_p95_us"],
                        "call_p99_us": benchmark["call_p99_us"],
                        "call_max_us": benchmark["call_max_us"],
                        "realtime_factor": benchmark["realtime_factor"],
                    }
                )
    print(f"Aggregate baseline: {aggregate_json.resolve()}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, default=TOOL_DIR / "build")
    parser.add_argument(
        "--fixtures-dir", type=Path, default=TOOL_DIR / "fixtures" / "generated"
    )
    parser.add_argument("--output-dir", type=Path, default=TOOL_DIR / "out")
    parser.add_argument(
        "--manifest",
        type=Path,
        help="Dataset manifest; defaults to <fixtures-dir>/manifest.csv",
    )
    parser.add_argument(
        "--backend",
        choices=("aubio", "native", "sdk", "both", "all"),
        default="all",
    )
    parser.add_argument("--runs", type=int, default=30)
    parser.add_argument("--warmup-runs", type=int, default=3)
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Use an existing executable in --build-dir",
    )
    parser.add_argument(
        "--skip-generate",
        action="store_true",
        help="Evaluate an existing dataset instead of regenerating fixtures",
    )
    args = parser.parse_args()

    if args.runs <= 0 or args.warmup_runs < 0:
        parser.error("--runs must be positive and --warmup-runs non-negative")

    executable = (
        args.build_dir / ("audio_haptics_eval.exe" if sys.platform == "win32" else "audio_haptics_eval")
        if args.skip_build
        else build_evaluator(args.build_dir)
    )
    if not executable.exists():
        raise RuntimeError(f"evaluator executable not found: {executable}")

    if not args.skip_generate:
        generate_fixtures(args.fixtures_dir)
    manifest_path = args.manifest or args.fixtures_dir / "manifest.csv"
    validation = validate_manifest(manifest_path)
    if not validation["valid"]:
        raise RuntimeError("dataset validation failed: " + "; ".join(validation["errors"]))
    print(
        f"dataset-check: {validation['case_count']} cases, "
        f"{validation['real_world_case_count']} real-world, manifest OK"
    )
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with manifest_path.open(encoding="utf-8", newline="") as input_file:
        manifest = list(csv.DictReader(input_file))

    summaries = [
        run_case(
            executable,
            manifest_path.parent,
            args.output_dir,
            row,
            args.backend,
            args.runs,
            args.warmup_runs,
        )
        for row in manifest
    ]
    write_aggregate(args.output_dir, summaries)
    if args.backend == "all":
        report = generate_shadow_report(
            args.output_dir / "baseline.json",
            args.output_dir,
            manifest_path,
        )
        print(
            "Shadow gates: algorithm="
            f"{'PASS' if report['algorithm_gates_pass'] else 'FAIL'}, "
            "aubio_removal="
            f"{'READY' if report['ready_for_aubio_removal'] else 'BLOCKED'}"
        )


if __name__ == "__main__":
    main()
