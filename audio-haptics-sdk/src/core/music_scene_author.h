// SPDX-License-Identifier: Apache-2.0

#ifndef MOONLIGHT_HAPTICS_CORE_MUSIC_SCENE_AUTHOR_H
#define MOONLIGHT_HAPTICS_CORE_MUSIC_SCENE_AUTHOR_H

#include <cstdint>

namespace moonlight::haptics::core {

struct MusicSceneIntent {
    float continuousAmplitude = 0.0F;
    float transientAmplitude = 0.0F;
    bool restartTransient = false;
};

/** Authors portable MUSIC intent without knowing the target actuator. */
class MusicSceneAuthor {
public:
    MusicSceneIntent Process(float continuousAmplitude,
                             float lowFrequencySupport,
                             float transientAmplitude,
                             bool hasTransient,
                             uint64_t timestampUs) noexcept;

    void Reset() noexcept;

private:
    bool grooveActive_ = false;
    bool hasTransientHistory_ = false;
    uint64_t lastTransientTimestampUs_ = 0U;
};

} // namespace moonlight::haptics::core

#endif // MOONLIGHT_HAPTICS_CORE_MUSIC_SCENE_AUTHOR_H
