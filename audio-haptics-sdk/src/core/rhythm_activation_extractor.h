// SPDX-License-Identifier: Apache-2.0

#ifndef MOONLIGHT_HAPTICS_CORE_RHYTHM_ACTIVATION_EXTRACTOR_H
#define MOONLIGHT_HAPTICS_CORE_RHYTHM_ACTIVATION_EXTRACTOR_H

#include "core/causal_onset_detector.h"
#include "core/feature_extractor.h"

#include <cstdint>

namespace moonlight::haptics::core {

struct RhythmActivationFrame {
    float activation = 0.0F;
    float lowFrequencySupport = 0.0F;
    bool audible = false;
    bool acousticOnset = false;
    bool evidenceEvent = false;
};

/*
 * Converts broadband DSP features into a causal pulse-likelihood stream.
 *
 * Low-band spectral flux and the actuator-shaped tactile envelope are primary
 * evidence. Mid/high-band novelty and the general onset detector may assist,
 * but cannot independently become a strong tempo event. This keeps speech and
 * cymbals from dominating the rhythm clock while preserving their authored
 * one-shot haptics elsewhere in the engine.
 */
class RhythmActivationExtractor {
public:
    RhythmActivationExtractor(uint32_t sampleRate, uint32_t hopSize);

    RhythmActivationFrame Process(const FeatureFrame& features,
                                  const OnsetResult& onset) noexcept;

    void Reset() noexcept;

private:
    uint32_t warmupHops_ = 0U;
    uint32_t framesSeen_ = 0U;
    float slowRhythmNovelty_ = 0.0F;
    float slowBroadbandNovelty_ = 0.0F;
    float slowTactileMeanAbsolute_ = 0.0F;
};

} // namespace moonlight::haptics::core

#endif // MOONLIGHT_HAPTICS_CORE_RHYTHM_ACTIVATION_EXTRACTOR_H
