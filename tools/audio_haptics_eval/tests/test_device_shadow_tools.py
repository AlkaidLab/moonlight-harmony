#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later

from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from device_shadow_gate import build_gate_report  # noqa: E402
from device_shadow_log import build_summary, parse_snapshots, p99_bucket_upper_bound  # noqa: E402


def metadata(capture_id: str = "capture-a", device_class: str = "phone") -> dict:
    return {
        "schema_version": 1,
        "capture_id": capture_id,
        "captured_at_utc": "2026-07-15T00:00:00Z",
        "device_id_hash": "0123456789ab",
        "device_class": device_class,
        "model": "test-model",
        "os_version": "test-os",
        "cpu_abi": "arm64-v8a",
        "scenario_id": "test-game",
        "scenario_category": "game_strong_transient",
        "sample_rate_hz": 48000,
        "sdk_version": "0.3.0",
        "parameter_set_version": "game-p3-v1",
        "shadow_runtime_enabled": True,
        "source": "hilog_aggregate_only",
        "synthetic": False,
    }


PASS_LOG = """
07-15 10:00:00.000 100 100 I Moonlight: unrelated
07-15 10:00:01.000 100 100 I Moonlight: [HAPTICS_SHADOW] blocks=50 frames=24000 ref=3 sdk=3 matched=3 refOnly=0 sdkOnly=0 pending=0/0 totalUs=4000 meanUs=80 maxUs=420 errors=0
07-15 10:00:01.001 100 100 I Moonlight: [HAPTICS_SHADOW] latencyBucketsUs le50=20 le100=20 le200=8 le500=2 le1000=0 gt1000=0 matchDeltaSumUs=150 matchDeltaAbsMaxUs=70
07-15 10:00:02.000 100 100 I Moonlight: [HAPTICS_SHADOW] blocks=100 frames=48000 ref=6 sdk=7 matched=6 refOnly=0 sdkOnly=1 pending=0/0 totalUs=8200 meanUs=82 maxUs=440 errors=0
07-15 10:00:02.001 100 100 I Moonlight: [HAPTICS_SHADOW] latencyBucketsUs le50=40 le100=40 le200=15 le500=5 le1000=0 gt1000=0 matchDeltaSumUs=240 matchDeltaAbsMaxUs=80
"""


class DeviceShadowLogTest(unittest.TestCase):
    def test_parses_prefixed_hilog_and_derives_conservative_p99(self) -> None:
        snapshots = parse_snapshots(PASS_LOG.splitlines())
        self.assertEqual(2, len(snapshots))
        summary = build_summary(metadata(), snapshots)
        self.assertTrue(summary["capture_pass"])
        self.assertEqual(500, summary["derived"]["p99_process_us_upper_bound"])
        self.assertEqual(0.5, summary["duration_seconds_from_frames"])
        self.assertEqual(84, summary["metrics"]["mean_process_us"])
        self.assertEqual(30.0, summary["derived"]["mean_match_delta_us"])

    def test_open_ended_p99_bucket_fails_latency_gate(self) -> None:
        histogram = {"le50": 0, "le100": 0, "le200": 0, "le500": 0, "le1000": 98, "gt1000": 2}
        self.assertIsNone(p99_bucket_upper_bound(histogram, 100))

    def test_counter_reset_selects_final_runtime_run(self) -> None:
        reset_log = PASS_LOG + PASS_LOG.replace("blocks=50", "blocks=10").replace("le50=20", "le50=10").replace("le100=20", "le100=0").replace("le200=8", "le200=0").replace("le500=2", "le500=0")
        snapshots = parse_snapshots(reset_log.splitlines())
        self.assertEqual(2, len(snapshots))
        self.assertEqual(10, snapshots[0]["blocks"])

    def test_histogram_count_mismatch_blocks_capture(self) -> None:
        broken_log = PASS_LOG.replace("le500=5", "le500=4")
        summary = build_summary(metadata(), parse_snapshots(broken_log.splitlines()))
        self.assertFalse(summary["capture_pass"])
        self.assertFalse(summary["gates"]["histogram_consistent"]["pass"])

    def test_android_logcat_source_and_platform_prefix(self) -> None:
        android_metadata = metadata()
        android_metadata["source"] = "android_logcat_aggregate_only"
        android_log = PASS_LOG.replace(
            "[HAPTICS_SHADOW] blocks=", "[HAPTICS_SHADOW] platform=android blocks="
        )
        summary = build_summary(android_metadata, parse_snapshots(android_log.splitlines()))
        self.assertTrue(summary["capture_pass"])


class DeviceShadowGateTest(unittest.TestCase):
    def test_two_real_device_classes_pass_reduced_test_coverage(self) -> None:
        first = build_summary(metadata("capture-a", "phone"), parse_snapshots(PASS_LOG.splitlines()))
        second_metadata = metadata("capture-b", "tablet")
        second_metadata["device_id_hash"] = "abcdef012345"
        second = build_summary(second_metadata, parse_snapshots(PASS_LOG.splitlines()))
        report = build_gate_report(
            [first, second],
            required_scenarios=["game_strong_transient"],
        )
        self.assertTrue(report["admission_pass"])

    def test_synthetic_capture_never_opens_real_device_gate(self) -> None:
        item = build_summary(metadata(), parse_snapshots(PASS_LOG.splitlines()))
        item = copy.deepcopy(item)
        item["metadata"]["synthetic"] = True
        report = build_gate_report(
            [item],
            required_scenarios=["game_strong_transient"],
            minimum_device_classes=1,
        )
        self.assertFalse(report["admission_pass"])
        self.assertFalse(report["gates"]["real_device_data_only"]["pass"])


if __name__ == "__main__":
    unittest.main()
