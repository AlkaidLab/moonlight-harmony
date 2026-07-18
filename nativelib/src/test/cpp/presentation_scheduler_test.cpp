#include "presentation_scheduler.h"

#include <cassert>
#include <cstdint>
#include <iostream>

namespace {
constexpr int64_t kMs = 1000000LL;

void TestBurstKeepsPtsCadence() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    const PresentationPlan first = scheduler.PlanFrame(0, 1000 * kMs);
    const PresentationPlan second = scheduler.PlanFrame(16667, 1000 * kMs);
    const PresentationPlan third = scheduler.PlanFrame(33333, 1001 * kMs);

    assert(first.action == PresentationAction::SCHEDULE);
    assert(second.action == PresentationAction::SCHEDULE);
    assert(third.action == PresentationAction::SCHEDULE);
    assert(second.targetTimeNs - first.targetTimeNs == 16667000LL);
    assert(third.targetTimeNs - second.targetTimeNs == 16666000LL);
}

void TestSmallLateFrameShiftsWholeTimeline() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    const PresentationPlan first = scheduler.PlanFrame(0, 1000 * kMs);
    const PresentationPlan shifted = scheduler.PlanFrame(16667, 1034 * kMs);
    const PresentationPlan next = scheduler.PlanFrame(33333, 1035 * kMs);

    assert(shifted.action == PresentationAction::SCHEDULE);
    assert(shifted.event == PresentationEvent::PHASE_SHIFT);
    assert(next.action == PresentationAction::SCHEDULE);
    assert(next.targetTimeNs - shifted.targetTimeNs == 16666000LL);
    assert(shifted.targetTimeNs >= 1035 * kMs);
    assert(first.targetTimeNs < shifted.targetTimeNs);
}

void TestSevereLateDropThenRebuffer() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    scheduler.PlanFrame(0, 1000 * kMs);
    const PresentationPlan dropped = scheduler.PlanFrame(16667, 1100 * kMs);
    const PresentationPlan rebuffered = scheduler.PlanFrame(33333, 1101 * kMs);

    assert(dropped.action == PresentationAction::DROP);
    assert(dropped.event == PresentationEvent::LATE_DROP);
    assert(rebuffered.action == PresentationAction::SCHEDULE);
    assert(rebuffered.event == PresentationEvent::REBUFFER);
    assert(rebuffered.targetTimeNs > 1101 * kMs);
}

void TestDiscontinuityReanchors() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(59.94);

    scheduler.PlanFrame(1000000, 2000 * kMs);
    const PresentationPlan discontinuity = scheduler.PlanFrame(500000, 2010 * kMs);

    assert(discontinuity.action == PresentationAction::SCHEDULE);
    assert(discontinuity.event == PresentationEvent::DISCONTINUITY);
}
} // namespace

int main() {
    TestBurstKeepsPtsCadence();
    TestSmallLateFrameShiftsWholeTimeline();
    TestSevereLateDropThenRebuffer();
    TestDiscontinuityReanchors();
    std::cout << "presentation scheduler tests passed\n";
    return 0;
}
