/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#ifndef PRESENTATION_SCHEDULER_H
#define PRESENTATION_SCHEDULER_H

#include <cstdint>

enum class PresentationAction {
    SCHEDULE,
    DROP,
};

enum class PresentationEvent {
    NONE,
    INITIAL_ANCHOR,
    DISCONTINUITY,
    PHASE_SHIFT,
    REBUFFER,
    DUPLICATE_PTS,
    INVALID_PTS,
    LATE_DROP,
};

struct PresentationPlan {
    PresentationAction action = PresentationAction::DROP;
    PresentationEvent event = PresentationEvent::NONE;
    int64_t targetTimeNs = 0;
    int64_t latenessNs = 0;
};

// Maps host PTS to a continuous local presentation timeline. RenderService
// owns display-slot selection; decoder arrival never replaces normal cadence.
class PtsPresentationScheduler {
public:
    void Configure(double fps);
    void Reset();
    PresentationPlan PlanFrame(int64_t ptsUs, int64_t decodedAtNs);

    int64_t GetInitialLeadNs() const { return initialLeadNs_; }

private:
    PresentationPlan AnchorFrame(int64_t ptsUs, int64_t decodedAtNs,
                                 PresentationEvent event,
                                 int64_t latenessNs = 0);
    void ApplySlowDriftCorrection(int64_t decodedAtNs, int64_t& targetTimeNs);

    int64_t frameIntervalNs_ = 16666667LL;
    int64_t initialLeadNs_ = 18666667LL;
    int64_t submitLeadNs_ = 2000000LL;
    int64_t discontinuityNs_ = 250000000LL;

    bool initialized_ = false;
    int64_t anchorPtsUs_ = 0;
    int64_t anchorTargetNs_ = 0;
    int64_t lastPtsUs_ = 0;
    int64_t driftErrorEmaNs_ = 0;
    int64_t phaseShiftDebtNs_ = 0;
    int consecutiveSevereLateFrames_ = 0;
};

#endif // PRESENTATION_SCHEDULER_H
