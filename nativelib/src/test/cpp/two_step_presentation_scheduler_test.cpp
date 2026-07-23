#include "presentation_scheduler.h"
#include "two_step_presentation_scheduler.h"

#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>

namespace {
constexpr int64_t kMs = 1000000LL;
constexpr int64_t kUsToNs = 1000LL;
constexpr int64_t kStartNs = 1000 * kMs;

void TestDecodeTimeConsumesPreparedLead() {
    PtsPresentationScheduler postDecode;
    TwoStepPresentationScheduler twoStep;
    postDecode.Configure(120.0);
    twoStep.Configure(120.0);

    constexpr int64_t kDecodeNs = 4 * kMs;
    assert(twoStep.PrepareFrame(0, kStartNs));
    const PreparedPresentationPlan prepared = twoStep.PlanDecodedFrame(
        0, kStartNs + kDecodeNs);
    const PresentationPlan post = postDecode.PlanFrame(
        0, kStartNs + kDecodeNs);

    assert(prepared.action == PreparedPresentationAction::SCHEDULE);
    assert(post.action == PresentationAction::SCHEDULE);
    assert(post.targetTimeNs - prepared.targetTimeNs == kDecodeNs);
}

void TestExpiredPreparedTargetRendersImmediately() {
    TwoStepPresentationScheduler scheduler;
    scheduler.Configure(120.0);

    assert(scheduler.PrepareFrame(0, kStartNs));
    const PreparedPresentationPlan plan = scheduler.PlanDecodedFrame(
        0, kStartNs + 12 * kMs);

    assert(plan.action == PreparedPresentationAction::IMMEDIATE);
    assert(plan.event == PreparedPresentationEvent::EXPIRED_TARGET);
}

void TestMissingTargetDoesNotPoisonNewTimeline() {
    TwoStepPresentationScheduler scheduler;
    scheduler.Configure(120.0);

    const PreparedPresentationPlan stale = scheduler.PlanDecodedFrame(
        1000000, kStartNs);
    assert(stale.action == PreparedPresentationAction::IMMEDIATE);
    assert(stale.event == PreparedPresentationEvent::MISSING_TARGET);

    assert(scheduler.PrepareFrame(0, kStartNs + kMs));
    const PreparedPresentationPlan first = scheduler.PlanDecodedFrame(
        0, kStartNs + 3 * kMs);
    assert(first.action == PreparedPresentationAction::SCHEDULE);
}

void TestFarFutureTargetRendersImmediately() {
    TwoStepPresentationScheduler scheduler;
    scheduler.Configure(120.0);

    assert(scheduler.PrepareFrame(0, kStartNs));
    assert(scheduler.PrepareFrame(33333, kStartNs));
    const PreparedPresentationPlan plan = scheduler.PlanDecodedFrame(
        33333, kStartNs);

    assert(plan.action == PreparedPresentationAction::IMMEDIATE);
    assert(plan.event == PreparedPresentationEvent::FUTURE_TARGET);
}

void TestTargetsFollowPtsAcrossOutputLookup() {
    TwoStepPresentationScheduler scheduler;
    scheduler.Configure(120.0);

    assert(scheduler.PrepareFrame(0, kStartNs));
    assert(scheduler.PrepareFrame(8333, kStartNs + 8 * kMs));

    const PreparedPresentationPlan newer = scheduler.PlanDecodedFrame(
        8333, kStartNs + 9 * kMs);
    const PreparedPresentationPlan older = scheduler.PlanDecodedFrame(
        0, kStartNs + 10 * kMs);

    assert(newer.action == PreparedPresentationAction::SCHEDULE);
    assert(older.action == PreparedPresentationAction::DROP);
    assert(older.event == PreparedPresentationEvent::NON_MONOTONIC_PTS);
}

void TestSyncDrainKeepsOnlyLatestPreparedTarget() {
    PtsPresentationScheduler postDecode;
    TwoStepPresentationScheduler twoStep;
    postDecode.Configure(120.0);
    twoStep.Configure(120.0);

    constexpr int64_t kPtsUs[] = {0, 8333, 16667, 25000, 33333};
    for (int64_t ptsUs : kPtsUs) {
        assert(twoStep.PrepareFrame(
            ptsUs, kStartNs + ptsUs * kUsToNs));
    }

    const int64_t burstDecodedAtNs = kStartNs + 34 * kMs;
    int64_t maxPostDecodeLeadNs = 0;
    for (size_t index = 0; index < std::size(kPtsUs); ++index) {
        const PresentationPlan post = postDecode.PlanFrame(
            kPtsUs[index], burstDecodedAtNs);
        if (post.action == PresentationAction::SCHEDULE) {
            maxPostDecodeLeadNs = std::max(
                maxPostDecodeLeadNs, post.targetTimeNs - burstDecodedAtNs);
        }
        if (index + 1 < std::size(kPtsUs)) {
            twoStep.DiscardFrame(kPtsUs[index]);
        }
    }

    const PreparedPresentationPlan latest = twoStep.PlanDecodedFrame(
        kPtsUs[4], burstDecodedAtNs);
    assert(twoStep.GetPendingTargetCount() == 0);
    assert(latest.action == PreparedPresentationAction::SCHEDULE);
    assert(maxPostDecodeLeadNs > postDecode.GetInitialLeadNs() + 3 * 8 * kMs);
    assert(latest.targetLeadNs < twoStep.GetInitialLeadNs());
}

void TestSynthetic120FpsAverageWaitIsLower() {
    PtsPresentationScheduler postDecode;
    TwoStepPresentationScheduler twoStep;
    postDecode.Configure(120.0);
    twoStep.Configure(120.0);

    constexpr double kFrameUs = 1000000.0 / 120.0;
    constexpr int64_t kDecodePatternMs[] = {2, 3, 4, 6, 5};
    int64_t postWaitNs = 0;
    int64_t twoStepWaitNs = 0;
    int scheduledFrames = 0;

    for (int frame = 0; frame < 1200; ++frame) {
        const int64_t ptsUs = static_cast<int64_t>(
            std::llround(frame * kFrameUs));
        const int64_t preparedAtNs = kStartNs + ptsUs * kUsToNs;
        const int64_t decodedAtNs = preparedAtNs +
            kDecodePatternMs[frame % std::size(kDecodePatternMs)] * kMs;

        assert(twoStep.PrepareFrame(ptsUs, preparedAtNs));
        const PreparedPresentationPlan prepared =
            twoStep.PlanDecodedFrame(ptsUs, decodedAtNs);
        const PresentationPlan post = postDecode.PlanFrame(ptsUs, decodedAtNs);

        assert(prepared.action == PreparedPresentationAction::SCHEDULE);
        assert(post.action == PresentationAction::SCHEDULE);
        postWaitNs += std::max<int64_t>(0, post.targetTimeNs - decodedAtNs);
        twoStepWaitNs += prepared.targetLeadNs;
        scheduledFrames++;
    }

    const int64_t averagePostWaitNs = postWaitNs / scheduledFrames;
    const int64_t averageTwoStepWaitNs = twoStepWaitNs / scheduledFrames;
    std::cout << "synthetic 120 fps average wait: post-decode="
              << averagePostWaitNs / 1000 << " us, two-step="
              << averageTwoStepWaitNs / 1000 << " us\n";
    assert(averagePostWaitNs - averageTwoStepWaitNs > kMs);
}

void TestPreparedTargetStorageIsBounded() {
    TwoStepPresentationScheduler scheduler;
    scheduler.Configure(120.0);

    for (int frame = 0; frame < 256; ++frame) {
        const int64_t ptsUs = frame * 8333LL;
        scheduler.PrepareFrame(ptsUs, kStartNs + ptsUs * kUsToNs);
    }

    assert(scheduler.GetPendingTargetCount() == 64);
}

void TestNtscCadencePreservesPreparedTargets() {
    TwoStepPresentationScheduler scheduler;
    scheduler.Configure(119.88);
    constexpr double kFrameUs = 1000000.0 / 119.88;

    int64_t previousPtsUs = 0;
    int64_t previousTargetNs = 0;
    for (int frame = 0; frame <= 2500; ++frame) {
        const int64_t ptsUs = static_cast<int64_t>(
            std::llround(frame * kFrameUs));
        const int64_t preparedAtNs = kStartNs + ptsUs * kUsToNs;
        assert(scheduler.PrepareFrame(ptsUs, preparedAtNs));
        const PreparedPresentationPlan plan = scheduler.PlanDecodedFrame(
            ptsUs, preparedAtNs + 3 * kMs);

        assert(plan.action == PreparedPresentationAction::SCHEDULE);
        if (frame > 0) {
            assert(plan.targetTimeNs - previousTargetNs ==
                (ptsUs - previousPtsUs) * kUsToNs);
        }
        previousPtsUs = ptsUs;
        previousTargetNs = plan.targetTimeNs;
    }
}

void TestDiscontinuityClearsOldTargets() {
    TwoStepPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    assert(scheduler.PrepareFrame(1000000, kStartNs));
    assert(scheduler.PrepareFrame(1016667, kStartNs + 16 * kMs));
    assert(scheduler.GetPendingTargetCount() == 2);

    assert(scheduler.PrepareFrame(0, kStartNs + 32 * kMs));
    assert(scheduler.GetPendingTargetCount() == 1);
    const PreparedPresentationPlan plan = scheduler.PlanDecodedFrame(
        0, kStartNs + 35 * kMs);
    assert(plan.action == PreparedPresentationAction::SCHEDULE);
    assert(scheduler.GetPendingTargetCount() == 0);
}

void TestDuplicateOutputIsDroppedOnce() {
    TwoStepPresentationScheduler scheduler;
    scheduler.Configure(60.0);

    assert(scheduler.PrepareFrame(1000, kStartNs));
    assert(scheduler.PrepareFrame(1000, kStartNs + 17 * kMs));
    const PreparedPresentationPlan first = scheduler.PlanDecodedFrame(
        1000, kStartNs + 18 * kMs);
    const PreparedPresentationPlan duplicate = scheduler.PlanDecodedFrame(
        1000, kStartNs + 19 * kMs);

    assert(first.action == PreparedPresentationAction::SCHEDULE);
    assert(duplicate.action == PreparedPresentationAction::DROP);
    assert(duplicate.event == PreparedPresentationEvent::NON_MONOTONIC_PTS);
    assert(scheduler.GetPendingTargetCount() == 0);
}
} // namespace

int main() {
    TestDecodeTimeConsumesPreparedLead();
    TestExpiredPreparedTargetRendersImmediately();
    TestMissingTargetDoesNotPoisonNewTimeline();
    TestFarFutureTargetRendersImmediately();
    TestTargetsFollowPtsAcrossOutputLookup();
    TestSyncDrainKeepsOnlyLatestPreparedTarget();
    TestSynthetic120FpsAverageWaitIsLower();
    TestPreparedTargetStorageIsBounded();
    TestNtscCadencePreservesPreparedTargets();
    TestDiscontinuityClearsOldTargets();
    TestDuplicateOutputIsDroppedOnce();
    std::cout << "two-step presentation scheduler tests passed\n";
    return 0;
}
