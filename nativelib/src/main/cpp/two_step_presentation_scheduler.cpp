#include "two_step_presentation_scheduler.h"

#include <algorithm>
#include <cmath>

namespace {
constexpr int64_t kNanosecondsPerSecond = 1000000000LL;
constexpr int64_t kNanosecondsPerMillisecond = 1000000LL;
constexpr double kDefaultFps = 60.0;
constexpr int64_t kMaxFutureIntervals = 3;
} // namespace

void TwoStepPresentationScheduler::Configure(double fps) {
    const double safeFps = fps > 0.0 ? fps : kDefaultFps;
    const int64_t frameIntervalNs = std::max<int64_t>(
        static_cast<int64_t>(std::llround(
            static_cast<double>(kNanosecondsPerSecond) / safeFps)),
        kNanosecondsPerMillisecond);
    scheduler_.Configure(safeFps);
    submitLeadNs_ = scheduler_.GetSubmitLeadNs();
    maxFutureLeadNs_ = frameIntervalNs * kMaxFutureIntervals;
    Reset();
    ResetStats();
}

void TwoStepPresentationScheduler::Reset() {
    scheduler_.Reset();
    ClearTargets();
    lastSubmittedPtsUs_ = 0;
    hasSubmittedPts_ = false;
}

void TwoStepPresentationScheduler::ClearTargets() {
    targets_.fill({});
    targetWriteIndex_ = 0;
    pendingTargetCount_ = 0;
}

PresentationTargetHandle TwoStepPresentationScheduler::StoreTarget(
        int64_t ptsUs, int64_t targetTimeNs) {
    const PresentationTargetHandle handle(nextTargetId_++);
    if (nextTargetId_ == 0) {
        nextTargetId_ = 1;
    }

    PreparedTarget& target = targets_[targetWriteIndex_];
    if (!target.valid) {
        pendingTargetCount_++;
    }
    target = {handle.id_, ptsUs, targetTimeNs, true};
    targetWriteIndex_ = (targetWriteIndex_ + 1) % targets_.size();
    stats_.preparedTargets++;
    stats_.pendingHighWater = std::max<uint64_t>(
        stats_.pendingHighWater, pendingTargetCount_);
    return handle;
}

bool TwoStepPresentationScheduler::TakeTarget(
        int64_t ptsUs, int64_t& targetTimeNs) {
    for (size_t offset = 0; offset < targets_.size(); ++offset) {
        const size_t index =
            (targetWriteIndex_ + targets_.size() - 1 - offset) % targets_.size();
        PreparedTarget& target = targets_[index];
        if (target.valid && target.ptsUs == ptsUs) {
            target.valid = false;
            pendingTargetCount_--;
            targetTimeNs = target.targetTimeNs;
            return true;
        }
    }
    return false;
}

PresentationTargetHandle TwoStepPresentationScheduler::PrepareFrame(
        int64_t ptsUs, int64_t preparedAtNs) {
    const PresentationPlan plan = scheduler_.PlanFrame(ptsUs, preparedAtNs);
    if (plan.action != PresentationAction::SCHEDULE) {
        return {};
    }

    if (plan.event == PresentationEvent::DISCONTINUITY) {
        ClearTargets();
        hasSubmittedPts_ = false;
    }
    return StoreTarget(ptsUs, plan.targetTimeNs);
}

void TwoStepPresentationScheduler::DiscardFrame(
        PresentationTargetHandle handle) {
    if (!handle) {
        return;
    }

    for (PreparedTarget& target : targets_) {
        if (target.valid && target.id == handle.id_) {
            target.valid = false;
            pendingTargetCount_--;
            return;
        }
    }
}

void TwoStepPresentationScheduler::DiscardFrame(int64_t ptsUs) {
    int64_t ignoredTargetNs = 0;
    TakeTarget(ptsUs, ignoredTargetNs);
}

void TwoStepPresentationScheduler::NoteSubmittedPts(int64_t ptsUs) {
    lastSubmittedPtsUs_ = ptsUs;
    hasSubmittedPts_ = true;
}

void TwoStepPresentationScheduler::RecordTargetLead(int64_t targetLeadNs) {
    if (targetLeadNs < kNanosecondsPerMillisecond) {
        stats_.leadUnder1Ms++;
    } else if (targetLeadNs < 2 * kNanosecondsPerMillisecond) {
        stats_.lead1To2Ms++;
    } else if (targetLeadNs < 4 * kNanosecondsPerMillisecond) {
        stats_.lead2To4Ms++;
    } else if (targetLeadNs < 8 * kNanosecondsPerMillisecond) {
        stats_.lead4To8Ms++;
    } else {
        stats_.leadAtLeast8Ms++;
    }
}

void TwoStepPresentationScheduler::NoteRenderAtTimeFallback() {
    stats_.renderAtTimeFallbacks++;
}

void TwoStepPresentationScheduler::ResetStats() {
    stats_ = {};
}

PreparedPresentationPlan TwoStepPresentationScheduler::PlanDecodedFrame(
        int64_t ptsUs, int64_t decodedAtNs) {
    PreparedPresentationPlan plan;
    if (hasSubmittedPts_ && ptsUs <= lastSubmittedPtsUs_) {
        plan.action = PreparedPresentationAction::DROP;
        plan.event = PreparedPresentationEvent::NON_MONOTONIC_PTS;
        stats_.nonMonotonicDrops++;
        DiscardFrame(ptsUs);
        return plan;
    }

    int64_t targetTimeNs = 0;
    if (!TakeTarget(ptsUs, targetTimeNs)) {
        plan.event = PreparedPresentationEvent::MISSING_TARGET;
        stats_.missingTargets++;
        return plan;
    }

    const int64_t targetLeadNs = targetTimeNs - decodedAtNs;
    plan.targetLeadNs = targetLeadNs;
    RecordTargetLead(targetLeadNs);
    if (targetLeadNs < submitLeadNs_) {
        plan.event = PreparedPresentationEvent::EXPIRED_TARGET;
        stats_.expiredTargets++;
        NoteSubmittedPts(ptsUs);
        return plan;
    }
    if (targetLeadNs > maxFutureLeadNs_) {
        plan.event = PreparedPresentationEvent::FUTURE_TARGET;
        stats_.futureTargets++;
        NoteSubmittedPts(ptsUs);
        return plan;
    }

    plan.action = PreparedPresentationAction::SCHEDULE;
    plan.targetTimeNs = targetTimeNs;
    stats_.scheduledFrames++;
    NoteSubmittedPts(ptsUs);
    return plan;
}
