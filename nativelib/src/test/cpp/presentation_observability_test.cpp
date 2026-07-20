#include "presentation_diagnostics.h"
#include "rolling_frame_rate.h"

#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>

namespace {
constexpr int64_t kMs = 1000000LL;

void AssertNear(double actual, double expected, double tolerance) {
    assert(std::fabs(actual - expected) <= tolerance);
}

void TestRollingRateTracksSteadyCadence() {
    RollingFrameRateTracker tracker;
    for (uint64_t frame = 1; frame <= 360; ++frame) {
        const int64_t timestampMs = static_cast<int64_t>(
            std::llround(static_cast<double>(frame - 1) * 1000.0 / 120.0));
        tracker.Record(timestampMs, frame);
    }

    AssertNear(tracker.GetRate(3000), 120.0, 1.0);
}

void TestRollingRateAbsorbsGroupedCallbacks() {
    RollingFrameRateTracker tracker;
    uint64_t frames = 0;
    for (int group = 0; group < 90; ++group) {
        frames += 4;
        const int64_t timestampMs = static_cast<int64_t>(
            std::llround(static_cast<double>(group) * 1000.0 / 30.0));
        tracker.Record(timestampMs, frames);
    }

    AssertNear(tracker.GetRate(3000), 120.0, 0.1);
    assert(tracker.GetRate(3200) < 115.0);
    assert(tracker.GetRate(6000) == 0.0);
}

void TestRollingRateResetsWithCounter() {
    RollingFrameRateTracker tracker;
    tracker.Record(1000, 120);
    tracker.Record(2000, 240);
    tracker.Record(3000, 1);
    tracker.Record(4000, 121);

    AssertNear(tracker.GetRate(4000), 120.0, 0.1);
}

void TestPresentationDiagnosticsTrackSlotConflicts() {
    PresentationDiagnostics diagnostics;
    constexpr int64_t kPeriodNs = 8333333;
    constexpr int64_t kVsyncNs = 1000 * kMs;

    diagnostics.Record(kVsyncNs + 2 * kMs, kVsyncNs,
                       kVsyncNs, kPeriodNs);
    diagnostics.Record(kVsyncNs + 4 * kMs, kVsyncNs + kMs,
                       kVsyncNs, kPeriodNs);
    diagnostics.Record(kVsyncNs + 27 * kMs, kVsyncNs + 2 * kMs,
                       kVsyncNs, kPeriodNs);
    diagnostics.Record(kVsyncNs + 3 * kMs, kVsyncNs + 3 * kMs,
                       kVsyncNs, kPeriodNs);

    const PresentationTimingStats& stats = diagnostics.GetStats();
    assert(stats.sameVsyncSlotCount == 1);
    assert(stats.targetRegressionCount == 1);
    assert(stats.maxTargetRegressionNs == 24 * kMs);
    assert(stats.vsyncSlotRegressionCount == 1);
    assert(stats.maxQueueDepthSlots == 4);
}
} // namespace

int main() {
    TestRollingRateTracksSteadyCadence();
    TestRollingRateAbsorbsGroupedCallbacks();
    TestRollingRateResetsWithCounter();
    TestPresentationDiagnosticsTrackSlotConflicts();
    std::cout << "presentation observability tests passed\n";
    return 0;
}
