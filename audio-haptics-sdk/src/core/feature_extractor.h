// SPDX-License-Identifier: Apache-2.0

#ifndef MOONLIGHT_HAPTICS_CORE_FEATURE_EXTRACTOR_H
#define MOONLIGHT_HAPTICS_CORE_FEATURE_EXTRACTOR_H

#include "dsp/real_fft.h"

#include <cstdint>
#include <vector>

namespace moonlight::haptics::core {

struct FeatureFrame {
    float novelty = 0.0F;
    float lowNovelty = 0.0F;
    float midNovelty = 0.0F;
    float highNovelty = 0.0F;
    // Project-written causal approximations of median-filter HPSS and
    // SuperFlux. MUSIC keeps using the legacy novelty fields above; GAME can
    // use these fields to distinguish short physical events from stable
    // orchestration and vocal vibrato.
    float percussiveNovelty = 0.0F;
    float percussiveSalience = 0.0F;
    float harmonicSalience = 0.0F;
    float percussiveLowBandRatio = 0.0F;
    float rms = 0.0F;
    float peak = 0.0F;
    float lowBandRatio = 0.0F;
    float stereoPan = 0.0F;
    float tactileRms = 0.0F;
    float tactilePeak = 0.0F;
    float tactileMeanAbsolute = 0.0F;
    uint64_t streamEndSample = 0;
    uint32_t analysisIndex = 0;
};

class FeatureExtractor {
public:
    FeatureExtractor(uint32_t sampleRate, uint32_t channelCount);

    uint32_t HopSize() const noexcept { return hopSize_; }
    uint32_t FftSize() const noexcept { return fftSize_; }

    bool PushInterleavedSample(const int16_t* samples, FeatureFrame& output) noexcept;
    void Reset() noexcept;

private:
    void Analyze(FeatureFrame& output) noexcept;

    uint32_t sampleRate_ = 0;
    uint32_t channelCount_ = 0;
    uint32_t hopSize_ = 0;
    uint32_t fftSize_ = 0;
    uint32_t spectrumSize_ = 0;
    uint32_t writeIndex_ = 0;
    uint32_t samplesInHop_ = 0;
    uint32_t analysisIndex_ = 0;
    uint64_t totalSamples_ = 0;

    double hopSumSquares_ = 0.0;
    double hopLeftSquares_ = 0.0;
    double hopRightSquares_ = 0.0;
    float hopPeak_ = 0.0F;
    float pcenSmoothingAlpha_ = 0.0F;
    float windowMagnitudeScale_ = 0.0F;

    dsp::RealFft fft_;
    std::vector<float> history_;
    std::vector<float> window_;
    std::vector<float> fftReal_;
    std::vector<float> fftImaginary_;
    std::vector<float> powerSpectrum_;
    std::vector<float> magnitudeSpectrum_;
    std::vector<float> pcenSmoother_;
    std::vector<float> currentPcen_;
    std::vector<float> previousPcen_;
    std::vector<float> magnitudeHistory_;
    uint32_t magnitudeHistoryPosition_ = 0U;
};

} // namespace moonlight::haptics::core

#endif // MOONLIGHT_HAPTICS_CORE_FEATURE_EXTRACTOR_H
