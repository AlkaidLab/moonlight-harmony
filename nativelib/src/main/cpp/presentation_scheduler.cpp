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
constexpr double kAdaptiveBurstFpsThreshold = 119.88;
constexpr int kMaxAdaptiveBurstCadenceIntervals = 3;
constexpr int64_t kDriftDeadbandNs = 2 * kNanosecondsPerMillisecond;
constexpr int64_t kMaxDriftCorrectionPerFrameNs = 20 * kNanosecondsPerMicrosecond;
constexpr int kSevereLateFramesBeforeRebuffer = 2;

int64_t CalculateFutureCadenceBudgetNs(double fps, int64_t frameIntervalNs) {
    if (fps >= kAdaptiveBurstFpsThreshold) {
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
    const int64_t futureCadenceBudgetNs =
        CalculateFutureCadenceBudgetNs(safeFps, frameIntervalNs_);
    maxFutureLeadNs_ = initialLeadNs_ + futureCadenceBudgetNs +
        kPtsQuantizationSlackNs;
    // A fourth high-refresh frame may arrive in the same decoder callback
    // burst. This cap is selected per frame and never changes steady-state lead.
    maxBurstFutureLeadNs_ = maxFutureLeadNs_;
    if (safeFps >= kAdaptiveBurstFpsThreshold) {
        maxBurstFutureLeadNs_ = initialLeadNs_ +
            frameIntervalNs_ * kMaxAdaptiveBurstCadenceIntervals +
            kPtsQuantizationSlackNs;
    }
    discontinuityNs_ = std::max<int64_t>(
        250 * kNanosecondsPerMillisecond, frameIntervalNs_ * 12);
    Reset();
}

void PtsPresentationScheduler::Reset() {
    initialized_ = false;
    anchorPtsUs_ = 0;
    anchorTargetNs_ = 0;
    lastPtsUs_ = 0;
    lastDecodedAtNs_ = 0;
    driftErrorEmaNs_ = 0;
    phaseShiftDebtNs_ = 0;
    consecutiveSevereLateFrames_ = 0;
}

PresentationPlan PtsPresentationScheduler::AnchorFrame(
        int64_t ptsUs, int64_t decodedAtNs, PresentationEvent event) {
    initialized_ = true;
    anchorPtsUs_ = ptsUs;
    anchorTargetNs_ = decodedAtNs + initialLeadNs_;
    lastPtsUs_ = ptsUs;
    lastDecodedAtNs_ = decodedAtNs;
    driftErrorEmaNs_ = 0;
    phaseShiftDebtNs_ = 0;
    consecutiveSevereLateFrames_ = 0;

    PresentationPlan plan;
    plan.action = PresentationAction::SCHEDULE;
    plan.event = event;
    plan.targetTimeNs = anchorTargetNs_;
    return plan;
}

bool PtsPresentationScheduler::IsDecoderOutputBurst(
        int64_t ptsDeltaUs, int64_t decodedAtNs) const {
    if (lastDecodedAtNs_ <= 0 || decodedAtNs < lastDecodedAtNs_) {
        return false;
    }

    const int64_t decodedDeltaNs = decodedAtNs - lastDecodedAtNs_;
    const int64_t ptsDeltaNs = ptsDeltaUs * kNanosecondsPerMicrosecond;
    return maxBurstFutureLeadNs_ > maxFutureLeadNs_ &&
        decodedDeltaNs <= frameIntervalNs_ / 2 &&
        ptsDeltaNs >= frameIntervalNs_ / 2 &&
        ptsDeltaNs <= frameIntervalNs_ + frameIntervalNs_ / 2;
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
    if (ptsUs < 0 || decodedAtNs <= 0) {
        PresentationPlan plan;
        plan.event = PresentationEvent::INVALID_PTS;
        return plan;
    }

    if (!initialized_) {
        return AnchorFrame(ptsUs, decodedAtNs, PresentationEvent::INITIAL_ANCHOR);
    }

    if (ptsUs == lastPtsUs_) {
        // A permanently repeated timestamp must not become a permanent DROP
        // state. Treat it as a broken host timeline and fall back to a fresh
        // local anchor until valid PTS progression resumes.
        return AnchorFrame(ptsUs, decodedAtNs, PresentationEvent::DUPLICATE_PTS);
    }

    const int64_t ptsDeltaUs = ptsUs - lastPtsUs_;
    if (ptsDeltaUs < 0 || ptsDeltaUs > discontinuityNs_ / kNanosecondsPerMicrosecond) {
        return AnchorFrame(ptsUs, decodedAtNs, PresentationEvent::DISCONTINUITY);
    }
    const bool decoderOutputBurst =
        IsDecoderOutputBurst(ptsDeltaUs, decodedAtNs);
    lastPtsUs_ = ptsUs;
    lastDecodedAtNs_ = decodedAtNs;

    const int64_t futureLeadLimitNs = decoderOutputBurst
        ? maxBurstFutureLeadNs_
        : maxFutureLeadNs_;

    int64_t targetTimeNs = anchorTargetNs_ +
        (ptsUs - anchorPtsUs_) * kNanosecondsPerMicrosecond;

    // Small late frames move the complete timeline forward and accumulate a
    // known phase-shift debt. Once the decode/transport delay recovers, repay
    // only that debt. This restores low latency quickly without mistaking a
    // normal decoder output burst (which has no debt) for excessive queuing.
    const int64_t surplusLeadNs =
        targetTimeNs - decodedAtNs - initialLeadNs_;
    if (phaseShiftDebtNs_ > 0 && surplusLeadNs > kDriftDeadbandNs) {
        const int64_t repaymentNs = std::min(phaseShiftDebtNs_, surplusLeadNs);
        anchorTargetNs_ -= repaymentNs;
        targetTimeNs -= repaymentNs;
        phaseShiftDebtNs_ -= repaymentNs;
        driftErrorEmaNs_ = 0;
        consecutiveSevereLateFrames_ = 0;

        if (targetTimeNs - decodedAtNs <= futureLeadLimitNs) {
            PresentationPlan plan;
            plan.action = PresentationAction::SCHEDULE;
            plan.event = PresentationEvent::PHASE_SHIFT;
            plan.targetTimeNs = targetTimeNs;
            plan.latenessNs = -repaymentNs;
            return plan;
        }
    }

    if (targetTimeNs - decodedAtNs > futureLeadLimitNs) {
        // This is not jitter absorbed by our own phase shift; it is decoded
        // output arriving in a burst ahead of the presentation timeline. A
        // fresh anchor gives all queued burst frames an immediate timestamp,
        // so the Surface can keep the newest frame instead of preserving lag.
        return AnchorFrame(ptsUs, decodedAtNs, PresentationEvent::CATCH_UP);
    }

    ApplySlowDriftCorrection(decodedAtNs, targetTimeNs);

    const int64_t requiredTargetNs = decodedAtNs + submitLeadNs_;
    if (targetTimeNs < requiredTargetNs) {
        const int64_t latenessNs = requiredTargetNs - targetTimeNs;
        if (latenessNs <= frameIntervalNs_ / 2) {
            // Move the complete timeline forward. This keeps all following PTS
            // intervals intact instead of switching this frame to immediate mode.
            anchorTargetNs_ += latenessNs;
            phaseShiftDebtNs_ += latenessNs;
            driftErrorEmaNs_ = 0;
            consecutiveSevereLateFrames_ = 0;

            PresentationPlan plan;
            plan.action = PresentationAction::SCHEDULE;
            plan.event = PresentationEvent::PHASE_SHIFT;
            plan.targetTimeNs = requiredTargetNs;
            plan.latenessNs = latenessNs;
            return plan;
        }

        consecutiveSevereLateFrames_++;
        if (consecutiveSevereLateFrames_ >= kSevereLateFramesBeforeRebuffer) {
            return AnchorFrame(ptsUs, decodedAtNs, PresentationEvent::REBUFFER);
        }

        PresentationPlan plan;
        plan.event = PresentationEvent::LATE_DROP;
        plan.latenessNs = latenessNs;
        return plan;
    }

    consecutiveSevereLateFrames_ = 0;
    PresentationPlan plan;
    plan.action = PresentationAction::SCHEDULE;
    if (decoderOutputBurst &&
        targetTimeNs - decodedAtNs > maxFutureLeadNs_) {
        plan.event = PresentationEvent::BURST_HEADROOM;
    }
    plan.targetTimeNs = targetTimeNs;
    return plan;
}
