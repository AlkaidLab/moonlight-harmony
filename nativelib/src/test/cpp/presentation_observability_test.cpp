#include "rolling_frame_rate.h"

#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>

namespace {
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

void TestRollingRateExcludesOldCadence() {
    RollingFrameRateTracker tracker;
    tracker.Record(500, 500);
    tracker.Record(1100, 510);
    tracker.Record(2000, 600);
    tracker.Record(3000, 700);
    tracker.Record(4000, 800);

    AssertNear(tracker.GetRate(4000), 100.0, 0.1);
}

} // namespace

int main() {
    TestRollingRateTracksSteadyCadence();
    TestRollingRateAbsorbsGroupedCallbacks();
    TestRollingRateResetsWithCounter();
    TestRollingRateExcludesOldCadence();
    std::cout << "presentation observability tests passed\n";
    return 0;
}
