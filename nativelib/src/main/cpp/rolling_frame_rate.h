#ifndef ROLLING_FRAME_RATE_H
#define ROLLING_FRAME_RATE_H

#include <array>
#include <cstddef>
#include <cstdint>

class RollingFrameRateTracker {
public:
    explicit RollingFrameRateTracker(int64_t windowMs = 3000);

    void Reset();
    void Record(int64_t timestampMs, uint64_t cumulativeFrames);
    double GetRate(int64_t nowMs) const;

private:
    struct Sample {
        int64_t timestampMs = 0;
        uint64_t cumulativeFrames = 0;
    };

    static constexpr size_t kSampleCapacity = 1024;

    const Sample& SampleAt(size_t offset) const;
    Sample& LastSample();

    std::array<Sample, kSampleCapacity> samples_{};
    size_t start_ = 0;
    size_t size_ = 0;
    int64_t windowMs_ = 3000;
};

#endif // ROLLING_FRAME_RATE_H
