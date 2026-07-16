#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture aggregate-only audio haptics shadow Logcat from one Android scenario."""

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


def find_adb() -> str:
    candidates = [shutil.which("adb")]
    for variable in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(variable):
            candidates.append(str(Path(os.environ[variable]) / "platform-tools" / "adb.exe"))
    candidates.append(str(Path.home() / "AppData" / "Local" / "Android" / "Sdk" / "platform-tools" / "adb.exe"))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    return "adb"


def adb_command(adb: str, serial: str | None, *arguments: str) -> list[str]:
    command = [adb]
    if serial:
        command.extend(["-s", serial])
    command.extend(arguments)
    return command


def run(adb: str, serial: str | None, *arguments: str) -> str:
    completed = subprocess.run(
        adb_command(adb, serial, *arguments),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=True,
        timeout=15,
    )
    return completed.stdout.strip()


def select_device(adb: str, requested: str | None) -> str:
    if requested:
        return requested
    devices = [
        line.split()[0]
        for line in run(adb, None, "devices").splitlines()[1:]
        if "\tdevice" in line
    ]
    if not devices:
        raise RuntimeError("no authorized Android device found")
    if len(devices) > 1:
        raise RuntimeError(f"found {len(devices)} Android devices; select one with --serial")
    return devices[0]


def getprop(adb: str, serial: str, name: str, fallback: str = "unknown") -> str:
    try:
        return run(adb, serial, "shell", "getprop", name) or fallback
    except (OSError, subprocess.SubprocessError):
        return fallback


def capture_logcat(adb: str, serial: str, duration_seconds: int) -> str:
    command = adb_command(
        adb,
        serial,
        "logcat",
        "-v",
        "threadtime",
        "-T",
        "1",
        "moonlight-haptics:I",
        "*:S",
    )
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
        raise RuntimeError(f"logcat capture failed ({process.returncode}): {stderr.strip()}")
    filtered = "\n".join(line for line in stdout.splitlines() if "[HAPTICS_SHADOW]" in line)
    return filtered + ("\n" if filtered else "")


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
    parser.add_argument("--serial")
    parser.add_argument("--adb", default=find_adb())
    parser.add_argument("--notes", default="")
    args = parser.parse_args()
    if args.duration_seconds < 5:
        parser.error("--duration-seconds must be at least 5")

    try:
        serial = select_device(args.adb, args.serial)
        now = datetime.now(timezone.utc).replace(microsecond=0)
        timestamp = now.strftime("%Y%m%dT%H%M%SZ")
        capture_id = f"android_{args.device_class}_{args.scenario_category}_{timestamp}"
        android_release = getprop(args.adb, serial, "ro.build.version.release")
        api_level = getprop(args.adb, serial, "ro.build.version.sdk")
        metadata = {
            "schema_version": 1,
            "capture_id": capture_id,
            "captured_at_utc": now.isoformat().replace("+00:00", "Z"),
            "device_id_hash": hashlib.sha256(serial.encode("utf-8")).hexdigest()[:12],
            "device_class": args.device_class,
            "model": getprop(args.adb, serial, "ro.product.model"),
            "os_version": f"Android {android_release} API {api_level}",
            "cpu_abi": getprop(args.adb, serial, "ro.product.cpu.abilist"),
            "scenario_id": args.scenario_id,
            "scenario_category": args.scenario_category,
            "sample_rate_hz": args.sample_rate_hz,
            "sdk_version": "0.3.0",
            "parameter_set_version": "game-p3-v1",
            "shadow_runtime_enabled": True,
            "source": "android_logcat_aggregate_only",
            "synthetic": False,
            "notes": args.notes,
        }
        print(f"Capturing {args.duration_seconds}s for {capture_id}; run the stream scenario now...", flush=True)
        filtered_log = capture_logcat(args.adb, serial, args.duration_seconds)
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        parser.error(str(exc))

    capture_dir = args.output_dir / capture_id
    capture_dir.mkdir(parents=True, exist_ok=False)
    (capture_dir / "shadow.logcat").write_text(filtered_log, encoding="utf-8")
    (capture_dir / "metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    snapshots = parse_snapshots(filtered_log.splitlines())
    if len(snapshots) < 2:
        parser.error(
            f"need at least two complete shadow snapshots for a window delta; "
            f"captured {len(snapshots)}; raw capture saved to {capture_dir}"
        )
    try:
        summary = build_summary(metadata, snapshots)
    except ValueError as exc:
        parser.error(f"{exc}; raw capture saved to {capture_dir}")
    (capture_dir / "device_shadow_summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    (capture_dir / "device_shadow_summary.md").write_text(render_markdown(summary), encoding="utf-8")
    print(capture_dir)
    return 0 if summary["capture_pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
