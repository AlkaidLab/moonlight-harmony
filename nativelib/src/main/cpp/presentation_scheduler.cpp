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
constexpr int64_t kNanosecondsPerMicrosecond = 1000LL;
constexpr int64_t kExtraPresentationLeadNs = 2000000LL;
constexpr int64_t kMinSubmitLeadNs = 1000000LL;
constexpr int64_t kMaxSubmitLeadNs = 2000000LL;
constexpr int64_t kDriftDeadbandNs = 2000000LL;
constexpr int64_t kMaxDriftCorrectionPerFrameNs = 20000LL;
constexpr int kSevereLateFramesBeforeRebuffer = 2;
} // namespace

void PtsPresentationScheduler::Configure(double fps) {
    const double safeFps = fps > 0.0 ? fps : 60.0;
    frameIntervalNs_ = static_cast<int64_t>(
        std::llround(static_cast<double>(kNanosecondsPerSecond) / safeFps));
    frameIntervalNs_ = std::max<int64_t>(frameIntervalNs_, 1000000LL);
    initialLeadNs_ = frameIntervalNs_ + kExtraPresentationLeadNs;
    submitLeadNs_ = std::clamp(frameIntervalNs_ / 8,
                               kMinSubmitLeadNs, kMaxSubmitLeadNs);
    discontinuityNs_ = std::max<int64_t>(250000000LL, frameIntervalNs_ * 12);
    Reset();
}

void PtsPresentationScheduler::Reset() {
    initialized_ = false;
    anchorPtsUs_ = 0;
    anchorTargetNs_ = 0;
    lastPtsUs_ = 0;
    driftErrorEmaNs_ = 0;
    consecutiveSevereLateFrames_ = 0;
}

PresentationPlan PtsPresentationScheduler::AnchorFrame(
        int64_t ptsUs, int64_t decodedAtNs, PresentationEvent event) {
    initialized_ = true;
    anchorPtsUs_ = ptsUs;
    anchorTargetNs_ = decodedAtNs + initialLeadNs_;
    lastPtsUs_ = ptsUs;
    driftErrorEmaNs_ = 0;
    consecutiveSevereLateFrames_ = 0;

    PresentationPlan plan;
    plan.action = PresentationAction::SCHEDULE;
    plan.event = event;
    plan.targetTimeNs = anchorTargetNs_;
    return plan;
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
        PresentationPlan plan;
        plan.event = PresentationEvent::DUPLICATE_PTS;
        return plan;
    }

    const int64_t ptsDeltaUs = ptsUs - lastPtsUs_;
    if (ptsDeltaUs < 0 || ptsDeltaUs > discontinuityNs_ / kNanosecondsPerMicrosecond) {
        return AnchorFrame(ptsUs, decodedAtNs, PresentationEvent::DISCONTINUITY);
    }
    lastPtsUs_ = ptsUs;

    int64_t targetTimeNs = anchorTargetNs_ +
        (ptsUs - anchorPtsUs_) * kNanosecondsPerMicrosecond;
    ApplySlowDriftCorrection(decodedAtNs, targetTimeNs);

    const int64_t requiredTargetNs = decodedAtNs + submitLeadNs_;
    if (targetTimeNs < requiredTargetNs) {
        const int64_t latenessNs = requiredTargetNs - targetTimeNs;
        if (latenessNs <= frameIntervalNs_ / 2) {
            // Move the complete timeline forward. This keeps all following PTS
            // intervals intact instead of switching this frame to immediate mode.
            anchorTargetNs_ += latenessNs;
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
    plan.targetTimeNs = targetTimeNs;
    return plan;
}
