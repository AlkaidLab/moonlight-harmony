#ifndef PRESENTATION_DIAGNOSTICS_H
#define PRESENTATION_DIAGNOSTICS_H

#include <cstdint>

struct PresentationTimingStats {
    int64_t targetRegressionCount = 0;
    int64_t maxTargetRegressionNs = 0;
    int64_t sameVsyncSlotCount = 0;
    int64_t vsyncSlotRegressionCount = 0;
    int64_t maxQueueDepthSlots = 0;
};

class PresentationDiagnostics {
public:
    void Reset();
    void Record(int64_t targetTimeNs, int64_t nowNs,
                int64_t observedVsyncNs, int64_t vsyncPeriodNs);

    const PresentationTimingStats& GetStats() const { return stats_; }

private:
    static int64_t NormalizeVsyncAnchor(
        int64_t observedVsyncNs, int64_t nowNs, int64_t vsyncPeriodNs);
    static int64_t VsyncSlotAtOrAfter(
        int64_t targetTimeNs, int64_t anchorNs, int64_t vsyncPeriodNs);

    PresentationTimingStats stats_;
    int64_t lastTargetTimeNs_ = 0;
};

#endif // PRESENTATION_DIAGNOSTICS_H
