// SPDX-License-Identifier: Apache-2.0

#include "core/music_scene_author.h"

#include "core/dsp_parameters.h"

#include <algorithm>

namespace moonlight::haptics::core {
namespace {

float Clamp01(float value) noexcept {
    return std::max(0.0F, std::min(1.0F, value));
}

} // namespace

MusicSceneIntent MusicSceneAuthor::Process(float continuousAmplitude,
                                           float lowFrequencySupport,
                                           float transientAmplitude,
                                           bool hasTransient,
                                           uint64_t timestampUs) noexcept {
    MusicSceneIntent intent;

    const float input = Clamp01(continuousAmplitude);
    const float support = Clamp01(lowFrequencySupport);
    const float inputFloor = grooveActive_
        ? parameters::kMusicGrooveBedSustainInput
        : parameters::kMusicGrooveBedStartInput;
    const float supportFloor = grooveActive_
        ? parameters::kMusicGrooveBedSustainSupport
        : parameters::kMusicGrooveBedStartSupport;

    if (input >= inputFloor && support >= supportFloor) {
        const float normalizedSupport = Clamp01(
            (support - supportFloor) /
            (parameters::kMusicGrooveBedFullSupport - supportFloor));
        const float supportScale =
            parameters::kMusicGrooveBedMinimumSupportScale +
            (1.0F - parameters::kMusicGrooveBedMinimumSupportScale) *
                normalizedSupport;
        const float bed = std::min(
            input * parameters::kMusicGrooveBedGain * supportScale,
            parameters::kMusicGrooveBedMaximumAmplitude);
        if (bed >= parameters::kMusicGrooveBedOutputFloor) {
            intent.continuousAmplitude = bed;
            grooveActive_ = true;
        } else {
            grooveActive_ = false;
        }
    } else {
        grooveActive_ = false;
    }

    intent.transientAmplitude = Clamp01(transientAmplitude);
    if (hasTransient) {
        intent.restartTransient = !hasTransientHistory_ ||
            timestampUs < lastTransientTimestampUs_ ||
            timestampUs - lastTransientTimestampUs_ >=
                parameters::kMusicRestartGapUs;
        const float restartGain = intent.restartTransient
            ? parameters::kMusicRestartTransientGain
            : 1.0F;
        intent.transientAmplitude = Clamp01(
            intent.transientAmplitude * parameters::kMusicTransientGain *
            restartGain);
        hasTransientHistory_ = true;
        lastTransientTimestampUs_ = timestampUs;
    }

    return intent;
}

void MusicSceneAuthor::Reset() noexcept {
    grooveActive_ = false;
    hasTransientHistory_ = false;
    lastTransientTimestampUs_ = 0U;
}

} // namespace moonlight::haptics::core
