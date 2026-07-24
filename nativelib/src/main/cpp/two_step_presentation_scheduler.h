#ifndef TWO_STEP_PRESENTATION_SCHEDULER_H
#define TWO_STEP_PRESENTATION_SCHEDULER_H

#include "presentation_scheduler.h"

#include <array>
#include <cstddef>
#include <cstdint>

enum class PreparedPresentationAction {
    SCHEDULE,
    IMMEDIATE,
    DROP,
};

enum class PreparedPresentationEvent {
    NONE,
    MISSING_TARGET,
    EXPIRED_TARGET,
    FUTURE_TARGET,
    NON_MONOTONIC_PTS,
};

struct PreparedPresentationPlan {
    PreparedPresentationAction action = PreparedPresentationAction::IMMEDIATE;
    PreparedPresentationEvent event = PreparedPresentationEvent::NONE;
    int64_t targetTimeNs = 0;
    int64_t targetLeadNs = 0;
};

struct TwoStepPresentationStats {
    uint64_t preparedTargets = 0;
    uint64_t scheduledFrames = 0;
    uint64_t expiredTargets = 0;
    uint64_t missingTargets = 0;
    uint64_t futureTargets = 0;
    uint64_t nonMonotonicDrops = 0;
    uint64_t renderAtTimeFallbacks = 0;
    uint64_t leadUnder1Ms = 0;
    uint64_t lead1To2Ms = 0;
    uint64_t lead2To4Ms = 0;
    uint64_t lead4To8Ms = 0;
    uint64_t leadAtLeast8Ms = 0;
    uint64_t pendingHighWater = 0;
};

class PresentationTargetHandle {
public:
    PresentationTargetHandle() = default;
    explicit operator bool() const { return id_ != 0; }

private:
    explicit PresentationTargetHandle(uint64_t id) : id_(id) {}

    uint64_t id_ = 0;

    friend class TwoStepPresentationScheduler;
};

// Computes targets before decode and validates them after decode. Targets are
// keyed by PTS, so decoder buffer indices and output callback order are not
// part of the association contract.
class TwoStepPresentationScheduler {
public:
    void Configure(double fps);
    void Reset();

    PresentationTargetHandle PrepareFrame(int64_t ptsUs, int64_t preparedAtNs);
    void DiscardFrame(PresentationTargetHandle handle);
    void DiscardFrame(int64_t ptsUs);
    PreparedPresentationPlan PlanDecodedFrame(
        int64_t ptsUs, int64_t decodedAtNs);
    void NoteRenderAtTimeFallback();
    void ResetStats();

    size_t GetPendingTargetCount() const { return pendingTargetCount_; }
    int64_t GetInitialLeadNs() const { return scheduler_.GetInitialLeadNs(); }
    TwoStepPresentationStats GetStats() const { return stats_; }

private:
    struct PreparedTarget {
        uint64_t id = 0;
        int64_t ptsUs = 0;
        int64_t targetTimeNs = 0;
        bool valid = false;
    };

    void ClearTargets();
    PresentationTargetHandle StoreTarget(int64_t ptsUs, int64_t targetTimeNs);
    bool TakeTarget(int64_t ptsUs, int64_t& targetTimeNs);
    void NoteSubmittedPts(int64_t ptsUs);
    void RecordTargetLead(int64_t targetLeadNs);

    static constexpr size_t kTargetCapacity = 64;

    PtsPresentationScheduler scheduler_;
    std::array<PreparedTarget, kTargetCapacity> targets_{};
    size_t targetWriteIndex_ = 0;
    size_t pendingTargetCount_ = 0;
    // Keep IDs monotonic across Reset so stale guards cannot match new targets.
    uint64_t nextTargetId_ = 1;
    int64_t submitLeadNs_ = 2000000LL;
    int64_t maxFutureLeadNs_ = 50000000LL;
    int64_t lastSubmittedPtsUs_ = 0;
    bool hasSubmittedPts_ = false;
    TwoStepPresentationStats stats_{};
};

#endif // TWO_STEP_PRESENTATION_SCHEDULER_H
