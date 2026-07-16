#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Create event-level shadow A/B diffs and aubio-removal gate results."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


def _ratio(numerator: int, denominator: int) -> float:
    return numerator / denominator if denominator else 1.0


def _f1(metrics: dict[str, int]) -> float:
    tp = metrics["true_positive"]
    return _ratio(2 * tp, 2 * tp + metrics["false_positive"] + metrics["false_negative"])


def _backend(case: dict[str, Any], name: str) -> dict[str, Any]:
    for backend in case["backends"]:
        if backend["name"] == name:
            return backend
    raise ValueError(f"{case['case']['case_id']}: backend {name!r} is missing")


def _sum_metrics(cases: list[dict[str, Any]], backend_name: str) -> dict[str, int]:
    totals = {"true_positive": 0, "false_positive": 0, "false_negative": 0}
    for case in cases:
        metrics = _backend(case, backend_name)["metrics"]
        for key in totals:
            totals[key] += int(metrics[key])
    return totals


def _read_events(path: Path, backend: str) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as input_file:
        return [row for row in csv.DictReader(input_file) if row["backend"] == backend]


def _match_events(
    reference: list[dict[str, str]],
    candidate: list[dict[str, str]],
    window_ms: float,
) -> list[dict[str, Any]]:
    possible: list[tuple[float, int, int]] = []
    for reference_index, reference_event in enumerate(reference):
        for candidate_index, candidate_event in enumerate(candidate):
            delta = float(candidate_event["output_ms"]) - float(reference_event["output_ms"])
            if abs(delta) <= window_ms:
                possible.append((abs(delta), reference_index, candidate_index))
    possible.sort()
    used_reference: set[int] = set()
    used_candidate: set[int] = set()
    rows: list[dict[str, Any]] = []
    for _, reference_index, candidate_index in possible:
        if reference_index in used_reference or candidate_index in used_candidate:
            continue
        used_reference.add(reference_index)
        used_candidate.add(candidate_index)
        reference_ms = float(reference[reference_index]["output_ms"])
        candidate_ms = float(candidate[candidate_index]["output_ms"])
        rows.append(
            {
                "status": "matched",
                "reference_ms": reference_ms,
                "candidate_ms": candidate_ms,
                "delta_ms": candidate_ms - reference_ms,
                "reference_descriptor": float(reference[reference_index]["descriptor"]),
                "candidate_descriptor": float(candidate[candidate_index]["descriptor"]),
            }
        )
    for index, event in enumerate(reference):
        if index not in used_reference:
            rows.append(
                {
                    "status": "reference_only",
                    "reference_ms": float(event["output_ms"]),
                    "candidate_ms": None,
                    "delta_ms": None,
                    "reference_descriptor": float(event["descriptor"]),
                    "candidate_descriptor": None,
                }
            )
    for index, event in enumerate(candidate):
        if index not in used_candidate:
            rows.append(
                {
                    "status": "candidate_only",
                    "reference_ms": None,
                    "candidate_ms": float(event["output_ms"]),
                    "delta_ms": None,
                    "reference_descriptor": None,
                    "candidate_descriptor": float(event["descriptor"]),
                }
            )
    rows.sort(
        key=lambda row: min(
            value for value in (row["reference_ms"], row["candidate_ms"]) if value is not None
        )
    )
    return rows


def generate_shadow_report(
    aggregate_path: Path,
    output_dir: Path,
    manifest_path: Path,
    reference_name: str = "aubio",
    candidate_name: str = "sdk_core",
    event_match_window_ms: float = 50.0,
    target_benchmark_count: int = 0,
    experience_approved: bool = False,
    rollback_verified: bool = False,
) -> dict[str, Any]:
    aggregate = json.loads(aggregate_path.read_text(encoding="utf-8"))
    cases: list[dict[str, Any]] = aggregate["cases"]
    with manifest_path.open(encoding="utf-8", newline="") as input_file:
        manifest = {row["case_id"]: row for row in csv.DictReader(input_file)}

    reference_totals = _sum_metrics(cases, reference_name)
    candidate_totals = _sum_metrics(cases, candidate_name)
    reference_f1 = _f1(reference_totals)
    candidate_f1 = _f1(candidate_totals)

    critical_cases = [
        case for case in cases if manifest[case["case"]["case_id"]]["critical"] == "yes"
    ]
    negative_cases = [
        case
        for case in cases
        if manifest[case["case"]["case_id"]]["expected_haptic"] == "none"
    ]
    critical_reference = _sum_metrics(critical_cases, reference_name)
    critical_candidate = _sum_metrics(critical_cases, candidate_name)
    critical_reference_recall = _ratio(
        critical_reference["true_positive"],
        critical_reference["true_positive"] + critical_reference["false_negative"],
    )
    critical_candidate_recall = _ratio(
        critical_candidate["true_positive"],
        critical_candidate["true_positive"] + critical_candidate["false_negative"],
    )
    negative_reference_fp = sum(
        int(_backend(case, reference_name)["metrics"]["false_positive"])
        for case in negative_cases
    )
    negative_candidate_fp = sum(
        int(_backend(case, candidate_name)["metrics"]["false_positive"])
        for case in negative_cases
    )
    positive_cases = [case for case in cases if int(case["label_count"]) > 0]
    worst_median_ms = max(
        (float(_backend(case, candidate_name)["metrics"]["median_abs_error_ms"])
         for case in positive_cases),
        default=0.0,
    )
    worst_p95_ms = max(
        (float(_backend(case, candidate_name)["metrics"]["p95_abs_error_ms"])
         for case in positive_cases),
        default=0.0,
    )
    worst_host_p99_us = max(
        float(_backend(case, candidate_name)["benchmark"]["call_p99_us"])
        for case in cases
    )
    real_world_case_count = sum(
        row["dataset_kind"] == "real_world" for row in manifest.values()
    )

    negative_fp_pass = (
        negative_candidate_fp == 0
        if negative_reference_fp == 0
        else negative_candidate_fp <= 1.1 * negative_reference_fp
    )
    gates = {
        "f1_gap_within_0_02": candidate_f1 >= reference_f1 - 0.02,
        "critical_recall_not_lower": critical_candidate_recall >= critical_reference_recall,
        "timing_median_at_most_10_ms": worst_median_ms <= 10.0,
        "timing_p95_at_most_25_ms": worst_p95_ms <= 25.0,
        "negative_false_positives_within_1_1x": negative_fp_pass,
        "host_call_p99_at_most_500_us": worst_host_p99_us <= 500.0,
        "real_world_dataset_present": real_world_case_count > 0,
        "two_target_device_classes_benchmarked": target_benchmark_count >= 2,
        "internal_experience_approved": experience_approved,
        "rollback_verified": rollback_verified,
    }
    algorithm_gate_names = (
        "f1_gap_within_0_02",
        "critical_recall_not_lower",
        "timing_median_at_most_10_ms",
        "timing_p95_at_most_25_ms",
        "negative_false_positives_within_1_1x",
        "host_call_p99_at_most_500_us",
    )

    event_rows: list[dict[str, Any]] = []
    for case in cases:
        case_id = case["case"]["case_id"]
        events_path = output_dir / case_id / "events.csv"
        for row in _match_events(
            _read_events(events_path, reference_name),
            _read_events(events_path, candidate_name),
            event_match_window_ms,
        ):
            event_rows.append({"case_id": case_id, **row})

    versions = {
        str(case.get("parameter_set_version", "unknown")) for case in cases
    }
    sdk_versions = {str(case.get("sdk_version", "unknown")) for case in cases}
    report = {
        "schema_version": 1,
        "reference_backend": reference_name,
        "candidate_backend": candidate_name,
        "sdk_version": next(iter(sdk_versions)) if len(sdk_versions) == 1 else "mixed",
        "parameter_set_version": next(iter(versions)) if len(versions) == 1 else "mixed",
        "dataset": {
            "case_count": len(cases),
            "real_world_case_count": real_world_case_count,
        },
        "metrics": {
            "reference_f1": reference_f1,
            "candidate_f1": candidate_f1,
            "f1_gap": candidate_f1 - reference_f1,
            "critical_reference_recall": critical_reference_recall,
            "critical_candidate_recall": critical_candidate_recall,
            "negative_reference_false_positives": negative_reference_fp,
            "negative_candidate_false_positives": negative_candidate_fp,
            "candidate_worst_case_median_ms": worst_median_ms,
            "candidate_worst_case_p95_ms": worst_p95_ms,
            "candidate_worst_host_call_p99_us": worst_host_p99_us,
            "matched_events": sum(row["status"] == "matched" for row in event_rows),
            "reference_only_events": sum(
                row["status"] == "reference_only" for row in event_rows
            ),
            "candidate_only_events": sum(
                row["status"] == "candidate_only" for row in event_rows
            ),
        },
        "gates": gates,
        "algorithm_gates_pass": all(gates[name] for name in algorithm_gate_names),
        "ready_for_aubio_removal": all(gates.values()),
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "shadow_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    with (output_dir / "shadow_events.csv").open("w", encoding="utf-8", newline="") as output:
        fieldnames = (
            "case_id",
            "status",
            "reference_ms",
            "candidate_ms",
            "delta_ms",
            "reference_descriptor",
            "candidate_descriptor",
        )
        writer = csv.DictWriter(output, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(event_rows)

    gate_lines = [
        f"| {name} | {'PASS' if passed else 'BLOCKED'} |"
        for name, passed in gates.items()
    ]
    markdown = f"""# Audio haptics shadow A/B report

- Reference: `{reference_name}`
- Candidate: `{candidate_name}`
- SDK: `{report['sdk_version']}`
- Parameter set: `{report['parameter_set_version']}`
- Dataset: {len(cases)} cases ({real_world_case_count} real-world)
- Algorithm gates: **{'PASS' if report['algorithm_gates_pass'] else 'FAIL'}**
- Ready for aubio removal: **{'YES' if report['ready_for_aubio_removal'] else 'NO'}**

| Metric | Reference | Candidate |
|---|---:|---:|
| Aggregate F1 | {reference_f1:.6f} | {candidate_f1:.6f} |
| Critical recall | {critical_reference_recall:.6f} | {critical_candidate_recall:.6f} |
| Negative false positives | {negative_reference_fp} | {negative_candidate_fp} |
| Worst labeled-case median timing | - | {worst_median_ms:.3f} ms |
| Worst labeled-case P95 timing | - | {worst_p95_ms:.3f} ms |
| Worst Host call P99 | - | {worst_host_p99_us:.3f} us |

## Gates

| Gate | Result |
|---|---|
{chr(10).join(gate_lines)}

Raw PCM is not included in this report. Event-level output contains timestamps,
descriptors, and aggregate differences only.
"""
    (output_dir / "shadow_report.md").write_text(markdown, encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--aggregate", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--reference", default="aubio")
    parser.add_argument("--candidate", default="sdk_core")
    parser.add_argument("--event-match-window-ms", type=float, default=50.0)
    parser.add_argument("--target-benchmark-count", type=int, default=0)
    parser.add_argument("--experience-approved", action="store_true")
    parser.add_argument("--rollback-verified", action="store_true")
    args = parser.parse_args()
    report = generate_shadow_report(
        args.aggregate,
        args.output_dir,
        args.manifest,
        args.reference,
        args.candidate,
        args.event_match_window_ms,
        args.target_benchmark_count,
        args.experience_approved,
        args.rollback_verified,
    )
    print(
        "shadow-report: algorithm_gates="
        f"{'PASS' if report['algorithm_gates_pass'] else 'FAIL'}, "
        "aubio_removal="
        f"{'READY' if report['ready_for_aubio_removal'] else 'BLOCKED'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
