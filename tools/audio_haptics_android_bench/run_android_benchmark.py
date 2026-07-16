#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build, deploy, run, and report the portable SDK benchmark on Android."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
REMOTE_BINARY = "/data/local/tmp/audio_haptics_android_bench"


def run(command: list[str], timeout: int = 120, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        check=check,
    )


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


def _version_key(path: Path) -> tuple[int, ...]:
    return tuple(int(value) for value in re.findall(r"\d+", path.name))


def find_ndk() -> Path:
    for variable in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT"):
        if os.environ.get(variable):
            candidate = Path(os.environ[variable])
            if candidate.is_dir():
                return candidate
    roots = []
    for variable in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(variable):
            roots.append(Path(os.environ[variable]) / "ndk")
    roots.append(Path.home() / "AppData" / "Local" / "Android" / "Sdk" / "ndk")
    versions = [
        path
        for root in roots
        if root.is_dir()
        for path in root.iterdir()
        if path.is_dir() and (path / "build" / "cmake" / "android.toolchain.cmake").is_file()
    ]
    if not versions:
        raise RuntimeError("Android NDK not found; set ANDROID_NDK_HOME")
    return max(versions, key=_version_key)


def adb_command(adb: str, serial: str | None, *arguments: str) -> list[str]:
    command = [adb]
    if serial:
        command.extend(["-s", serial])
    command.extend(arguments)
    return command


def select_device(adb: str, requested: str | None) -> str:
    if requested:
        return requested
    output = run([adb, "devices"]).stdout.splitlines()[1:]
    devices = [line.split()[0] for line in output if "\tdevice" in line]
    if not devices:
        raise RuntimeError("no authorized Android device found")
    if len(devices) > 1:
        raise RuntimeError(f"found {len(devices)} Android devices; select one with --serial")
    return devices[0]


def getprop(adb: str, serial: str, name: str) -> str:
    return run(adb_command(adb, serial, "shell", "getprop", name), timeout=15).stdout.strip() or "unknown"


def battery_temperature(adb: str, serial: str) -> float | None:
    output = run(adb_command(adb, serial, "shell", "dumpsys", "battery"), timeout=15).stdout
    match = re.search(r"^\s*temperature:\s*(\d+)\s*$", output, re.MULTILINE)
    return int(match.group(1)) / 10.0 if match else None


def build_binary(ndk: Path, build_dir: Path, abi: str) -> Path:
    toolchain = ndk / "build" / "cmake" / "android.toolchain.cmake"
    if not toolchain.is_file():
        raise RuntimeError(f"invalid NDK, toolchain missing: {toolchain}")
    configure = [
        "cmake",
        "-S", str(SCRIPT_DIR),
        "-B", str(build_dir),
        "-G", "Ninja",
        f"-DCMAKE_TOOLCHAIN_FILE={toolchain}",
        f"-DANDROID_ABI={abi}",
        "-DANDROID_PLATFORM=android-23",
        "-DANDROID_STL=c++_static",
        "-DCMAKE_BUILD_TYPE=Release",
    ]
    run(configure, timeout=120)
    run(["cmake", "--build", str(build_dir)], timeout=180)
    binary = build_dir / "audio_haptics_android_bench"
    if not binary.is_file():
        raise RuntimeError(f"benchmark binary not produced: {binary}")
    return binary


def render_markdown(report: dict[str, Any]) -> str:
    metadata = report["metadata"]
    lines = [
        "# Android audio haptics SDK Core benchmark",
        "",
        f"Overall: **{'PASS' if report['android_core_gate_pass'] else 'BLOCKED'}**",
        "",
        f"- Device: `{metadata['manufacturer']} {metadata['model']}` (`{metadata['device_class']}`)",
        f"- Android/API/ABI: `{metadata['android_release']}` / `{metadata['api_level']}` / `{metadata['abi']}`",
        f"- SDK/parameters: `{report['benchmark']['sdk_version']}` / `{report['benchmark']['parameter_set_version']}`",
        f"- Duration gate: `{'PASS' if report['duration_gate']['pass'] else 'BLOCKED'}` "
        f"({report['duration_gate']['actual_seconds']} / {report['duration_gate']['required_seconds']} seconds per scenario)",
        f"- Battery temperature: `{metadata['battery_temperature_before_c']}` -> `{metadata['battery_temperature_after_c']}` °C",
        "",
        "| Scenario | Mean us | P95 us | P99 us | Max us | Realtime factor | Errors | Gate |",
        "|---|---:|---:|---:|---:|---:|---:|---|",
    ]
    gates = report["scenario_gates"]
    for scenario in report["benchmark"]["scenarios"]:
        gate = gates[scenario["name"]]
        lines.append(
            f"| {scenario['name']} | {scenario['mean_us']:.3f} | {scenario['p95_us']:.3f} | "
            f"{scenario['p99_us']:.3f} | {scenario['max_us']:.3f} | "
            f"{scenario['realtime_factor']:.1f}x | {scenario['errors']} | "
            f"{'PASS' if gate['pass'] else 'BLOCKED'} |"
        )
    lines.extend([
        "",
        "> This is an Android arm64 SDK Core CPU gate using deterministic synthetic workloads. It does not replace real-content accuracy evaluation or HarmonyOS actuator experience review.",
        "",
    ])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=SCRIPT_DIR / "out")
    parser.add_argument("--build-dir", type=Path, default=SCRIPT_DIR / "build" / "arm64-v8a")
    parser.add_argument("--device-class", default="android_phone_performance")
    parser.add_argument("--duration-seconds", type=int, default=5, help="Wall time per scenario")
    parser.add_argument("--minimum-gate-duration-seconds", type=int, default=10)
    parser.add_argument("--serial")
    parser.add_argument("--adb", default=find_adb())
    parser.add_argument("--ndk", type=Path)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    if args.duration_seconds < 1 or args.duration_seconds > 3600:
        parser.error("--duration-seconds must be between 1 and 3600")
    if args.minimum_gate_duration_seconds < 1:
        parser.error("--minimum-gate-duration-seconds must be positive")

    try:
        serial = select_device(args.adb, args.serial)
        abi_list = getprop(args.adb, serial, "ro.product.cpu.abilist")
        abi = "arm64-v8a" if "arm64-v8a" in abi_list.split(",") else abi_list.split(",")[0]
        ndk = args.ndk or find_ndk()
        binary = args.build_dir / "audio_haptics_android_bench" if args.skip_build else build_binary(
            ndk, args.build_dir, abi
        )
        if not binary.is_file():
            raise RuntimeError(f"benchmark binary not found: {binary}")

        run(adb_command(args.adb, serial, "push", str(binary), REMOTE_BINARY), timeout=60)
        run(adb_command(args.adb, serial, "shell", "chmod", "755", REMOTE_BINARY), timeout=15)
        temperature_before = battery_temperature(args.adb, serial)
        completed = run(
            adb_command(
                args.adb,
                serial,
                "shell",
                REMOTE_BINARY,
                "--duration-seconds",
                str(args.duration_seconds),
            ),
            timeout=args.duration_seconds * 5 + 60,
        )
        temperature_after = battery_temperature(args.adb, serial)
        benchmark = json.loads(completed.stdout)
    except (OSError, RuntimeError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        parser.error(str(exc))

    scenario_gates = {
        scenario["name"]: {
            "pass": scenario["errors"] == 0 and scenario["p99_us"] <= 500.0,
            "errors_zero": scenario["errors"] == 0,
            "p99_process_le_500_us": scenario["p99_us"] <= 500.0,
        }
        for scenario in benchmark["scenarios"]
    }
    duration_gate = {
        "pass": args.duration_seconds >= args.minimum_gate_duration_seconds,
        "actual_seconds": args.duration_seconds,
        "required_seconds": args.minimum_gate_duration_seconds,
    }
    now = datetime.now(timezone.utc).replace(microsecond=0)
    metadata = {
        "schema_version": 1,
        "captured_at_utc": now.isoformat().replace("+00:00", "Z"),
        "device_id_hash": hashlib.sha256(serial.encode("utf-8")).hexdigest()[:12],
        "device_class": args.device_class,
        "manufacturer": getprop(args.adb, serial, "ro.product.manufacturer"),
        "model": getprop(args.adb, serial, "ro.product.model"),
        "android_release": getprop(args.adb, serial, "ro.build.version.release"),
        "api_level": int(getprop(args.adb, serial, "ro.build.version.sdk")),
        "abi": abi,
        "ndk_version": ndk.name,
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "battery_temperature_before_c": temperature_before,
        "battery_temperature_after_c": temperature_after,
    }
    report = {
        "schema_version": 1,
        "metadata": metadata,
        "benchmark": benchmark,
        "scenario_gates": scenario_gates,
        "duration_gate": duration_gate,
        "android_core_gate_pass": duration_gate["pass"] and all(
            gate["pass"] for gate in scenario_gates.values()
        ),
        "scope": {
            "validates": ["Android arm64 SDK Core CPU latency", "long-running process stability", "C ABI compatibility"],
            "does_not_validate": ["real-content accuracy", "Android vibrator experience", "HarmonyOS actuator experience"],
        },
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    json_path = args.output_dir / "android_core_benchmark.json"
    markdown_path = args.output_dir / "android_core_benchmark.md"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    markdown_path.write_text(render_markdown(report), encoding="utf-8")
    print(json_path)
    print(markdown_path)
    return 0 if report["android_core_gate_pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
