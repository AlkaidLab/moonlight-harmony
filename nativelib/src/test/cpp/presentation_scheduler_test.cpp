#include "presentation_scheduler.h"

#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdlib>
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

void TestAccumulatedPhaseShiftRecoversQuickly() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    constexpr int64_t kStartNs = 1000 * kMs;
    constexpr int64_t kFrameUs = 16667;
    scheduler.PlanFrame(0, kStartNs);

    int phaseShiftCount = 0;
    for (int i = 1; i <= 12; ++i) {
        const int64_t ptsUs = i * kFrameUs;
        const int64_t nominalDecodeNs = kStartNs + ptsUs * 1000;
        const int64_t rampDelayNs = (20 + (i - 1) * 6) * kMs;
        const PresentationPlan delayed = scheduler.PlanFrame(
            ptsUs, nominalDecodeNs + rampDelayNs);
        assert(delayed.action == PresentationAction::SCHEDULE);
        if (delayed.event == PresentationEvent::PHASE_SHIFT) {
            phaseShiftCount++;
        }
    }
    assert(phaseShiftCount >= 10);

    const int64_t recoveredPtsUs = 13 * kFrameUs;
    const int64_t recoveredDecodeNs = kStartNs + recoveredPtsUs * 1000;
    const PresentationPlan recovered = scheduler.PlanFrame(
        recoveredPtsUs, recoveredDecodeNs);

    assert(recovered.action == PresentationAction::SCHEDULE);
    assert(recovered.event == PresentationEvent::PHASE_SHIFT);
    assert(recovered.latenessNs < 0);
    assert(std::llabs((recovered.targetTimeNs - recoveredDecodeNs) -
                      scheduler.GetInitialLeadNs()) < kMs);

    const int64_t nextPtsUs = 14 * kFrameUs;
    const int64_t nextDecodeNs = kStartNs + nextPtsUs * 1000;
    const PresentationPlan next = scheduler.PlanFrame(nextPtsUs, nextDecodeNs);
    assert(next.action == PresentationAction::SCHEDULE);
    assert(std::llabs((next.targetTimeNs - recovered.targetTimeNs) -
                      kFrameUs * 1000) < kMs);
}

void TestDuplicatePtsReanchorsInsteadOfFreezing() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    scheduler.PlanFrame(1000, 1000 * kMs);
    const PresentationPlan firstDuplicate = scheduler.PlanFrame(1000, 1017 * kMs);
    const PresentationPlan secondDuplicate = scheduler.PlanFrame(1000, 1034 * kMs);

    assert(firstDuplicate.action == PresentationAction::SCHEDULE);
    assert(firstDuplicate.event == PresentationEvent::DUPLICATE_PTS);
    assert(secondDuplicate.action == PresentationAction::SCHEDULE);
    assert(secondDuplicate.event == PresentationEvent::DUPLICATE_PTS);
    assert(secondDuplicate.targetTimeNs > firstDuplicate.targetTimeNs);
}

void TestDiscontinuityReanchors() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(59.94);

    scheduler.PlanFrame(1000000, 2000 * kMs);
    const PresentationPlan discontinuity = scheduler.PlanFrame(500000, 2010 * kMs);

    assert(discontinuity.action == PresentationAction::SCHEDULE);
    assert(discontinuity.event == PresentationEvent::DISCONTINUITY);
}

void TestFractionalFpsLead() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(59.94);

    const int64_t decodedAtNs = 2000 * kMs;
    const PresentationPlan first = scheduler.PlanFrame(0, decodedAtNs);
    const int64_t expectedLeadNs = static_cast<int64_t>(
        std::llround(1000000000.0 / 59.94)) + 2 * kMs;

    assert(first.action == PresentationAction::SCHEDULE);
    assert(first.targetTimeNs - decodedAtNs == expectedLeadNs);
}

void TestSlowClockDriftStaysBounded() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    constexpr int64_t kStartNs = 1000 * kMs;
    constexpr double kPtsIntervalUs = 1000000.0 / 60.0;
    constexpr double kFastLocalIntervalNs = 1000000000.0 / 60.0 * (1.0 - 0.0001);
    scheduler.PlanFrame(0, kStartNs);

    PresentationPlan plan;
    int64_t decodedAtNs = kStartNs;
    for (int i = 1; i <= 20000; ++i) {
        const int64_t ptsUs = static_cast<int64_t>(std::llround(i * kPtsIntervalUs));
        decodedAtNs = kStartNs + static_cast<int64_t>(std::llround(i * kFastLocalIntervalNs));
        plan = scheduler.PlanFrame(ptsUs, decodedAtNs);
        assert(plan.action == PresentationAction::SCHEDULE);
    }

    const int64_t finalLeadNs = plan.targetTimeNs - decodedAtNs;
    const int64_t expectedLeadNs = scheduler.GetInitialLeadNs();
    assert(std::llabs(finalLeadNs - expectedLeadNs) < 5 * kMs);
}
} // namespace

int main() {
    TestBurstKeepsPtsCadence();
    TestSmallLateFrameShiftsWholeTimeline();
    TestSevereLateDropThenRebuffer();
    TestAccumulatedPhaseShiftRecoversQuickly();
    TestDuplicatePtsReanchorsInsteadOfFreezing();
    TestDiscontinuityReanchors();
    TestFractionalFpsLead();
    TestSlowClockDriftStaysBounded();
    std::cout << "presentation scheduler tests passed\n";
    return 0;
}
