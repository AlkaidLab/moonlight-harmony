#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture aggregate-only audio haptics shadow HiLog from one HarmonyOS scenario."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from device_shadow_log import build_summary, parse_snapshots, render_markdown


def find_hdc() -> str:
    candidates = [shutil.which("hdc")]
    sdk_home = os.environ.get("DEVECO_SDK_HOME") or os.environ.get("OHOS_SDK_HOME")
    if sdk_home:
        candidates.append(str(Path(sdk_home) / "openharmony" / "toolchains" / "hdc.exe"))
        candidates.append(str(Path(sdk_home) / "toolchains" / "hdc.exe"))
    candidates.append(
        r"C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
    )
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    return "hdc"


def _run(hdc: str, serial: str | None, *args: str) -> str:
    command = [hdc]
    if serial:
        command.extend(["-t", serial])
    command.extend(args)
    completed = subprocess.run(command, capture_output=True, text=True, check=True, timeout=15)
    return completed.stdout.strip()


def _property(hdc: str, serial: str | None, name: str, fallback: str) -> str:
    try:
        value = _run(hdc, serial, "shell", "param", "get", name)
        return value or fallback
    except (OSError, subprocess.SubprocessError):
        return fallback


def _resolve_serial(hdc: str, requested: str | None) -> str:
    if requested:
        return requested
    targets = [line.strip() for line in _run(hdc, None, "list", "targets").splitlines()]
    targets = [target for target in targets if target and target != "[Empty]"]
    if not targets:
        raise RuntimeError("no HDC target found; connect and authorize a HarmonyOS device")
    if len(targets) > 1:
        raise RuntimeError(f"found {len(targets)} HDC targets; select one with --serial")
    return targets[0]


def capture_hilog(hdc: str, serial: str, duration_seconds: int) -> tuple[str, int]:
    command = [hdc, "-t", serial, "shell", "hilog"]
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=duration_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.terminate()
        stdout, stderr = process.communicate(timeout=10)
    if not timed_out and process.returncode != 0:
        raise RuntimeError(f"hilog capture failed ({process.returncode}): {stderr.strip()}")
    filtered = "\n".join(line for line in stdout.splitlines() if "[HAPTICS_SHADOW]" in line)
    if filtered:
        filtered += "\n"
    return filtered, process.returncode or 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--device-class", required=True)
    parser.add_argument("--scenario-id", required=True)
    parser.add_argument(
        "--scenario-category",
        required=True,
        choices=(
            "game_strong_transient",
            "continuous_low_frequency",
            "music",
            "speech",
            "silence_noise_floor",
            "stream_reconnect",
        ),
    )
    parser.add_argument("--duration-seconds", type=int, default=60)
    parser.add_argument("--sample-rate-hz", type=int, default=48000)
    parser.add_argument("--serial", help="HDC target; omitted when exactly one device is connected")
    parser.add_argument("--hdc", default=find_hdc())
    parser.add_argument("--notes", default="")
    args = parser.parse_args()

    if args.duration_seconds < 5:
        parser.error("--duration-seconds must be at least 5")

    try:
        serial = _resolve_serial(args.hdc, args.serial)
        now = datetime.now(timezone.utc).replace(microsecond=0)
        timestamp = now.strftime("%Y%m%dT%H%M%SZ")
        capture_id = f"{args.device_class}_{args.scenario_category}_{timestamp}"
        device_hash = hashlib.sha256(serial.encode("utf-8")).hexdigest()[:12]
        metadata = {
            "schema_version": 1,
            "capture_id": capture_id,
            "captured_at_utc": now.isoformat().replace("+00:00", "Z"),
            "device_id_hash": device_hash,
            "device_class": args.device_class,
            "model": _property(args.hdc, serial, "const.product.model", "unknown"),
            "os_version": _property(args.hdc, serial, "const.ohos.fullname", "unknown"),
            "cpu_abi": _property(args.hdc, serial, "const.product.cpu.abilist", "unknown"),
            "scenario_id": args.scenario_id,
            "scenario_category": args.scenario_category,
            "sample_rate_hz": args.sample_rate_hz,
            "sdk_version": "0.3.0",
            "parameter_set_version": "game-p3-v1",
            "shadow_runtime_enabled": True,
            "source": "hilog_aggregate_only",
            "synthetic": False,
            "notes": args.notes,
        }
        print(f"Capturing {args.duration_seconds}s for {capture_id}; run the scenario now...", flush=True)
        filtered_log, _ = capture_hilog(args.hdc, serial, args.duration_seconds)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
        parser.error(str(exc))

    capture_dir = args.output_dir / capture_id
    capture_dir.mkdir(parents=True, exist_ok=False)
    (capture_dir / "shadow.hilog").write_text(filtered_log, encoding="utf-8")
    (capture_dir / "metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    try:
        snapshots = parse_snapshots(filtered_log.splitlines())
        summary = build_summary(metadata, snapshots)
    except ValueError as exc:
        parser.error(f"{exc}; raw filtered capture saved to {capture_dir}")
    (capture_dir / "device_shadow_summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    (capture_dir / "device_shadow_summary.md").write_text(render_markdown(summary), encoding="utf-8")
    print(capture_dir)
    return 0 if summary["capture_pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
