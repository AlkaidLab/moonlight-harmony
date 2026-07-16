// SPDX-License-Identifier: Apache-2.0

#ifndef MOONLIGHT_HAPTICS_CORE_CAUSAL_ONSET_DETECTOR_H
#define MOONLIGHT_HAPTICS_CORE_CAUSAL_ONSET_DETECTOR_H

#include "core/feature_extractor.h"

#include <array>
#include <cstddef>
#include <cstdint>

namespace moonlight::haptics::core {

struct OnsetResult {
    bool detected = false;
    float amplitude = 0.0F;
    float sharpness = 0.0F;
    float confidence = 0.0F;
};

class CausalOnsetDetector {
public:
    CausalOnsetDetector(uint32_t sampleRate, uint32_t hopSize);

    OnsetResult Process(const FeatureFrame& features, float sensitivity) noexcept;
    void Reset() noexcept;

private:
    float MedianHistory() const noexcept;
    float MedianAbsoluteDeviation(float median) const noexcept;
    void PushHistory(float value) noexcept;

    static constexpr std::size_t kHistoryCapacity = 64;
    std::array<float, kHistoryCapacity> history_{};
    uint32_t historyPosition_ = 0;
    uint32_t historyCount_ = 0;
    uint32_t framesSeen_ = 0;
    uint32_t framesSinceOnset_ = 0;
    uint32_t refractoryFrames_ = 0;
    uint32_t sensitiveRefractoryFrames_ = 0;
    float slowRms_ = 0.0F;
    float previousRms_ = 0.0F;
    float previousNovelty_ = 0.0F;
    float slowTactileMeanAbsolute_ = 0.0F;
    float previousTactileMeanAbsolute_ = 0.0F;
};

} // namespace moonlight::haptics::core

#endif // MOONLIGHT_HAPTICS_CORE_CAUSAL_ONSET_DETECTOR_H
