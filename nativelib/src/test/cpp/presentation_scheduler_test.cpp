#include "presentation_scheduler.h"

#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {
constexpr int64_t kNanosecondsPerSecond = 1000000000LL;
constexpr int64_t kNanosecondsPerMicrosecond = 1000LL;
constexpr int64_t kMs = 1000000LL;
constexpr int64_t kStartNs = 1000 * kMs;

int64_t FrameIntervalNs(double fps) {
    return static_cast<int64_t>(
        std::llround(static_cast<double>(kNanosecondsPerSecond) / fps));
}

void TestStableBaselineLead() {
    for (double fps : {30.0, 59.94, 60.0, 90.0, 119.88, 120.0}) {
        PtsPresentationScheduler scheduler;
        scheduler.Configure(fps);
        assert(scheduler.GetInitialLeadNs() == FrameIntervalNs(fps) + 2 * kMs);
    }
}

void TestInitialTargetUsesPtsTimelineWithoutSlotQuantization() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(120.0);
    const int64_t decodedAtNs = kStartNs + kMs;

    const PresentationPlan first = scheduler.PlanFrame(0, decodedAtNs);

    assert(first.action == PresentationAction::SCHEDULE);
    assert(first.event == PresentationEvent::INITIAL_ANCHOR);
    assert(first.targetTimeNs == decodedAtNs + scheduler.GetInitialLeadNs());
}

void Test120FpsBurstKeepsPtsCadence() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(120.0);
    const int64_t decodedAtNs = kStartNs + kMs;
    constexpr int64_t kPtsUs[] = {0, 8334, 16667, 25000, 33333};

    PresentationPlan previous;
    for (size_t i = 0; i < std::size(kPtsUs); ++i) {
        const PresentationPlan current = scheduler.PlanFrame(
            kPtsUs[i], decodedAtNs);
        assert(current.action == PresentationAction::SCHEDULE);
        if (i > 0) {
            assert(current.targetTimeNs - previous.targetTimeNs ==
                (kPtsUs[i] - kPtsUs[i - 1]) * kNanosecondsPerMicrosecond);
        }
        previous = current;
    }

    const PresentationPlan caughtUp = scheduler.PlanFrame(
        41667, decodedAtNs + 41667 * kNanosecondsPerMicrosecond);
    assert(caughtUp.action == PresentationAction::SCHEDULE);
    assert(caughtUp.targetTimeNs - previous.targetTimeNs ==
        (41667 - kPtsUs[4]) * kNanosecondsPerMicrosecond);
}

void TestSubFrame120FpsJitterIsAbsorbedByReserve() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(120.0);
    const int64_t frameIntervalNs = FrameIntervalNs(120.0);
    const int64_t firstDecodedAtNs = kStartNs + kMs;

    const PresentationPlan first = scheduler.PlanFrame(0, firstDecodedAtNs);
    const PresentationPlan jittered = scheduler.PlanFrame(
        8334, firstDecodedAtNs + frameIntervalNs + 5 * kMs);

    assert(first.action == PresentationAction::SCHEDULE);
    assert(jittered.action == PresentationAction::SCHEDULE);
    assert(jittered.event == PresentationEvent::NONE);
    assert(jittered.targetTimeNs - first.targetTimeNs == 8334 * kNanosecondsPerMicrosecond);
    assert(jittered.targetTimeNs > firstDecodedAtNs + frameIntervalNs + 5 * kMs);
}

void TestSustained120FpsPeriodicJitterDoesNotDrop() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(120.0);
    constexpr double kPtsIntervalUs = 1000000.0 / 120.0;
    const int64_t frameIntervalNs = FrameIntervalNs(120.0);
    const int64_t firstDecodedAtNs = kStartNs + kMs;

    PresentationPlan previous = scheduler.PlanFrame(0, firstDecodedAtNs);
    for (int i = 1; i <= 1201; ++i) {
        const int64_t ptsUs = static_cast<int64_t>(
            std::llround(i * kPtsIntervalUs));
        const int64_t jitterNs = i % 120 == 0 ? 5 * kMs : 0;
        const int64_t decodedAtNs =
            firstDecodedAtNs + i * frameIntervalNs + jitterNs;
        const PresentationPlan current = scheduler.PlanFrame(ptsUs, decodedAtNs);

        assert(current.action == PresentationAction::SCHEDULE);
        assert(current.targetTimeNs > previous.targetTimeNs);
        previous = current;
    }
}

void TestSmallLateFrameShiftsWholeTimeline() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    const PresentationPlan first = scheduler.PlanFrame(0, kStartNs);
    const PresentationPlan shifted = scheduler.PlanFrame(
        16667, kStartNs + 37 * kMs);
    const PresentationPlan next = scheduler.PlanFrame(
        33333, kStartNs + 53 * kMs);

    assert(first.action == PresentationAction::SCHEDULE);
    assert(shifted.action == PresentationAction::SCHEDULE);
    assert(shifted.event == PresentationEvent::PHASE_SHIFT);
    assert(shifted.latenessNs > 0);
    assert(shifted.latenessNs <= FrameIntervalNs(60.0) / 2);
    assert(next.action == PresentationAction::SCHEDULE);
    assert(next.targetTimeNs - shifted.targetTimeNs == 16666 * kNanosecondsPerMicrosecond);
}

void TestLateShiftDebtIsReclaimedAfterRecovery() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    scheduler.PlanFrame(0, kStartNs);
    const PresentationPlan shifted = scheduler.PlanFrame(
        16667, kStartNs + 36 * kMs);
    const PresentationPlan recovered = scheduler.PlanFrame(
        50000, kStartNs + 50 * kMs);

    assert(shifted.action == PresentationAction::SCHEDULE);
    assert(shifted.event == PresentationEvent::PHASE_SHIFT);
    assert(shifted.latenessNs > 0);
    assert(recovered.action == PresentationAction::SCHEDULE);
    assert(recovered.event == PresentationEvent::PHASE_SHIFT);
    assert(recovered.latenessNs == -shifted.latenessNs);
    assert(std::llabs(
        recovered.targetTimeNs - (kStartNs + 50 * kMs) -
        scheduler.GetInitialLeadNs()) <= kNanosecondsPerMicrosecond);
}

void TestSevereLateFrameDropsThenReanchorsNextFrame() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    scheduler.PlanFrame(0, kStartNs);
    const int64_t decodedAtNs = kStartNs + 100 * kMs;
    const PresentationPlan dropped = scheduler.PlanFrame(16667, decodedAtNs);
    const PresentationPlan rebuffered = scheduler.PlanFrame(
        33333, decodedAtNs + kMs);

    assert(dropped.action == PresentationAction::DROP);
    assert(dropped.event == PresentationEvent::LATE_DROP);
    assert(dropped.latenessNs > FrameIntervalNs(60.0) / 2);
    assert(rebuffered.action == PresentationAction::SCHEDULE);
    assert(rebuffered.event == PresentationEvent::REBUFFER);
    assert(rebuffered.latenessNs > FrameIntervalNs(60.0) / 2);
    assert(rebuffered.targetTimeNs ==
        decodedAtNs + kMs + scheduler.GetInitialLeadNs());
}

void TestSingleSevereLateSpikeKeepsUsableTimeline() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    const PresentationPlan first = scheduler.PlanFrame(0, kStartNs);
    const PresentationPlan dropped = scheduler.PlanFrame(
        16667, kStartNs + 100 * kMs);
    const PresentationPlan recovered = scheduler.PlanFrame(
        100000, kStartNs + 101 * kMs);

    assert(dropped.action == PresentationAction::DROP);
    assert(dropped.event == PresentationEvent::LATE_DROP);
    assert(recovered.action == PresentationAction::SCHEDULE);
    assert(recovered.event == PresentationEvent::NONE);
    assert(recovered.targetTimeNs - first.targetTimeNs == 100 * kMs);
}

void TestDuplicatePtsReanchorsWithoutDropping() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    scheduler.PlanFrame(1000, kStartNs);
    const PresentationPlan firstDuplicate = scheduler.PlanFrame(
        1000, kStartNs + 17 * kMs);
    const PresentationPlan secondDuplicate = scheduler.PlanFrame(
        1000, kStartNs + 34 * kMs);

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
    const int64_t decodedAtNs = 2010 * kMs;
    const PresentationPlan discontinuity = scheduler.PlanFrame(500000, decodedAtNs);

    assert(discontinuity.action == PresentationAction::SCHEDULE);
    assert(discontinuity.event == PresentationEvent::DISCONTINUITY);
    assert(discontinuity.targetTimeNs == decodedAtNs + scheduler.GetInitialLeadNs());
}

void TestNtscCadencePreservesPtsIntervals() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(119.88);
    constexpr double kPtsIntervalUs = 1000000.0 / 119.88;
    const int64_t firstDecodedAtNs = kStartNs + kMs;

    int64_t previousPtsUs = 0;
    PresentationPlan previous = scheduler.PlanFrame(0, firstDecodedAtNs);
    for (int i = 1; i <= 2500; ++i) {
        const int64_t ptsUs = static_cast<int64_t>(
            std::llround(i * kPtsIntervalUs));
        const int64_t decodedAtNs =
            firstDecodedAtNs + ptsUs * kNanosecondsPerMicrosecond;
        const PresentationPlan current = scheduler.PlanFrame(ptsUs, decodedAtNs);

        assert(current.action == PresentationAction::SCHEDULE);
        assert(current.targetTimeNs - previous.targetTimeNs ==
            (ptsUs - previousPtsUs) * kNanosecondsPerMicrosecond);
        previousPtsUs = ptsUs;
        previous = current;
    }
}

void TestSlowClockDriftStaysBounded() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);
    constexpr double kPtsIntervalUs = 1000000.0 / 60.0;
    constexpr double kFastLocalIntervalNs =
        1000000000.0 / 60.0 * (1.0 - 0.0001);
    scheduler.PlanFrame(0, kStartNs);

    PresentationPlan plan;
    int64_t decodedAtNs = kStartNs;
    for (int i = 1; i <= 20000; ++i) {
        const int64_t ptsUs = static_cast<int64_t>(
            std::llround(i * kPtsIntervalUs));
        decodedAtNs = kStartNs + static_cast<int64_t>(
            std::llround(i * kFastLocalIntervalNs));
        plan = scheduler.PlanFrame(ptsUs, decodedAtNs);
        assert(plan.action == PresentationAction::SCHEDULE);
    }

    assert(std::llabs((plan.targetTimeNs - decodedAtNs) -
                      scheduler.GetInitialLeadNs()) < 5 * kMs);
}

void TestInvalidPtsDropsWithoutScheduling() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    const PresentationPlan invalid = scheduler.PlanFrame(-1, kStartNs);
    assert(invalid.action == PresentationAction::DROP);
    assert(invalid.event == PresentationEvent::INVALID_PTS);
}
} // namespace

int main() {
    TestStableBaselineLead();
    TestInitialTargetUsesPtsTimelineWithoutSlotQuantization();
    Test120FpsBurstKeepsPtsCadence();
    TestSubFrame120FpsJitterIsAbsorbedByReserve();
    TestSustained120FpsPeriodicJitterDoesNotDrop();
    TestSmallLateFrameShiftsWholeTimeline();
    TestLateShiftDebtIsReclaimedAfterRecovery();
    TestSevereLateFrameDropsThenReanchorsNextFrame();
    TestSingleSevereLateSpikeKeepsUsableTimeline();
    TestDuplicatePtsReanchorsWithoutDropping();
    TestDiscontinuityReanchors();
    TestNtscCadencePreservesPtsIntervals();
    TestSlowClockDriftStaysBounded();
    TestInvalidPtsDropsWithoutScheduling();
    std::cout << "presentation scheduler tests passed\n";
    return 0;
}
