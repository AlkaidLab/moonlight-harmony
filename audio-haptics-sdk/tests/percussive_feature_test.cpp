// SPDX-License-Identifier: Apache-2.0

#include "core/feature_extractor.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>

namespace {

constexpr uint32_t kSampleRate = 48000U;
constexpr double kPi = 3.14159265358979323846;

int16_t ToPcm16(float value) {
    const float clamped = std::max(-1.0F, std::min(1.0F, value));
    return static_cast<int16_t>(std::lround(clamped * 32767.0F));
}

void AssertSteadyToneIsHarmonic() {
    moonlight::haptics::core::FeatureExtractor extractor(kSampleRate, 1U);
    double percussiveSum = 0.0;
    double harmonicSum = 0.0;
    uint32_t frames = 0U;
    for (uint32_t sampleIndex = 0U; sampleIndex < kSampleRate; ++sampleIndex) {
        const double time = static_cast<double>(sampleIndex) / kSampleRate;
        const int16_t sample = ToPcm16(
            0.30F * static_cast<float>(std::sin(2.0 * kPi * 440.0 * time)));
        moonlight::haptics::core::FeatureFrame frame;
        if (!extractor.PushInterleavedSample(&sample, frame) ||
            sampleIndex < kSampleRate / 4U) {
            continue;
        }
        percussiveSum += frame.percussiveSalience;
        harmonicSum += frame.harmonicSalience;
        ++frames;
    }
    assert(frames > 0U);
    assert(harmonicSum > percussiveSum * 1.8);
}

void AssertBroadbandAttackIsPercussiveAndCausal() {
    moonlight::haptics::core::FeatureExtractor extractor(kSampleRate, 1U);
    constexpr uint32_t kAttackSample = kSampleRate / 5U;
    constexpr uint32_t kAttackLength = kSampleRate / 100U;
    uint32_t randomState = 0x12345678U;
    float maximumSalience = 0.0F;
    float maximumNovelty = 0.0F;
    uint64_t firstPercussiveEndSample = 0U;
    for (uint32_t sampleIndex = 0U; sampleIndex < kSampleRate / 2U;
         ++sampleIndex) {
        int16_t sample = 0;
        if (sampleIndex >= kAttackSample &&
            sampleIndex < kAttackSample + kAttackLength) {
            randomState ^= randomState << 13U;
            randomState ^= randomState >> 17U;
            randomState ^= randomState << 5U;
            const float noise = static_cast<float>(randomState & 0xffffU) /
                                    32767.5F -
                                1.0F;
            const float envelope = std::exp(
                -static_cast<float>(sampleIndex - kAttackSample) /
                (0.0025F * static_cast<float>(kSampleRate)));
            sample = ToPcm16(0.80F * envelope * noise);
        }
        moonlight::haptics::core::FeatureFrame frame;
        if (!extractor.PushInterleavedSample(&sample, frame)) continue;
        maximumSalience = std::max(maximumSalience, frame.percussiveSalience);
        maximumNovelty = std::max(maximumNovelty, frame.percussiveNovelty);
        if (firstPercussiveEndSample == 0U &&
            frame.percussiveNovelty > 0.002F) {
            firstPercussiveEndSample = frame.streamEndSample;
        }
    }
    assert(maximumSalience > 0.65F);
    assert(maximumNovelty > 0.002F);
    assert(firstPercussiveEndSample >= kAttackSample);
    assert(firstPercussiveEndSample - kAttackSample <= extractor.HopSize());
}

void AssertVibratoDoesNotBecomePercussiveNovelty() {
    moonlight::haptics::core::FeatureExtractor extractor(kSampleRate, 1U);
    double regularNovelty = 0.0;
    double percussiveNovelty = 0.0;
    double phase = 0.0;
    for (uint32_t sampleIndex = 0U; sampleIndex < kSampleRate * 2U;
         ++sampleIndex) {
        const double time = static_cast<double>(sampleIndex) / kSampleRate;
        const double frequency = 440.0 + 12.0 *
            std::sin(2.0 * kPi * 5.5 * time);
        phase += 2.0 * kPi * frequency / kSampleRate;
        const int16_t sample = ToPcm16(
            0.30F * static_cast<float>(std::sin(phase)));
        moonlight::haptics::core::FeatureFrame frame;
        if (!extractor.PushInterleavedSample(&sample, frame) ||
            sampleIndex < kSampleRate / 2U) {
            continue;
        }
        regularNovelty += frame.novelty;
        percussiveNovelty += frame.percussiveNovelty;
    }
    assert(regularNovelty > 0.0);
    assert(percussiveNovelty < regularNovelty * 0.55);
}

} // namespace

int main() {
    AssertSteadyToneIsHarmonic();
    AssertBroadbandAttackIsPercussiveAndCausal();
    AssertVibratoDoesNotBecomePercussiveNovelty();
    return 0;
}
