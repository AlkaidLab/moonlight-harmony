// SPDX-License-Identifier: Apache-2.0

/*
 * Copyright (C) 2020 The Android Open Source Project
 * Copyright (C) 2026 Moonlight Audio Haptics contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef MOONLIGHT_HAPTICS_DSP_AOSP_HAPTIC_ENVELOPE_H
#define MOONLIGHT_HAPTICS_DSP_AOSP_HAPTIC_ENVELOPE_H

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace moonlight::haptics::dsp {

/** Five-millisecond cadence summary over a causal 40 ms actuator window. */
struct TactileEnvelopeFrame {
    float rms = 0.0F;
    float peak = 0.0F;
    float meanAbsolute = 0.0F;
};

/**
 * Portable causal form of Android's Apache-2.0 HapticGenerator DSP chain.
 *
 * Android's implementation produces an audio-rate haptic channel. The portable
 * SDK instead summarizes that waveform at its analysis hop so platform adapters
 * can render perceptual intent without owning PCM or Audio HAL resources.
 */
class AospHapticEnvelope {
public:
    AospHapticEnvelope(uint32_t sampleRate,
                       uint32_t channelCount,
                       uint32_t hopSize);

    bool PushInterleavedSample(const int16_t* samples,
                               TactileEnvelopeFrame& output) noexcept;
    void Reset() noexcept;

private:
    using Coefficients = std::array<float, 5>;
    static constexpr std::size_t kEnvelopeWindowHops = 8U;

    struct Biquad {
        explicit Biquad(const Coefficients& newCoefficients) noexcept
            : coefficients(newCoefficients) {}

        float Process(float input) noexcept;
        void Reset() noexcept;

        Coefficients coefficients{};
        float input1 = 0.0F;
        float input2 = 0.0F;
        float output1 = 0.0F;
        float output2 = 0.0F;
    };

    struct ChannelState {
        explicit ChannelState(float sampleRate);

        float Process(float input) noexcept;
        void Reset() noexcept;

        Biquad highPass50;
        Biquad lowPass9000;
        Biquad highPass60;
        Biquad lowPass700;
        Biquad lowPass400;
        Biquad lowPass500;
        Biquad resonantBandPass;
        Biquad slowEnvelope;
        Biquad resonantBandStop;
        Biquad distortionLowPass;
    };

    uint32_t channelCount_ = 0;
    uint32_t hopSize_ = 0;
    uint32_t samplesInHop_ = 0;
    double hopSumSquares_ = 0.0;
    double hopSumAbsolute_ = 0.0;
    float hopPeak_ = 0.0F;
    std::array<double, kEnvelopeWindowHops> windowMeanSquares_{};
    std::array<double, kEnvelopeWindowHops> windowMeanAbsolute_{};
    std::array<float, kEnvelopeWindowHops> windowPeaks_{};
    std::size_t windowPosition_ = 0U;
    std::size_t windowCount_ = 0U;
    double windowSumMeanSquares_ = 0.0;
    double windowSumMeanAbsolute_ = 0.0;
    std::vector<ChannelState> channels_;
};

} // namespace moonlight::haptics::dsp

#endif // MOONLIGHT_HAPTICS_DSP_AOSP_HAPTIC_ENVELOPE_H
