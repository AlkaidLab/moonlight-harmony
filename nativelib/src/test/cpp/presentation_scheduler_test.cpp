#include "presentation_scheduler.h"

#include <cassert>
#include <cmath>
#include <cstdint>
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

PresentationVsyncTiming Timing(double refreshRate) {
    return {kStartNs, FrameIntervalNs(refreshRate)};
}

void AssertOnVsyncSlot(
        const PresentationPlan& plan,
        const PresentationVsyncTiming& timing) {
    assert(plan.action == PresentationAction::SCHEDULE);
    assert((plan.targetTimeNs - timing.timestampNs) % timing.periodNs == 0);
}

void AssertFutureCadenceBudget(double fps, int numerator, int denominator) {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(fps);

    const int64_t expectedCadenceBudgetNs =
        FrameIntervalNs(fps) * numerator / denominator;

    assert(scheduler.GetInitialLeadNs() == kExpectedSubmitLeadNs);
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

void Test120FpsBurstUsesThreeUniqueSlots() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(120.0);
    const PresentationVsyncTiming timing = Timing(120.0);
    const int64_t decodedAtNs = kStartNs + kMs;

    const PresentationPlan first = scheduler.PlanFrame(0, decodedAtNs, timing);
    const PresentationPlan second = scheduler.PlanFrame(8334, decodedAtNs, timing);
    const PresentationPlan third = scheduler.PlanFrame(16667, decodedAtNs, timing);
    const PresentationPlan fourth = scheduler.PlanFrame(25000, decodedAtNs, timing);

    AssertOnVsyncSlot(first, timing);
    AssertOnVsyncSlot(second, timing);
    AssertOnVsyncSlot(third, timing);
    assert(second.targetTimeNs - first.targetTimeNs == timing.periodNs);
    assert(third.targetTimeNs - second.targetTimeNs == timing.periodNs);
    assert(fourth.action == PresentationAction::DROP);
    assert(fourth.event == PresentationEvent::QUEUE_FULL);
}

void TestQueueFullWaitsForDrainBeforeReanchor() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(120.0);
    const PresentationVsyncTiming timing = Timing(120.0);
    const int64_t burstTimeNs = kStartNs + kMs;

    const PresentationPlan first = scheduler.PlanFrame(0, burstTimeNs, timing);
    scheduler.PlanFrame(8334, burstTimeNs, timing);
    const PresentationPlan third = scheduler.PlanFrame(16667, burstTimeNs, timing);
    const PresentationPlan full = scheduler.PlanFrame(25000, burstTimeNs, timing);
    const PresentationPlan waiting = scheduler.PlanFrame(
        33333, first.targetTimeNs + kMs, timing);
    const PresentationPlan recovered = scheduler.PlanFrame(
        41667, third.targetTimeNs + kMs, timing);

    assert(full.event == PresentationEvent::QUEUE_FULL);
    assert(waiting.action == PresentationAction::DROP);
    assert(waiting.event == PresentationEvent::WAIT_FOR_DRAIN);
    assert(recovered.action == PresentationAction::SCHEDULE);
    assert(recovered.event == PresentationEvent::CATCH_UP);
    assert(recovered.targetTimeNs == third.targetTimeNs + timing.periodNs);
}

void Test90FpsPairBurstUsesTwoSlots() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(90.0);
    const PresentationVsyncTiming timing = Timing(90.0);
    const int64_t decodedAtNs = kStartNs + kMs;

    const PresentationPlan first = scheduler.PlanFrame(0, decodedAtNs, timing);
    const PresentationPlan second = scheduler.PlanFrame(11111, decodedAtNs, timing);
    const PresentationPlan third = scheduler.PlanFrame(22222, decodedAtNs, timing);

    AssertOnVsyncSlot(first, timing);
    AssertOnVsyncSlot(second, timing);
    assert(second.targetTimeNs - first.targetTimeNs == timing.periodNs);
    assert(third.action == PresentationAction::DROP);
    assert(third.event == PresentationEvent::QUEUE_FULL);
}

void Test60FpsDoesNotGrowPresentationQueue() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);
    const PresentationVsyncTiming timing = Timing(60.0);
    const int64_t decodedAtNs = kStartNs + kMs;

    const PresentationPlan first = scheduler.PlanFrame(0, decodedAtNs, timing);
    const PresentationPlan burst = scheduler.PlanFrame(16667, decodedAtNs, timing);
    const PresentationPlan recovered = scheduler.PlanFrame(
        33333, first.targetTimeNs + kMs, timing);

    AssertOnVsyncSlot(first, timing);
    assert(burst.action == PresentationAction::DROP);
    assert(burst.event == PresentationEvent::QUEUE_FULL);
    assert(recovered.action == PresentationAction::SCHEDULE);
    assert(recovered.event == PresentationEvent::CATCH_UP);
    assert(recovered.targetTimeNs == first.targetTimeNs + timing.periodNs);
}

void TestSmallLateFrameShiftsWholeTimeline() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);
    const PresentationVsyncTiming timing = Timing(60.0);

    const PresentationPlan first = scheduler.PlanFrame(
        0, kStartNs + kMs, timing);
    const PresentationPlan shifted = scheduler.PlanFrame(
        16667, kStartNs + 18 * kMs, timing);
    const PresentationPlan next = scheduler.PlanFrame(
        33333, kStartNs + 34 * kMs, timing);

    assert(shifted.action == PresentationAction::SCHEDULE);
    assert(shifted.event == PresentationEvent::PHASE_SHIFT);
    assert(next.action == PresentationAction::SCHEDULE);
    assert(first.targetTimeNs < shifted.targetTimeNs);
    assert(next.targetTimeNs - shifted.targetTimeNs == timing.periodNs);
}

void TestSevereLateFrameRebuffersAfterDrain() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);
    const PresentationVsyncTiming timing = Timing(60.0);

    scheduler.PlanFrame(0, kStartNs + kMs, timing);
    const PresentationPlan rebuffered = scheduler.PlanFrame(
        16667, kStartNs + 100 * kMs, timing);

    assert(rebuffered.action == PresentationAction::SCHEDULE);
    assert(rebuffered.event == PresentationEvent::REBUFFER);
    assert(rebuffered.targetTimeNs > kStartNs + 100 * kMs);
}

void TestDiscontinuityWaitsForQueuedSlot() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(120.0);
    const PresentationVsyncTiming timing = Timing(120.0);
    const int64_t decodedAtNs = kStartNs + kMs;

    const PresentationPlan first = scheduler.PlanFrame(1000000, decodedAtNs, timing);
    const PresentationPlan waiting = scheduler.PlanFrame(500000, decodedAtNs, timing);
    const PresentationPlan reanchored = scheduler.PlanFrame(
        500001, first.targetTimeNs + kMs, timing);

    assert(waiting.action == PresentationAction::DROP);
    assert(waiting.event == PresentationEvent::WAIT_FOR_DRAIN);
    assert(reanchored.action == PresentationAction::SCHEDULE);
    assert(reanchored.event == PresentationEvent::DISCONTINUITY);
    assert(reanchored.targetTimeNs == first.targetTimeNs + timing.periodNs);
}

void TestDuplicatePtsRecoversAfterQueuedSlot() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(60.0);
    const PresentationVsyncTiming timing = Timing(60.0);
    const int64_t decodedAtNs = kStartNs + kMs;

    const PresentationPlan first = scheduler.PlanFrame(1000, decodedAtNs, timing);
    const PresentationPlan waiting = scheduler.PlanFrame(1000, decodedAtNs, timing);
    const PresentationPlan reanchored = scheduler.PlanFrame(
        1000, first.targetTimeNs + kMs, timing);

    assert(waiting.action == PresentationAction::DROP);
    assert(waiting.event == PresentationEvent::WAIT_FOR_DRAIN);
    assert(reanchored.action == PresentationAction::SCHEDULE);
    assert(reanchored.event == PresentationEvent::DUPLICATE_PTS);
}

void TestNtscCadenceSkipsARealSlotWithoutRegression() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(119.88);
    const PresentationVsyncTiming timing = Timing(120.0);
    constexpr double kPtsIntervalUs = 1000000.0 / 119.88;
    const int64_t firstDecodedAtNs = kStartNs + kMs;

    PresentationPlan previous = scheduler.PlanFrame(
        0, firstDecodedAtNs, timing);
    bool skippedSlot = false;
    for (int i = 1; i <= 2500; ++i) {
        const int64_t ptsUs = static_cast<int64_t>(
            std::llround(i * kPtsIntervalUs));
        const int64_t decodedAtNs =
            firstDecodedAtNs + ptsUs * kNanosecondsPerMicrosecond;
        const PresentationPlan current = scheduler.PlanFrame(
            ptsUs, decodedAtNs, timing);

        AssertOnVsyncSlot(current, timing);
        assert(current.targetTimeNs > previous.targetTimeNs);
        const int64_t slotDelta =
            (current.targetTimeNs - previous.targetTimeNs) / timing.periodNs;
        assert(slotDelta == 1 || slotDelta == 2);
        skippedSlot = skippedSlot || slotDelta == 2;
        previous = current;
    }
    assert(skippedSlot);
}

void TestObservedVsyncPhaseCannotReuseFallbackSlot() {
    PtsPresentationScheduler scheduler;
    scheduler.Configure(120.0);
    const int64_t decodedAtNs = kStartNs + kMs;

    const PresentationPlan fallback = scheduler.PlanFrame(0, decodedAtNs);
    const PresentationVsyncTiming observed = {
        kStartNs + 3 * kMs, FrameIntervalNs(120.0)};
    const PresentationPlan phased = scheduler.PlanFrame(
        8334, decodedAtNs, observed);

    AssertOnVsyncSlot(phased, observed);
    const int64_t fallbackOccupiedSlot = observed.timestampNs +
        static_cast<int64_t>(std::ceil(
            static_cast<double>(fallback.targetTimeNs - observed.timestampNs) /
            static_cast<double>(observed.periodNs))) * observed.periodNs;
    assert(phased.targetTimeNs > fallbackOccupiedSlot);
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
    TestRefreshRateTierBudgets();
    Test120FpsBurstUsesThreeUniqueSlots();
    TestQueueFullWaitsForDrainBeforeReanchor();
    Test90FpsPairBurstUsesTwoSlots();
    Test60FpsDoesNotGrowPresentationQueue();
    TestSmallLateFrameShiftsWholeTimeline();
    TestSevereLateFrameRebuffersAfterDrain();
    TestDiscontinuityWaitsForQueuedSlot();
    TestDuplicatePtsRecoversAfterQueuedSlot();
    TestNtscCadenceSkipsARealSlotWithoutRegression();
    TestObservedVsyncPhaseCannotReuseFallbackSlot();
    TestInvalidPtsDropsWithoutScheduling();
    std::cout << "presentation scheduler tests passed\n";
    return 0;
}
