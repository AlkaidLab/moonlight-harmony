// SPDX-License-Identifier: Apache-2.0

#ifndef MOONLIGHT_HAPTICS_CORE_GAME_SCENE_AUTHOR_H
#define MOONLIGHT_HAPTICS_CORE_GAME_SCENE_AUTHOR_H

#include "core/causal_onset_detector.h"
#include "core/feature_extractor.h"

#include <cstdint>

namespace moonlight::haptics::core {

struct GameSceneIntent {
    float continuousAmplitude = 0.0F;
    float transientAmplitude = 0.0F;
    float transientDurationMs = 25.0F;
    float sharpness = 0.0F;
    float confidence = 0.0F;
    bool hasTransient = false;
};

/** Authors portable GAME intent without selecting an actuator primitive. */
class GameSceneAuthor {
public:
    GameSceneIntent Process(float continuousInput,
                            float lowFrequencySupport,
                            float transientAmplitude,
                            bool hasTransient,
                            const FeatureFrame& features,
                            const OnsetResult& onset,
                            bool onsetOnStableBeat = false,
                            float rhythmConfidence = 0.0F) noexcept;

    void Reset() noexcept;

private:
    bool continuousActive_ = false;
    uint32_t qualifyingHops_ = 0U;
    uint32_t continuousMissHops_ = 0U;
    uint32_t transientDuckHops_ = 0U;
    float continuousEnvelope_ = 0.0F;
    float noiseFloor_ = 0.0F;
    float fatigue_ = 0.0F;
    float transientActivity_ = 0.0F;
};

} // namespace moonlight::haptics::core

#endif // MOONLIGHT_HAPTICS_CORE_GAME_SCENE_AUTHOR_H
