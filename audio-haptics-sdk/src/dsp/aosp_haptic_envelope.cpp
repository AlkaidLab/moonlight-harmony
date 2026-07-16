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
 *
 * Adapted from AOSP frameworks/av media/libeffects/hapticgenerator/Processors.cpp
 * and EffectHapticGenerator.cpp. See THIRD_PARTY_NOTICES.md for source details.
 */

#include "dsp/aosp_haptic_envelope.h"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <utility>

namespace moonlight::haptics::dsp {

namespace {

using Coefficients = std::array<float, 5>;

constexpr float kPi = 3.14159265358979323846F;
constexpr float kResonantFrequency = 150.0F;
constexpr float kBandPassQ = 1.0F;
constexpr float kBandStopZeroQ = 8.0F;
constexpr float kBandStopPoleQ = 4.0F;
constexpr float kSlowEnvelopeNormalizationPower = -0.8F;
constexpr float kSlowEnvelopeOffset = 0.01F;
constexpr float kDistortionInputGain = 0.3F;
constexpr float kDistortionCubeThreshold = 0.1F;
constexpr float kDistortionOutputGain = 1.5F;

float SafeCorner(float frequency, float sampleRate) noexcept {
    return std::max(1.0F, std::min(frequency, sampleRate * 0.45F));
}

float RealPole(float cornerFrequency, float sampleRate) noexcept {
    return std::exp(-2.0F * kPi * SafeCorner(cornerFrequency, sampleRate) /
                    sampleRate);
}

std::pair<float, float> ComplexPole(float frequency,
                                    float q,
                                    float sampleRate) noexcept {
    const float safeFrequency = SafeCorner(frequency, sampleRate);
    const float safeQ = std::max(q, 0.1F);
    const float imaginary = 2.0F * kPi * safeFrequency;
    const float radius = std::exp(-imaginary / (2.0F * safeQ * sampleRate));
    const float phase = imaginary / sampleRate;
    return {radius * std::cos(phase), radius * std::sin(phase)};
}

Coefficients CascadeFirstOrder(const Coefficients& first,
                               const Coefficients& second) noexcept {
    return {
        first[0] * second[0],
        first[0] * second[1] + first[1] * second[0],
        first[1] * second[1],
        first[3] + second[3],
        first[3] * second[3]
    };
}

Coefficients LowPass(float cornerFrequency, float sampleRate) noexcept {
    const float pole = RealPole(cornerFrequency, sampleRate);
    const float feedForward = 0.5F * (1.0F - pole);
    return {feedForward, feedForward, 0.0F, -pole, 0.0F};
}

Coefficients LowPass2(float cornerFrequency, float sampleRate) noexcept {
    const Coefficients firstOrder = LowPass(cornerFrequency, sampleRate);
    return CascadeFirstOrder(firstOrder, firstOrder);
}

Coefficients HighPass2(float cornerFrequency, float sampleRate) noexcept {
    const float pole = RealPole(cornerFrequency, sampleRate);
    const float feedForward = 0.5F * (1.0F + pole);
    const Coefficients firstOrder = {
        feedForward, -feedForward, 0.0F, -pole, 0.0F
    };
    return CascadeFirstOrder(firstOrder, firstOrder);
}

Coefficients BandPass(float frequency, float q, float sampleRate) noexcept {
    const auto pole = ComplexPole(frequency, q, sampleRate);
    return {1.0F, -1.0F, 0.0F,
            -2.0F * pole.first,
            pole.first * pole.first + pole.second * pole.second};
}

Coefficients BandStop(float frequency,
                      float zeroQ,
                      float poleQ,
                      float sampleRate) noexcept {
    const auto zero = ComplexPole(frequency, zeroQ, sampleRate);
    const auto pole = ComplexPole(frequency, poleQ, sampleRate);
    const float zero1 = -2.0F * zero.first;
    const float zero2 = zero.first * zero.first + zero.second * zero.second;
    const float pole1 = -2.0F * pole.first;
    const float pole2 = pole.first * pole.first + pole.second * pole.second;
    const float normalization =
        (1.0F + pole1 + pole2) / (1.0F + zero1 + zero2);
    return {normalization, zero1 * normalization, zero2 * normalization,
            pole1, pole2};
}

} // namespace

float AospHapticEnvelope::Biquad::Process(float input) noexcept {
    const float output = coefficients[0] * input +
                         coefficients[1] * input1 +
                         coefficients[2] * input2 -
                         coefficients[3] * output1 -
                         coefficients[4] * output2;
    input2 = input1;
    input1 = input;
    output2 = output1;
    output1 = output;
    return output;
}

void AospHapticEnvelope::Biquad::Reset() noexcept {
    input1 = 0.0F;
    input2 = 0.0F;
    output1 = 0.0F;
    output2 = 0.0F;
}

AospHapticEnvelope::ChannelState::ChannelState(float sampleRate)
    : highPass50(HighPass2(50.0F, sampleRate)),
      lowPass9000(LowPass2(9000.0F, sampleRate)),
      highPass60(HighPass2(60.0F, sampleRate)),
      lowPass700(LowPass2(700.0F, sampleRate)),
      lowPass400(LowPass2(400.0F, sampleRate)),
      lowPass500(LowPass2(500.0F, sampleRate)),
      resonantBandPass(BandPass(kResonantFrequency, kBandPassQ, sampleRate)),
      slowEnvelope(LowPass(5.0F, sampleRate)),
      resonantBandStop(BandStop(kResonantFrequency,
                                kBandStopZeroQ,
                                kBandStopPoleQ,
                                sampleRate)),
      distortionLowPass(LowPass2(300.0F, sampleRate)) {}

float AospHapticEnvelope::ChannelState::Process(float input) noexcept {
    float value = highPass50.Process(input);
    value = lowPass9000.Process(value);
    value = std::max(value, 0.0F); // AOSP Ramp: half-wave rectifier.
    value = highPass60.Process(value);
    value = lowPass700.Process(value);
    value = lowPass400.Process(value);
    value = lowPass500.Process(value);
    value = resonantBandPass.Process(value);

    const float envelope = std::max(
        slowEnvelope.Process(std::abs(value)) + kSlowEnvelopeOffset,
        1.0e-6F);
    value *= std::pow(envelope, kSlowEnvelopeNormalizationPower);
    value = resonantBandStop.Process(value);

    const float driven = kDistortionInputGain * value;
    const float square = driven * driven;
    const float cored = driven * square / (kDistortionCubeThreshold + square);
    value = distortionLowPass.Process(cored);
    return kDistortionOutputGain * value / (1.0F + std::abs(value));
}

void AospHapticEnvelope::ChannelState::Reset() noexcept {
    highPass50.Reset();
    lowPass9000.Reset();
    highPass60.Reset();
    lowPass700.Reset();
    lowPass400.Reset();
    lowPass500.Reset();
    resonantBandPass.Reset();
    slowEnvelope.Reset();
    resonantBandStop.Reset();
    distortionLowPass.Reset();
}

AospHapticEnvelope::AospHapticEnvelope(uint32_t sampleRate,
                                       uint32_t channelCount,
                                       uint32_t hopSize)
    : channelCount_(channelCount), hopSize_(hopSize) {
    if (sampleRate == 0U || channelCount == 0U || hopSize == 0U) {
        throw std::invalid_argument("invalid haptic envelope format");
    }
    channels_.reserve(channelCount_);
    for (uint32_t channel = 0; channel < channelCount_; ++channel) {
        channels_.emplace_back(static_cast<float>(sampleRate));
    }
}

bool AospHapticEnvelope::PushInterleavedSample(
        const int16_t* samples,
        TactileEnvelopeFrame& output) noexcept {
    float frameMagnitude = 0.0F;
    for (uint32_t channel = 0; channel < channelCount_; ++channel) {
        const float input = static_cast<float>(samples[channel]) / 32768.0F;
        frameMagnitude = std::max(
            frameMagnitude,
            std::abs(channels_[channel].Process(input)));
    }

    const double magnitude = static_cast<double>(frameMagnitude);
    hopSumSquares_ += magnitude * magnitude;
    hopSumAbsolute_ += magnitude;
    hopPeak_ = std::max(hopPeak_, frameMagnitude);
    ++samplesInHop_;
    if (samplesInHop_ < hopSize_) return false;

    const double sampleCount = static_cast<double>(samplesInHop_);
    const double hopMeanSquare = hopSumSquares_ / sampleCount;
    const double hopMeanAbsolute = hopSumAbsolute_ / sampleCount;
    if (windowCount_ == kEnvelopeWindowHops) {
        windowSumMeanSquares_ -= windowMeanSquares_[windowPosition_];
        windowSumMeanAbsolute_ -= windowMeanAbsolute_[windowPosition_];
    } else {
        ++windowCount_;
    }
    windowMeanSquares_[windowPosition_] = hopMeanSquare;
    windowMeanAbsolute_[windowPosition_] = hopMeanAbsolute;
    windowPeaks_[windowPosition_] = hopPeak_;
    windowSumMeanSquares_ += hopMeanSquare;
    windowSumMeanAbsolute_ += hopMeanAbsolute;
    windowPosition_ = (windowPosition_ + 1U) % kEnvelopeWindowHops;

    const double windowCount = static_cast<double>(windowCount_);
    output.rms = static_cast<float>(
        std::sqrt(std::max(0.0, windowSumMeanSquares_ / windowCount)));
    output.meanAbsolute = static_cast<float>(
        std::max(0.0, windowSumMeanAbsolute_ / windowCount));
    output.peak = *std::max_element(
        windowPeaks_.begin(), windowPeaks_.begin() + windowCount_);
    samplesInHop_ = 0U;
    hopSumSquares_ = 0.0;
    hopSumAbsolute_ = 0.0;
    hopPeak_ = 0.0F;
    return true;
}

void AospHapticEnvelope::Reset() noexcept {
    for (ChannelState& channel : channels_) channel.Reset();
    samplesInHop_ = 0U;
    hopSumSquares_ = 0.0;
    hopSumAbsolute_ = 0.0;
    hopPeak_ = 0.0F;
    windowMeanSquares_.fill(0.0);
    windowMeanAbsolute_.fill(0.0);
    windowPeaks_.fill(0.0F);
    windowPosition_ = 0U;
    windowCount_ = 0U;
    windowSumMeanSquares_ = 0.0;
    windowSumMeanAbsolute_ = 0.0;
}

} // namespace moonlight::haptics::dsp
