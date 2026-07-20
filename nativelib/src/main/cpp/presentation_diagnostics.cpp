#include "presentation_diagnostics.h"

#include <algorithm>

void PresentationDiagnostics::Reset() {
    stats_ = {};
    lastTargetTimeNs_ = 0;
}

int64_t PresentationDiagnostics::NormalizeVsyncAnchor(
        int64_t observedVsyncNs, int64_t nowNs, int64_t vsyncPeriodNs) {
    if (nowNs <= observedVsyncNs) {
        return observedVsyncNs;
    }
    return observedVsyncNs +
        ((nowNs - observedVsyncNs) / vsyncPeriodNs) * vsyncPeriodNs;
}

int64_t PresentationDiagnostics::VsyncSlotAtOrAfter(
        int64_t targetTimeNs, int64_t anchorNs, int64_t vsyncPeriodNs) {
    const int64_t deltaNs = targetTimeNs - anchorNs;
    const int64_t slotOffset = deltaNs >= 0
        ? (deltaNs + vsyncPeriodNs - 1) / vsyncPeriodNs
        : deltaNs / vsyncPeriodNs;
    return anchorNs + slotOffset * vsyncPeriodNs;
}

void PresentationDiagnostics::Record(
        int64_t targetTimeNs, int64_t nowNs,
        int64_t observedVsyncNs, int64_t vsyncPeriodNs) {
    if (lastTargetTimeNs_ > 0 && targetTimeNs < lastTargetTimeNs_) {
        const int64_t regressionNs = lastTargetTimeNs_ - targetTimeNs;
        stats_.targetRegressionCount++;
        stats_.maxTargetRegressionNs = std::max(
            stats_.maxTargetRegressionNs, regressionNs);
    }

    if (observedVsyncNs > 0 && vsyncPeriodNs > 0) {
        const int64_t anchorNs = NormalizeVsyncAnchor(
            observedVsyncNs, nowNs, vsyncPeriodNs);
        const int64_t currentSlotNs = VsyncSlotAtOrAfter(
            targetTimeNs, anchorNs, vsyncPeriodNs);
        if (lastTargetTimeNs_ > 0) {
            const int64_t previousSlotNs = VsyncSlotAtOrAfter(
                lastTargetTimeNs_, anchorNs, vsyncPeriodNs);
            if (currentSlotNs == previousSlotNs) {
                stats_.sameVsyncSlotCount++;
            } else if (currentSlotNs < previousSlotNs) {
                stats_.vsyncSlotRegressionCount++;
            }
        }

        const int64_t queueDepthSlots = std::max<int64_t>(
            0, (currentSlotNs - anchorNs) / vsyncPeriodNs);
        stats_.maxQueueDepthSlots = std::max(
            stats_.maxQueueDepthSlots, queueDepthSlots);
    }

    lastTargetTimeNs_ = targetTimeNs;
}
