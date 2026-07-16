#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the real-device admission report from device shadow summaries."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Iterable


DEFAULT_REQUIRED_SCENARIOS = (
    "game_strong_transient",
    "continuous_low_frequency",
    "music",
    "speech",
    "silence_noise_floor",
    "stream_reconnect",
)


def build_gate_report(
    summaries: Iterable[dict[str, Any]],
    required_scenarios: Iterable[str] = DEFAULT_REQUIRED_SCENARIOS,
    minimum_device_classes: int = 2,
) -> dict[str, Any]:
    captures = list(summaries)
    device_classes = sorted({item["metadata"]["device_class"] for item in captures})
    device_ids = sorted({item["metadata"]["device_id_hash"] for item in captures})
    scenarios = sorted({item["metadata"]["scenario_category"] for item in captures})
    required = sorted(set(required_scenarios))
    scenarios_by_device_class = {
        device_class: sorted({
            item["metadata"]["scenario_category"]
            for item in captures
            if item["metadata"]["device_class"] == device_class
        })
        for device_class in device_classes
    }
    missing_scenarios_by_device_class = {
        device_class: sorted(set(required) - set(device_scenarios))
        for device_class, device_scenarios in scenarios_by_device_class.items()
        if set(required) - set(device_scenarios)
    }
    failed_capture_ids = [
        item["metadata"]["capture_id"] for item in captures if not item.get("capture_pass", False)
    ]
    synthetic_capture_ids = [
        item["metadata"]["capture_id"] for item in captures if item["metadata"].get("synthetic", True)
    ]

    gates = {
        "minimum_two_device_classes": {
            "pass": len(device_classes) >= minimum_device_classes,
            "actual": len(device_classes),
            "required": minimum_device_classes,
        },
        "minimum_two_distinct_devices": {
            "pass": len(device_ids) >= minimum_device_classes,
            "actual": len(device_ids),
            "required": minimum_device_classes,
        },
        "required_scenario_coverage_per_device_class": {
            "pass": bool(device_classes) and not missing_scenarios_by_device_class,
            "missing_by_device_class": missing_scenarios_by_device_class,
        },
        "all_capture_gates_pass": {
            "pass": not failed_capture_ids and bool(captures),
            "failed_capture_ids": failed_capture_ids,
        },
        "real_device_data_only": {
            "pass": not synthetic_capture_ids and bool(captures),
            "synthetic_capture_ids": synthetic_capture_ids,
        },
    }
    return {
        "schema_version": 1,
        "capture_count": len(captures),
        "distinct_device_count": len(device_ids),
        "device_classes": device_classes,
        "scenarios_by_device_class": scenarios_by_device_class,
        "scenario_categories": scenarios,
        "required_scenario_categories": required,
        "gates": gates,
        "admission_pass": all(gate["pass"] for gate in gates.values()),
    }


def render_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Audio haptics real-device admission report",
        "",
        f"Overall: **{'PASS' if report['admission_pass'] else 'BLOCKED'}**",
        "",
        f"- Captures: {report['capture_count']}",
        f"- Distinct devices: {report['distinct_device_count']}",
        f"- Device classes: {', '.join(report['device_classes']) or '(none)'}",
        f"- Scenario categories: {', '.join(report['scenario_categories']) or '(none)'}",
        "",
        "## Gates",
        "",
    ]
    for name, gate in report["gates"].items():
        details = {key: value for key, value in gate.items() if key != "pass"}
        suffix = f" — `{json.dumps(details, ensure_ascii=False)}`" if details else ""
        lines.append(f"- {'PASS' if gate['pass'] else 'BLOCKED'}: `{name}`{suffix}")
    lines.extend([
        "",
        "> This report is an engineering admission gate. Product rollout still requires internal experience review and rollback verification.",
        "",
    ])
    return "\n".join(lines)


def _expand_inputs(paths: list[Path]) -> list[Path]:
    expanded: list[Path] = []
    for path in paths:
        if path.is_dir():
            expanded.extend(sorted(path.rglob("device_shadow_summary.json")))
        else:
            expanded.append(path)
    return expanded


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", type=Path, nargs="+", help="Summary JSON files or directories")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--required-scenario",
        action="append",
        dest="required_scenarios",
        help="Override the default scenario set; repeat for each required category",
    )
    parser.add_argument("--minimum-device-classes", type=int, default=2)
    args = parser.parse_args()

    input_paths = _expand_inputs(args.inputs)
    if not input_paths:
        parser.error("no device_shadow_summary.json files found")
    summaries = [json.loads(path.read_text(encoding="utf-8")) for path in input_paths]
    report = build_gate_report(
        summaries,
        required_scenarios=args.required_scenarios or DEFAULT_REQUIRED_SCENARIOS,
        minimum_device_classes=args.minimum_device_classes,
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    json_path = args.output_dir / "device_shadow_admission.json"
    md_path = args.output_dir / "device_shadow_admission.md"
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(report), encoding="utf-8")
    print(json_path)
    print(md_path)
    return 0 if report["admission_pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
