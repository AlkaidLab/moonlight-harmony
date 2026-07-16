#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Parse aggregate-only HarmonyOS audio haptics shadow HiLog snapshots."""

from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path
from typing import Any, Iterable


PRIMARY_RE = re.compile(
    r"blocks=(?P<blocks>\d+)\s+frames=(?P<frames>\d+)\s+"
    r"ref=(?P<reference_events>\d+)\s+sdk=(?P<sdk_events>\d+)\s+"
    r"matched=(?P<matched_events>\d+)\s+refOnly=(?P<reference_only_events>\d+)\s+"
    r"sdkOnly=(?P<sdk_only_events>\d+)\s+pending=(?P<pending_reference>\d+)/(?P<pending_sdk>\d+)\s+"
    r"(?:totalUs=(?P<total_process_us>\d+)\s+)?"
    r"meanUs=(?P<mean_process_us>\d+)\s+maxUs=(?P<max_process_us>\d+)\s+"
    r"errors=(?P<process_errors>\d+)"
)

HISTOGRAM_RE = re.compile(
    r"latencyBucketsUs\s+le50=(?P<le50>\d+)\s+le100=(?P<le100>\d+)\s+"
    r"le200=(?P<le200>\d+)\s+le500=(?P<le500>\d+)\s+"
    r"le1000=(?P<le1000>\d+)\s+gt1000=(?P<gt1000>\d+)\s+"
    r"matchDeltaSumUs=(?P<match_delta_sum_us>-?\d+)\s+"
    r"matchDeltaAbsMaxUs=(?P<match_delta_abs_max_us>\d+)"
)

REQUIRED_METADATA_FIELDS = (
    "schema_version",
    "capture_id",
    "captured_at_utc",
    "device_id_hash",
    "device_class",
    "model",
    "os_version",
    "cpu_abi",
    "scenario_id",
    "scenario_category",
    "sample_rate_hz",
    "sdk_version",
    "parameter_set_version",
    "shadow_runtime_enabled",
    "source",
    "synthetic",
)

HISTOGRAM_BUCKETS = (
    ("le50", 50),
    ("le100", 100),
    ("le200", 200),
    ("le500", 500),
    ("le1000", 1000),
    ("gt1000", None),
)


def _ints(match: re.Match[str]) -> dict[str, int]:
    return {key: int(value) for key, value in match.groupdict().items() if value is not None}


def parse_snapshots(lines: Iterable[str]) -> list[dict[str, Any]]:
    """Return complete primary/histogram snapshot pairs from the final run."""
    snapshots: list[dict[str, Any]] = []
    pending: dict[str, int] | None = None

    for line in lines:
        if "[HAPTICS_SHADOW]" not in line:
            continue
        primary_match = PRIMARY_RE.search(line)
        if primary_match:
            pending = _ints(primary_match)
            continue
        histogram_match = HISTOGRAM_RE.search(line)
        if histogram_match and pending is not None:
            snapshot: dict[str, Any] = dict(pending)
            snapshot["latency_buckets_us"] = _ints(histogram_match)
            if snapshots and snapshot["blocks"] < snapshots[-1]["blocks"]:
                # Runtime re-enable resets cumulative counters. Only the final run
                # is eligible for a capture summary.
                snapshots.clear()
            snapshots.append(snapshot)
            pending = None

    return snapshots


def p99_bucket_upper_bound(histogram: dict[str, int], total: int) -> int | None:
    """Return the inclusive P99 bucket upper bound, or None for the open bucket."""
    if total <= 0:
        return None
    target = math.ceil(total * 0.99)
    cumulative = 0
    for name, upper_bound in HISTOGRAM_BUCKETS:
        cumulative += histogram[name]
        if cumulative >= target:
            return upper_bound
    return None


def validate_metadata(metadata: dict[str, Any]) -> list[str]:
    errors = [f"missing metadata field: {name}" for name in REQUIRED_METADATA_FIELDS if name not in metadata]
    if errors:
        return errors
    if metadata["schema_version"] != 1:
        errors.append("metadata schema_version must be 1")
    if not re.fullmatch(r"[0-9a-f]{12}", str(metadata["device_id_hash"])):
        errors.append("device_id_hash must be 12 lowercase hexadecimal characters")
    if metadata["shadow_runtime_enabled"] is not True:
        errors.append("shadow_runtime_enabled must be true")
    if metadata["source"] not in ("hilog_aggregate_only", "android_logcat_aggregate_only"):
        errors.append("source must be an aggregate-only HarmonyOS or Android log source")
    return errors


def build_summary(metadata: dict[str, Any], snapshots: list[dict[str, Any]]) -> dict[str, Any]:
    metadata_errors = validate_metadata(metadata)
    if not snapshots:
        raise ValueError("no complete [HAPTICS_SHADOW] snapshot pair found")

    final = snapshots[-1]
    metrics = dict(final)
    metrics["latency_buckets_us"] = dict(final["latency_buckets_us"])
    measurement_mode = "cumulative_single_snapshot"
    if len(snapshots) >= 2:
        baseline = snapshots[0]
        if final["blocks"] <= baseline["blocks"]:
            raise ValueError("no new audio blocks between the first and final shadow snapshots")
        measurement_mode = "snapshot_delta"
        cumulative_fields = (
            "blocks",
            "frames",
            "reference_events",
            "sdk_events",
            "matched_events",
            "reference_only_events",
            "sdk_only_events",
            "process_errors",
        )
        for field in cumulative_fields:
            metrics[field] = final[field] - baseline[field]
        for name, _ in HISTOGRAM_BUCKETS:
            metrics["latency_buckets_us"][name] = (
                final["latency_buckets_us"][name] - baseline["latency_buckets_us"][name]
            )
        metrics["latency_buckets_us"]["match_delta_sum_us"] = (
            final["latency_buckets_us"]["match_delta_sum_us"]
            - baseline["latency_buckets_us"]["match_delta_sum_us"]
        )
        if "total_process_us" in final and "total_process_us" in baseline:
            metrics["total_process_us"] = final["total_process_us"] - baseline["total_process_us"]
            metrics["mean_process_us"] = metrics["total_process_us"] // metrics["blocks"]
        else:
            # Backward-compatible estimate for logs produced before totalUs was
            # added. Each cumulative mean may contain up to one microsecond of
            # integer truncation error.
            estimated_total = (
                final["mean_process_us"] * final["blocks"]
                - baseline["mean_process_us"] * baseline["blocks"]
            )
            metrics["mean_process_us"] = estimated_total // metrics["blocks"]

    histogram = metrics["latency_buckets_us"]
    histogram_total = sum(histogram[name] for name, _ in HISTOGRAM_BUCKETS)
    histogram_nonnegative = all(histogram[name] >= 0 for name, _ in HISTOGRAM_BUCKETS)
    histogram_consistent = histogram_nonnegative and histogram_total == metrics["blocks"]
    p99_upper = p99_bucket_upper_bound(histogram, histogram_total) if histogram_consistent else None
    p99_gate_pass = histogram_consistent and p99_upper is not None and p99_upper <= 500
    mean_delta = (
        histogram["match_delta_sum_us"] / metrics["matched_events"]
        if metrics["matched_events"]
        else None
    )
    sample_rate = int(metadata["sample_rate_hz"])

    summary = {
        "schema_version": 1,
        "metadata": metadata,
        "snapshot_count": len(snapshots),
        "measurement_mode": measurement_mode,
        "duration_seconds_from_frames": metrics["frames"] / sample_rate if sample_rate > 0 else None,
        "metrics": metrics,
        "session_final_metrics": final,
        "derived": {
            "histogram_total": histogram_total,
            "histogram_consistent": histogram_consistent,
            "p99_process_us_upper_bound": p99_upper,
            "p99_process_us_display": f"<={p99_upper}" if p99_upper is not None else ">1000 or unavailable",
            "mean_match_delta_us": mean_delta,
        },
        "gates": {
            "metadata_valid": {"pass": not metadata_errors, "details": metadata_errors},
            "histogram_consistent": {"pass": histogram_consistent},
            "process_errors_zero": {"pass": metrics["process_errors"] == 0},
            "p99_process_le_500_us": {"pass": p99_gate_pass},
        },
    }
    summary["capture_pass"] = all(gate["pass"] for gate in summary["gates"].values())
    return summary


def render_markdown(summary: dict[str, Any]) -> str:
    metadata = summary["metadata"]
    metrics = summary["metrics"]
    derived = summary["derived"]
    lines = [
        f"# Device shadow capture: {metadata['capture_id']}",
        "",
        f"- Result: **{'PASS' if summary['capture_pass'] else 'BLOCKED'}**",
        f"- Device class/model: `{metadata['device_class']}` / `{metadata['model']}`",
        f"- OS/ABI: `{metadata['os_version']}` / `{metadata['cpu_abi']}`",
        f"- Scenario: `{metadata['scenario_category']}` / `{metadata['scenario_id']}`",
        f"- SDK/parameters: `{metadata['sdk_version']}` / `{metadata['parameter_set_version']}`",
        f"- Synthetic: `{str(metadata['synthetic']).lower()}`",
        f"- Measurement mode: `{summary['measurement_mode']}`",
        "",
        "| Metric | Value |",
        "|---|---:|",
        f"| Blocks | {metrics['blocks']} |",
        f"| Frames | {metrics['frames']} |",
        f"| Mean process time | {metrics['mean_process_us']} us |",
        f"| Session maximum process time (informational) | {metrics['max_process_us']} us |",
        f"| P99 bucket upper bound | {derived['p99_process_us_display']} us |",
        f"| Process errors | {metrics['process_errors']} |",
        f"| Reference / SDK events | {metrics['reference_events']} / {metrics['sdk_events']} |",
        f"| Matched / reference-only / SDK-only | {metrics['matched_events']} / {metrics['reference_only_events']} / {metrics['sdk_only_events']} |",
        "",
        "## Gates",
        "",
    ]
    for name, gate in summary["gates"].items():
        lines.append(f"- {'PASS' if gate['pass'] else 'BLOCKED'}: `{name}`")
    lines.extend([
        "",
        "> Window metrics are the final snapshot minus the first snapshot. P99 is derived conservatively from the fixed histogram; the session maximum is informational only.",
        "",
    ])
    return "\n".join(lines)


def parse_capture(log_path: Path, metadata_path: Path) -> dict[str, Any]:
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    snapshots = parse_snapshots(log_path.read_text(encoding="utf-8", errors="replace").splitlines())
    return build_summary(metadata, snapshots)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True, help="Raw aggregate-only HiLog capture")
    parser.add_argument("--metadata", type=Path, required=True, help="Capture metadata JSON")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    try:
        summary = parse_capture(args.log, args.metadata)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.error(str(exc))

    args.output_dir.mkdir(parents=True, exist_ok=True)
    json_path = args.output_dir / "device_shadow_summary.json"
    md_path = args.output_dir / "device_shadow_summary.md"
    json_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(summary), encoding="utf-8")
    print(json_path)
    print(md_path)
    return 0 if summary["capture_pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
