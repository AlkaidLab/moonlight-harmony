/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#include "presentation_scheduler.h"

#include <algorithm>
#include <cmath>

namespace {
constexpr int64_t kNanosecondsPerSecond = 1000000000LL;
constexpr int64_t kNanosecondsPerMillisecond = 1000000LL;
constexpr int64_t kNanosecondsPerMicrosecond = 1000LL;
constexpr int64_t kSubmitLeadNs = 2 * kNanosecondsPerMillisecond;
constexpr int64_t kPtsQuantizationSlackNs = kNanosecondsPerMicrosecond;
constexpr double kDefaultFps = 60.0;
constexpr double kHighRefreshFps = kDefaultFps;
constexpr double kNtscTripleBurstFps = 119.88;
constexpr int64_t kDriftDeadbandNs = 2 * kNanosecondsPerMillisecond;
constexpr int64_t kMaxDriftCorrectionPerFrameNs = 20 * kNanosecondsPerMicrosecond;
constexpr int kSevereLateFramesBeforeRebuffer = 2;

int64_t FloorDiv(int64_t value, int64_t divisor) {
    int64_t quotient = value / divisor;
    if (value % divisor < 0) {
        quotient--;
    }
    return quotient;
}

int64_t CeilDiv(int64_t value, int64_t divisor) {
    int64_t quotient = value / divisor;
    if (value % divisor > 0) {
        quotient++;
    }
    return quotient;
}

int64_t FloorToSlot(int64_t timeNs, int64_t anchorNs, int64_t periodNs) {
    return anchorNs + FloorDiv(timeNs - anchorNs, periodNs) * periodNs;
}

int64_t CeilToSlot(int64_t timeNs, int64_t anchorNs, int64_t periodNs) {
    return anchorNs + CeilDiv(timeNs - anchorNs, periodNs) * periodNs;
}

int64_t CalculateFutureCadenceBudgetNs(double fps, int64_t frameIntervalNs) {
    if (fps >= kNtscTripleBurstFps) {
        return frameIntervalNs * 2;
    }
    if (fps > kHighRefreshFps) {
        return frameIntervalNs;
    }
    return frameIntervalNs / 2;
}
} // namespace

void PtsPresentationScheduler::Configure(double fps) {
    const double safeFps = fps > 0.0 ? fps : kDefaultFps;
    frameIntervalNs_ = static_cast<int64_t>(
        std::llround(static_cast<double>(kNanosecondsPerSecond) / safeFps));
    frameIntervalNs_ = std::max<int64_t>(frameIntervalNs_, 1000000LL);
    // RenderService needs an absolute latch margin that does not shrink with
    // the stream frame interval. Keep steady-state lead small, but large enough
    // for 120 Hz submission overhead.
    submitLeadNs_ = kSubmitLeadNs;
    initialLeadNs_ = submitLeadNs_;
    maxFutureLeadNs_ = initialLeadNs_ +
        CalculateFutureCadenceBudgetNs(safeFps, frameIntervalNs_) +
        kPtsQuantizationSlackNs;
    discontinuityNs_ = std::max<int64_t>(
        250 * kNanosecondsPerMillisecond, frameIntervalNs_ * 12);
    Reset();
}

void PtsPresentationScheduler::Reset() {
    initialized_ = false;
    anchorPtsUs_ = 0;
    anchorTargetNs_ = 0;
    lastPtsUs_ = 0;
    driftErrorEmaNs_ = 0;
    phaseShiftDebtNs_ = 0;
    lastScheduledTargetNs_ = 0;
    consecutiveSevereLateFrames_ = 0;
    reanchorPending_ = false;
    pendingReanchorEvent_ = PresentationEvent::CATCH_UP;
}

PresentationPlan PtsPresentationScheduler::AnchorFrame(
        int64_t ptsUs, int64_t decodedAtNs, PresentationEvent event,
        const SlotClock& slotClock) {
    initialized_ = true;
    anchorPtsUs_ = ptsUs;
    anchorTargetNs_ = decodedAtNs + initialLeadNs_;
    lastPtsUs_ = ptsUs;
    driftErrorEmaNs_ = 0;
    phaseShiftDebtNs_ = 0;
    consecutiveSevereLateFrames_ = 0;
    reanchorPending_ = false;
    pendingReanchorEvent_ = PresentationEvent::CATCH_UP;

    return ScheduleTarget(anchorTargetNs_, decodedAtNs, event, 0, slotClock);
}

PresentationPlan PtsPresentationScheduler::ScheduleTarget(
        int64_t targetTimeNs, int64_t decodedAtNs,
        PresentationEvent event, int64_t latenessNs,
        const SlotClock& slotClock) {
    const int64_t requiredTargetNs = decodedAtNs + submitLeadNs_;
    int64_t scheduledSlotNs = CeilToSlot(
        std::max(targetTimeNs, requiredTargetNs),
        slotClock.anchorNs, slotClock.periodNs);

    if (lastScheduledTargetNs_ > 0) {
        // Re-map the previous target when a real VSync sample first arrives or
        // its phase changes, so two submissions still cannot share a latch.
        const int64_t lastOccupiedSlotNs = CeilToSlot(
            lastScheduledTargetNs_, slotClock.anchorNs, slotClock.periodNs);
        if (scheduledSlotNs <= lastOccupiedSlotNs) {
            scheduledSlotNs = lastOccupiedSlotNs + slotClock.periodNs;
        }
    }

    // Start the existing cadence budget at the first slot that still has the
    // submit margin. Being close to a VSync must not reduce burst capacity.
    const int64_t firstEligibleSlotNs = CeilToSlot(
        requiredTargetNs, slotClock.anchorNs, slotClock.periodNs);
    const int64_t maxScheduledSlotNs = firstEligibleSlotNs +
        GetAdditionalQueueSlots(slotClock.periodNs) * slotClock.periodNs;
    if (scheduledSlotNs > maxScheduledSlotNs) {
        reanchorPending_ = true;
        pendingReanchorEvent_ = PresentationEvent::CATCH_UP;
        PresentationPlan plan;
        plan.event = PresentationEvent::QUEUE_FULL;
        plan.latenessNs = latenessNs;
        return plan;
    }

    lastScheduledTargetNs_ = scheduledSlotNs;

    PresentationPlan plan;
    plan.action = PresentationAction::SCHEDULE;
    plan.event = event;
    plan.targetTimeNs = scheduledSlotNs;
    plan.latenessNs = latenessNs;
    return plan;
}

PtsPresentationScheduler::SlotClock PtsPresentationScheduler::ResolveSlotClock(
        int64_t decodedAtNs,
        const PresentationVsyncTiming& vsyncTiming) const {
    SlotClock clock;
    clock.periodNs = vsyncTiming.periodNs > 0
        ? vsyncTiming.periodNs
        : frameIntervalNs_;
    clock.anchorNs = vsyncTiming.timestampNs > 0
        ? vsyncTiming.timestampNs
        : 0;
    clock.currentSlotNs = FloorToSlot(
        decodedAtNs, clock.anchorNs, clock.periodNs);
    return clock;
}

bool PtsPresentationScheduler::IsPresentationQueueEmpty(
        const SlotClock& slotClock) const {
    if (lastScheduledTargetNs_ <= 0) {
        return true;
    }
    const int64_t lastOccupiedSlotNs = CeilToSlot(
        lastScheduledTargetNs_, slotClock.anchorNs, slotClock.periodNs);
    return lastOccupiedSlotNs <= slotClock.currentSlotNs;
}

int64_t PtsPresentationScheduler::GetAdditionalQueueSlots(
        int64_t vsyncPeriodNs) const {
    const int64_t cadenceBudgetNs = std::max<int64_t>(
        0, maxFutureLeadNs_ - initialLeadNs_);
    return cadenceBudgetNs / vsyncPeriodNs;
}

void PtsPresentationScheduler::ApplySlowDriftCorrection(
        int64_t decodedAtNs, int64_t& targetTimeNs) {
    int64_t leadErrorNs = targetTimeNs - decodedAtNs - initialLeadNs_;
    leadErrorNs = std::clamp(leadErrorNs, -frameIntervalNs_, frameIntervalNs_);
    driftErrorEmaNs_ += (leadErrorNs - driftErrorEmaNs_) / 256;

    if (driftErrorEmaNs_ > kDriftDeadbandNs ||
        driftErrorEmaNs_ < -kDriftDeadbandNs) {
        const int64_t correctionNs = std::clamp(
            -driftErrorEmaNs_ / 1024,
            -kMaxDriftCorrectionPerFrameNs,
            kMaxDriftCorrectionPerFrameNs);
        anchorTargetNs_ += correctionNs;
        targetTimeNs += correctionNs;
        if (correctionNs < 0 && phaseShiftDebtNs_ > 0) {
            phaseShiftDebtNs_ = std::max<int64_t>(
                0, phaseShiftDebtNs_ + correctionNs);
        }
    }
}

PresentationPlan PtsPresentationScheduler::PlanFrame(
        int64_t ptsUs, int64_t decodedAtNs) {
    return PlanFrame(ptsUs, decodedAtNs, {});
}

PresentationPlan PtsPresentationScheduler::PlanFrame(
        int64_t ptsUs, int64_t decodedAtNs,
        const PresentationVsyncTiming& vsyncTiming) {
    if (ptsUs < 0 || decodedAtNs <= 0) {
        PresentationPlan plan;
        plan.event = PresentationEvent::INVALID_PTS;
        return plan;
    }

    const SlotClock slotClock = ResolveSlotClock(decodedAtNs, vsyncTiming);
    const bool queueEmpty = IsPresentationQueueEmpty(slotClock);

    if (reanchorPending_) {
        if (queueEmpty) {
            return AnchorFrame(
                ptsUs, decodedAtNs, pendingReanchorEvent_, slotClock);
        }
        PresentationPlan plan;
        plan.event = PresentationEvent::WAIT_FOR_DRAIN;
        return plan;
    }

    if (!initialized_) {
        return AnchorFrame(
            ptsUs, decodedAtNs, PresentationEvent::INITIAL_ANCHOR, slotClock);
    }

    if (ptsUs == lastPtsUs_) {
        // A permanently repeated timestamp must not become a permanent DROP
        // state. Treat it as a broken host timeline and fall back to a fresh
        // local anchor until valid PTS progression resumes.
        if (queueEmpty) {
            return AnchorFrame(
                ptsUs, decodedAtNs, PresentationEvent::DUPLICATE_PTS, slotClock);
        }
        reanchorPending_ = true;
        pendingReanchorEvent_ = PresentationEvent::DUPLICATE_PTS;
        PresentationPlan plan;
        plan.event = PresentationEvent::WAIT_FOR_DRAIN;
        return plan;
    }

    const int64_t ptsDeltaUs = ptsUs - lastPtsUs_;
    if (ptsDeltaUs < 0 || ptsDeltaUs > discontinuityNs_ / kNanosecondsPerMicrosecond) {
        if (queueEmpty) {
            return AnchorFrame(
                ptsUs, decodedAtNs, PresentationEvent::DISCONTINUITY, slotClock);
        }
        reanchorPending_ = true;
        pendingReanchorEvent_ = PresentationEvent::DISCONTINUITY;
        PresentationPlan plan;
        plan.event = PresentationEvent::WAIT_FOR_DRAIN;
        return plan;
    }
    lastPtsUs_ = ptsUs;

    int64_t targetTimeNs = anchorTargetNs_ +
        (ptsUs - anchorPtsUs_) * kNanosecondsPerMicrosecond;

    // Small late frames move the complete timeline forward and accumulate a
    // known phase-shift debt. Once the decode/transport delay recovers, repay
    // only that debt. This restores low latency quickly without mistaking a
    // normal decoder output burst (which has no debt) for excessive queuing.
    const int64_t surplusLeadNs =
        targetTimeNs - decodedAtNs - initialLeadNs_;
    PresentationEvent event = PresentationEvent::NONE;
    int64_t latenessNs = 0;
    if (queueEmpty && phaseShiftDebtNs_ > 0 &&
        surplusLeadNs > kDriftDeadbandNs) {
        const int64_t repaymentNs = std::min(phaseShiftDebtNs_, surplusLeadNs);
        anchorTargetNs_ -= repaymentNs;
        targetTimeNs -= repaymentNs;
        phaseShiftDebtNs_ -= repaymentNs;
        driftErrorEmaNs_ = 0;
        event = PresentationEvent::PHASE_SHIFT;
        latenessNs = -repaymentNs;
    }

    if (queueEmpty && targetTimeNs - decodedAtNs > maxFutureLeadNs_) {
        return AnchorFrame(
            ptsUs, decodedAtNs, PresentationEvent::CATCH_UP, slotClock);
    }

    if (queueEmpty) {
        ApplySlowDriftCorrection(decodedAtNs, targetTimeNs);
    }

    const int64_t requiredTargetNs = decodedAtNs + submitLeadNs_;
    if (queueEmpty && targetTimeNs < requiredTargetNs) {
        const int64_t latenessNs = requiredTargetNs - targetTimeNs;
        if (latenessNs <= frameIntervalNs_ / 2) {
            // Move the complete timeline forward. This keeps all following PTS
            // intervals intact instead of switching this frame to immediate mode.
            anchorTargetNs_ += latenessNs;
            phaseShiftDebtNs_ += latenessNs;
            driftErrorEmaNs_ = 0;
            consecutiveSevereLateFrames_ = 0;
            event = PresentationEvent::PHASE_SHIFT;
            targetTimeNs = requiredTargetNs;
            return ScheduleTarget(
                targetTimeNs, decodedAtNs, event, latenessNs, slotClock);
        }

        consecutiveSevereLateFrames_++;
        if (consecutiveSevereLateFrames_ >= kSevereLateFramesBeforeRebuffer) {
            return AnchorFrame(
                ptsUs, decodedAtNs, PresentationEvent::REBUFFER, slotClock);
        }

        PresentationPlan plan;
        plan.event = PresentationEvent::LATE_DROP;
        plan.latenessNs = latenessNs;
        return plan;
    }

    consecutiveSevereLateFrames_ = 0;
    return ScheduleTarget(
        targetTimeNs, decodedAtNs, event, latenessNs, slotClock);
}
