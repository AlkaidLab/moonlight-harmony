#include "rolling_frame_rate.h"

#include <algorithm>

namespace {
constexpr int64_t kRecentSampleGraceMs = 100;
}

RollingFrameRateTracker::RollingFrameRateTracker(int64_t windowMs)
    : windowMs_(std::max<int64_t>(windowMs, 1)) {
}

void RollingFrameRateTracker::Reset() {
    start_ = 0;
    size_ = 0;
}

const RollingFrameRateTracker::Sample& RollingFrameRateTracker::SampleAt(
        size_t offset) const {
    return samples_[(start_ + offset) % kSampleCapacity];
}

RollingFrameRateTracker::Sample& RollingFrameRateTracker::LastSample() {
    return samples_[(start_ + size_ - 1) % kSampleCapacity];
}

void RollingFrameRateTracker::Record(
        int64_t timestampMs, uint64_t cumulativeFrames) {
    if (size_ > 0) {
        Sample& last = LastSample();
        if (timestampMs < last.timestampMs ||
            cumulativeFrames < last.cumulativeFrames) {
            Reset();
        } else if (timestampMs == last.timestampMs) {
            last.cumulativeFrames = cumulativeFrames;
            return;
        }
    }

    size_t insertIndex = 0;
    if (size_ < kSampleCapacity) {
        insertIndex = (start_ + size_) % kSampleCapacity;
        size_++;
    } else {
        insertIndex = start_;
        start_ = (start_ + 1) % kSampleCapacity;
    }
    samples_[insertIndex] = {timestampMs, cumulativeFrames};
}

double RollingFrameRateTracker::GetRate(int64_t nowMs) const {
    if (size_ < 2) {
        return 0.0;
    }

    const Sample& latest = SampleAt(size_ - 1);
    if (nowMs < latest.timestampMs ||
        nowMs - latest.timestampMs >= windowMs_) {
        return 0.0;
    }

    const int64_t cutoffMs = nowMs - windowMs_;
    size_t baselineOffset = 0;
    for (size_t i = 1; i < size_; ++i) {
        if (SampleAt(i).timestampMs > cutoffMs) {
            break;
        }
        baselineOffset = i;
    }

    const Sample& baseline = SampleAt(baselineOffset);
    const int64_t rateEndMs = nowMs - latest.timestampMs <= kRecentSampleGraceMs
        ? latest.timestampMs
        : nowMs;
    const int64_t elapsedMs = rateEndMs - baseline.timestampMs;
    if (elapsedMs <= 0 || latest.cumulativeFrames < baseline.cumulativeFrames) {
        return 0.0;
    }

    const uint64_t frameDelta =
        latest.cumulativeFrames - baseline.cumulativeFrames;
    return static_cast<double>(frameDelta) * 1000.0 /
        static_cast<double>(elapsedMs);
}
