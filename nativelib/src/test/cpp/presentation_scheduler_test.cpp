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
constexpr int64_t kExpectedSubmitLeadNs = 2 * kMs;

int64_t FrameIntervalNs(double fps) {
    return static_cast<int64_t>(
        std::llround(static_cast<double>(kNanosecondsPerSecond) / fps));
}

void AssertFutureCadenceBudget(double fps, int numerator, int denominator) {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(fps);

    const PresentationPlan first = scheduler.PlanFrame(0, kStartNs);
    const int64_t expectedCadenceBudgetNs =
        FrameIntervalNs(fps) * numerator / denominator;

    assert(first.action == PresentationAction::SCHEDULE);
    assert(scheduler.GetInitialLeadNs() == kExpectedSubmitLeadNs);
    assert(first.targetTimeNs - kStartNs == kExpectedSubmitLeadNs);
    assert(scheduler.GetMaxFutureLeadNs() ==
        kExpectedSubmitLeadNs + expectedCadenceBudgetNs +
        kNanosecondsPerMicrosecond);
}

void TestRefreshRateTierBudgets() {
    AssertFutureCadenceBudget(30.0, 1, 2);
    AssertFutureCadenceBudget(59.94, 1, 2);
    AssertFutureCadenceBudget(60.0, 1, 2);
    AssertFutureCadenceBudget(90.0, 1, 1);
    AssertFutureCadenceBudget(119.0, 1, 1);
    AssertFutureCadenceBudget(119.88, 2, 1);
    AssertFutureCadenceBudget(120.0, 2, 1);
    AssertFutureCadenceBudget(144.0, 2, 1);
}

void Test120FpsFourFrameBurstKeepsPtsCadence() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(120.0);

    const PresentationPlan first = scheduler.PlanFrame(0, kStartNs);
    const PresentationPlan second = scheduler.PlanFrame(8334, kStartNs);
    const PresentationPlan third = scheduler.PlanFrame(16667, kStartNs + kMs);
    const PresentationPlan fourth = scheduler.PlanFrame(25000, kStartNs + kMs);
    const PresentationPlan fifth = scheduler.PlanFrame(33333, kStartNs + kMs);

    assert(first.action == PresentationAction::SCHEDULE);
    assert(second.action == PresentationAction::SCHEDULE);
    assert(third.action == PresentationAction::SCHEDULE);
    assert(fourth.action == PresentationAction::SCHEDULE);
    assert(fifth.action == PresentationAction::SCHEDULE);
    assert(second.event == PresentationEvent::NONE);
    assert(third.event == PresentationEvent::NONE);
    assert(fourth.event == PresentationEvent::BURST_HEADROOM);
    assert(fifth.event == PresentationEvent::CATCH_UP);
    assert(second.targetTimeNs - first.targetTimeNs ==
        8334 * kNanosecondsPerMicrosecond);
    assert(third.targetTimeNs - second.targetTimeNs ==
        8333 * kNanosecondsPerMicrosecond);
    assert(fourth.targetTimeNs - third.targetTimeNs ==
        8333 * kNanosecondsPerMicrosecond);
    assert(fifth.targetTimeNs - (kStartNs + kMs) ==
        scheduler.GetInitialLeadNs());
}

void Test120FpsBurstHeadroomExpiresOutsideBurst() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(120.0);

    scheduler.PlanFrame(0, kStartNs);
    scheduler.PlanFrame(8334, kStartNs);
    scheduler.PlanFrame(16667, kStartNs + kMs);
    const PresentationPlan regular = scheduler.PlanFrame(
        25000, kStartNs + 7 * kMs);

    assert(regular.action == PresentationAction::SCHEDULE);
    assert(regular.event == PresentationEvent::CATCH_UP);
    assert(regular.targetTimeNs - (kStartNs + 7 * kMs) ==
        scheduler.GetInitialLeadNs());
}

void AssertFourthBurstFrameUsesHeadroom(
        double fps, int64_t secondPtsUs, int64_t thirdPtsUs,
        int64_t fourthPtsUs) {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(fps);

    scheduler.PlanFrame(0, kStartNs);
    scheduler.PlanFrame(secondPtsUs, kStartNs);
    scheduler.PlanFrame(thirdPtsUs, kStartNs + kMs);
    const PresentationPlan fourth = scheduler.PlanFrame(
        fourthPtsUs, kStartNs + kMs);

    assert(fourth.action == PresentationAction::SCHEDULE);
    assert(fourth.event == PresentationEvent::BURST_HEADROOM);
}

void TestHighRefreshRatesUseBurstHeadroom() {
    AssertFourthBurstFrameUsesHeadroom(119.88, 8342, 16683, 25025);
    AssertFourthBurstFrameUsesHeadroom(144.0, 6944, 13889, 20833);
}

void Test90FpsPairBurstKeepsSingleFrameBudget() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(90.0);

    const PresentationPlan first = scheduler.PlanFrame(0, kStartNs);
    const PresentationPlan second = scheduler.PlanFrame(11111, kStartNs);
    const PresentationPlan third = scheduler.PlanFrame(22222, kStartNs + kMs);

    assert(first.action == PresentationAction::SCHEDULE);
    assert(second.action == PresentationAction::SCHEDULE);
    assert(third.action == PresentationAction::SCHEDULE);
    assert(second.event == PresentationEvent::NONE);
    assert(third.event == PresentationEvent::CATCH_UP);
}

void AssertLowRefreshBurstCatchesUp(double fps, int64_t framePtsUs) {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(fps);

    const PresentationPlan first = scheduler.PlanFrame(0, kStartNs);
    const PresentationPlan burst = scheduler.PlanFrame(framePtsUs, kStartNs);

    assert(first.action == PresentationAction::SCHEDULE);
    assert(burst.action == PresentationAction::SCHEDULE);
    assert(burst.event == PresentationEvent::CATCH_UP);
    assert(burst.targetTimeNs - kStartNs == scheduler.GetInitialLeadNs());
}

void TestLowRefreshBurstKeepsHalfFrameBudget() {
    AssertLowRefreshBurstCatchesUp(30.0, 33333);
    AssertLowRefreshBurstCatchesUp(60.0, 16667);
}

void TestSmallLateFrameShiftsWholeTimeline() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    const PresentationPlan first = scheduler.PlanFrame(0, kStartNs);
    const PresentationPlan shifted = scheduler.PlanFrame(16667, 1018 * kMs);
    const PresentationPlan next = scheduler.PlanFrame(33333, 1034 * kMs);

    assert(shifted.action == PresentationAction::SCHEDULE);
    assert(shifted.event == PresentationEvent::PHASE_SHIFT);
    assert(next.action == PresentationAction::SCHEDULE);
    assert(next.targetTimeNs - shifted.targetTimeNs == 16666000LL);
    assert(shifted.targetTimeNs >= 1020 * kMs);
    assert(first.targetTimeNs < shifted.targetTimeNs);
}

void TestSevereLateDropThenRebuffer() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    scheduler.PlanFrame(0, kStartNs);
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

    constexpr int64_t kFrameUs = 16667;
    scheduler.PlanFrame(0, kStartNs);

    int phaseShiftCount = 0;
    for (int i = 1; i <= 12; ++i) {
        const int64_t ptsUs = i * kFrameUs;
        const int64_t nominalDecodeNs =
            kStartNs + ptsUs * kNanosecondsPerMicrosecond;
        const int64_t rampDelayNs = (3 + (i - 1) * 6) * kMs;
        const PresentationPlan delayed = scheduler.PlanFrame(
            ptsUs, nominalDecodeNs + rampDelayNs);
        assert(delayed.action == PresentationAction::SCHEDULE);
        if (delayed.event == PresentationEvent::PHASE_SHIFT) {
            phaseShiftCount++;
        }
    }
    assert(phaseShiftCount >= 10);

    const int64_t recoveredPtsUs = 13 * kFrameUs;
    const int64_t recoveredDecodeNs =
        kStartNs + recoveredPtsUs * kNanosecondsPerMicrosecond;
    const PresentationPlan recovered = scheduler.PlanFrame(
        recoveredPtsUs, recoveredDecodeNs);

    assert(recovered.action == PresentationAction::SCHEDULE);
    assert(recovered.event == PresentationEvent::PHASE_SHIFT);
    assert(recovered.latenessNs < 0);
    assert(std::llabs((recovered.targetTimeNs - recoveredDecodeNs) -
                      scheduler.GetInitialLeadNs()) < kMs);

    const int64_t nextPtsUs = 14 * kFrameUs;
    const int64_t nextDecodeNs =
        kStartNs + nextPtsUs * kNanosecondsPerMicrosecond;
    const PresentationPlan next = scheduler.PlanFrame(nextPtsUs, nextDecodeNs);
    assert(next.action == PresentationAction::SCHEDULE);
    assert(std::llabs((next.targetTimeNs - recovered.targetTimeNs) -
                      kFrameUs * kNanosecondsPerMicrosecond) < kMs);
}

void TestBurstCatchesUpAfterPartialPhaseDebtRepayment() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    scheduler.PlanFrame(0, kStartNs);
    const PresentationPlan shifted = scheduler.PlanFrame(16667, 1022 * kMs);
    const PresentationPlan burst = scheduler.PlanFrame(50000, 1023 * kMs);

    assert(shifted.event == PresentationEvent::PHASE_SHIFT);
    assert(burst.action == PresentationAction::SCHEDULE);
    assert(burst.event == PresentationEvent::CATCH_UP);
    assert(burst.targetTimeNs - 1023 * kMs == scheduler.GetInitialLeadNs());
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

void TestSlowClockDriftStaysBounded() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);

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
    TestRefreshRateTierBudgets();
    Test120FpsFourFrameBurstKeepsPtsCadence();
    Test120FpsBurstHeadroomExpiresOutsideBurst();
    TestHighRefreshRatesUseBurstHeadroom();
    Test90FpsPairBurstKeepsSingleFrameBudget();
    TestLowRefreshBurstKeepsHalfFrameBudget();
    TestSmallLateFrameShiftsWholeTimeline();
    TestSevereLateDropThenRebuffer();
    TestAccumulatedPhaseShiftRecoversQuickly();
    TestBurstCatchesUpAfterPartialPhaseDebtRepayment();
    TestDuplicatePtsReanchorsInsteadOfFreezing();
    TestDiscontinuityReanchors();
    TestSlowClockDriftStaysBounded();
    std::cout << "presentation scheduler tests passed\n";
    return 0;
}
