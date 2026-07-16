// SPDX-License-Identifier: Apache-2.0

#include "core/rhythm_activation_extractor.h"

#include "core/dsp_parameters.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace moonlight::haptics::core {

namespace {

constexpr float kAverageAlpha = 0.020F;

float Clamp01(float value) noexcept {
    return std::max(0.0F, std::min(1.0F, value));
}

uint32_t SecondsToHops(float seconds,
                       uint32_t sampleRate,
                       uint32_t hopSize) noexcept {
    return std::max(
        1U,
        static_cast<uint32_t>(std::ceil(
            static_cast<double>(seconds) * static_cast<double>(sampleRate) /
            static_cast<double>(hopSize))));
}

} // namespace

RhythmActivationExtractor::RhythmActivationExtractor(uint32_t sampleRate,
                                                       uint32_t hopSize)
    : warmupHops_(SecondsToHops(0.750F, sampleRate, hopSize)) {
    Reset();
}

RhythmActivationFrame RhythmActivationExtractor::Process(
    const FeatureFrame& features,
    const OnsetResult& onset) noexcept {
    RhythmActivationFrame output;
    output.audible = features.rms >= parameters::kMinimumRms;
    output.acousticOnset = onset.detected;

    // Per-band flux is normalized by bin count in FeatureExtractor, so these
    // weights describe musical role rather than compensating for band width.
    const float rhythmNovelty = features.lowNovelty +
                                0.35F * features.midNovelty +
                                0.08F * features.highNovelty;
    const float noveltySum = features.lowNovelty + features.midNovelty +
                             features.highNovelty + 1.0e-6F;
    const float beatBandShare = Clamp01(
        (features.lowNovelty + 0.35F * features.midNovelty) / noveltySum);
    const float energySupport = std::sqrt(Clamp01(features.lowBandRatio));
    output.lowFrequencySupport = Clamp01(
        0.65F * energySupport + 0.35F * beatBandShare);

    const float previousSlowRhythm = slowRhythmNovelty_;
    const float previousSlowBroadband = slowBroadbandNovelty_;
    const float previousSlowTactile = slowTactileMeanAbsolute_;
    slowRhythmNovelty_ +=
        kAverageAlpha * (rhythmNovelty - slowRhythmNovelty_);
    slowBroadbandNovelty_ +=
        kAverageAlpha * (features.novelty - slowBroadbandNovelty_);
    slowTactileMeanAbsolute_ += kAverageAlpha *
        (features.tactileMeanAbsolute - slowTactileMeanAbsolute_);

    const float spectralRise = Clamp01(
        (rhythmNovelty - previousSlowRhythm) /
        (1.50F * previousSlowRhythm + 0.0015F));
    const float broadbandRise = Clamp01(
        (features.novelty - previousSlowBroadband) /
        (3.0F * previousSlowBroadband + 0.003F));
    const float tactileRise = Clamp01(
        (features.tactileMeanAbsolute - previousSlowTactile) /
        (0.50F * previousSlowTactile + 0.001F));

    const float support = output.lowFrequencySupport;
    const float spectralActivation =
        spectralRise * (0.15F + 0.85F * support);
    const float tactileActivation =
        tactileRise * (0.25F + 0.75F * support);
    const float broadbandAssist =
        broadbandRise * (0.18F + 0.20F * support);
    const float onsetAssist = onset.detected
        ? 0.10F + support * (0.55F + 0.25F * Clamp01(onset.amplitude))
        : 0.0F;

    output.activation = Clamp01(std::max(
        std::max(spectralActivation, tactileActivation),
        std::max(broadbandAssist, onsetAssist)));
    output.evidenceEvent = output.audible && support >= 0.22F &&
        (onset.detected || spectralRise >= 0.35F || tactileRise >= 0.35F) &&
        output.activation >= 0.20F;

    if (framesSeen_ < warmupHops_) {
        output.activation = 0.0F;
        output.evidenceEvent = false;
    }
    if (framesSeen_ < std::numeric_limits<uint32_t>::max()) ++framesSeen_;
    if (!output.audible) {
        output.activation = 0.0F;
        output.evidenceEvent = false;
    }
    return output;
}

void RhythmActivationExtractor::Reset() noexcept {
    framesSeen_ = 0U;
    slowRhythmNovelty_ = 0.0F;
    slowBroadbandNovelty_ = 0.0F;
    slowTactileMeanAbsolute_ = 0.0F;
}

} // namespace moonlight::haptics::core
