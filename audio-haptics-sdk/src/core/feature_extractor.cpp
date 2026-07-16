// SPDX-License-Identifier: Apache-2.0

#include "core/feature_extractor.h"

#include "core/dsp_parameters.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>

namespace moonlight::haptics::core {

namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;
namespace params = parameters;

uint32_t NextPowerOfTwo(uint32_t value) {
    uint32_t result = 1U;
    while (result < value && result < params::kMaximumFftSize) result <<= 1U;
    if (result < value) throw std::invalid_argument("sample rate requires oversized FFT");
    return result;
}

float Clamp(float value, float minimum, float maximum) noexcept {
    return std::max(minimum, std::min(maximum, value));
}

template <std::size_t Capacity>
float Median(std::array<float, Capacity>& values,
             std::size_t count) noexcept {
    if (count == 0U) return 0.0F;
    const auto middle = values.begin() +
        static_cast<std::ptrdiff_t>(count / 2U);
    std::nth_element(values.begin(), middle,
                     values.begin() + static_cast<std::ptrdiff_t>(count));
    return *middle;
}

} // namespace

FeatureExtractor::FeatureExtractor(uint32_t sampleRate, uint32_t channelCount)
    : sampleRate_(sampleRate),
      channelCount_(channelCount),
      hopSize_((sampleRate + params::kAnalysisHopsPerSecond / 2U) /
               params::kAnalysisHopsPerSecond),
      fftSize_(NextPowerOfTwo(hopSize_ * params::kWindowHops)),
      spectrumSize_(fftSize_ / 2U + 1U),
      pcenSmoothingAlpha_(
          static_cast<float>(1.0 - std::exp(
              -static_cast<double>(hopSize_) /
              (static_cast<double>(sampleRate_) *
               static_cast<double>(params::kPcenTimeConstantSeconds))))),
      fft_(fftSize_),
      history_(static_cast<size_t>(channelCount_) * fftSize_, 0.0F),
      window_(fftSize_, 0.0F),
      fftReal_(fftSize_, 0.0F),
      fftImaginary_(fftSize_, 0.0F),
      powerSpectrum_(spectrumSize_, 0.0F),
      magnitudeSpectrum_(spectrumSize_, 0.0F),
      pcenSmoother_(spectrumSize_, 1.0e-6F),
      currentPcen_(spectrumSize_, 0.0F),
      previousPcen_(spectrumSize_, 0.0F),
      magnitudeHistory_(
          static_cast<size_t>(spectrumSize_) *
              params::kPercussiveTemporalFrames,
          0.0F) {
    if (sampleRate_ == 0 || channelCount_ == 0 || hopSize_ == 0) {
        throw std::invalid_argument("invalid feature extractor format");
    }
    double windowSum = 0.0;
    for (uint32_t index = 0; index < fftSize_; ++index) {
        const double phase = 2.0 * kPi * static_cast<double>(index) /
                             static_cast<double>(fftSize_ - 1U);
        window_[index] = static_cast<float>(0.5 - 0.5 * std::cos(phase));
        windowSum += window_[index];
    }
    windowMagnitudeScale_ = static_cast<float>(2.0 / windowSum);
}

bool FeatureExtractor::PushInterleavedSample(const int16_t* samples,
                                             FeatureFrame& output) noexcept {
    for (uint32_t channel = 0; channel < channelCount_; ++channel) {
        const float value = static_cast<float>(samples[channel]) / 32768.0F;
        history_[static_cast<size_t>(channel) * fftSize_ + writeIndex_] = value;
        const double square = static_cast<double>(value) * value;
        hopSumSquares_ += square;
        hopPeak_ = std::max(hopPeak_, std::abs(value));
        if (channel == 0U) hopLeftSquares_ += square;
        if (channel == 1U) hopRightSquares_ += square;
    }
    if (channelCount_ == 1U) hopRightSquares_ = hopLeftSquares_;

    writeIndex_ = (writeIndex_ + 1U) % fftSize_;
    ++samplesInHop_;
    ++totalSamples_;
    if (samplesInHop_ < hopSize_) return false;

    Analyze(output);
    samplesInHop_ = 0;
    hopSumSquares_ = 0.0;
    hopLeftSquares_ = 0.0;
    hopRightSquares_ = 0.0;
    hopPeak_ = 0.0F;
    return true;
}

void FeatureExtractor::Analyze(FeatureFrame& output) noexcept {
    std::fill(powerSpectrum_.begin(), powerSpectrum_.end(), 0.0F);
    for (uint32_t channel = 0; channel < channelCount_; ++channel) {
        const size_t channelOffset = static_cast<size_t>(channel) * fftSize_;
        for (uint32_t index = 0; index < fftSize_; ++index) {
            const uint32_t historyIndex = (writeIndex_ + index) % fftSize_;
            fftReal_[index] = history_[channelOffset + historyIndex] * window_[index];
            fftImaginary_[index] = 0.0F;
        }
        fft_.Transform(fftReal_.data(), fftImaginary_.data());
        for (uint32_t bin = 0; bin < spectrumSize_; ++bin) {
            powerSpectrum_[bin] +=
                fftReal_[bin] * fftReal_[bin] +
                fftImaginary_[bin] * fftImaginary_[bin];
        }
    }

    const float channelScale = 1.0F / static_cast<float>(channelCount_);
    for (uint32_t bin = 0; bin < spectrumSize_; ++bin) {
        const float magnitude =
            std::sqrt(powerSpectrum_[bin] * channelScale) * windowMagnitudeScale_;
        magnitudeSpectrum_[bin] = magnitude;
        float& smoother = pcenSmoother_[bin];
        if (analysisIndex_ == 0U) {
            smoother = std::max(magnitude, 1.0e-6F);
        } else {
            smoother += pcenSmoothingAlpha_ * (magnitude - smoother);
        }

        const float normalized = magnitude /
            std::pow(1.0e-6F + smoother, params::kPcenExponent);
        currentPcen_[bin] =
            std::sqrt(normalized + params::kPcenOffset) -
            std::sqrt(params::kPcenOffset);
        magnitudeHistory_[
            static_cast<size_t>(magnitudeHistoryPosition_) * spectrumSize_ + bin] =
            magnitude;
    }

    float lowFlux = 0.0F;
    float midFlux = 0.0F;
    float highFlux = 0.0F;
    float percussiveLowFlux = 0.0F;
    float percussiveMidFlux = 0.0F;
    float percussiveHighFlux = 0.0F;
    float lowEnergy = 0.0F;
    float totalEnergy = 0.0F;
    float percussiveLowEnergy = 0.0F;
    float percussiveEnergy = 0.0F;
    float harmonicEnergy = 0.0F;
    uint32_t lowBins = 0;
    uint32_t midBins = 0;
    uint32_t highBins = 0;

    for (uint32_t bin = 0; bin < spectrumSize_; ++bin) {
        const float magnitude = magnitudeSpectrum_[bin];
        const float difference = std::max(
            0.0F, currentPcen_[bin] - previousPcen_[bin]);

        const uint32_t superStart = bin > params::kSuperFluxFrequencyRadius
            ? bin - params::kSuperFluxFrequencyRadius
            : 0U;
        const uint32_t superEnd = std::min(
            spectrumSize_ - 1U,
            bin + params::kSuperFluxFrequencyRadius);
        float previousMaximum = 0.0F;
        for (uint32_t neighbor = superStart; neighbor <= superEnd; ++neighbor) {
            previousMaximum = std::max(
                previousMaximum, previousPcen_[neighbor]);
        }
        const float superDifference = std::max(
            0.0F, currentPcen_[bin] - previousMaximum);

        std::array<float, params::kPercussiveTemporalFrames> temporalValues{};
        for (uint32_t frame = 0U;
             frame < params::kPercussiveTemporalFrames;
             ++frame) {
            temporalValues[frame] = magnitudeHistory_[
                static_cast<size_t>(frame) * spectrumSize_ + bin];
        }
        const float harmonicEstimate = Median(
            temporalValues,
            static_cast<std::size_t>(params::kPercussiveTemporalFrames));

        constexpr std::size_t kFrequencyCapacity =
            static_cast<std::size_t>(
                params::kPercussiveFrequencyRadius * 2U + 1U);
        std::array<float, kFrequencyCapacity> frequencyValues{};
        const uint32_t frequencyStart =
            bin > params::kPercussiveFrequencyRadius
                ? bin - params::kPercussiveFrequencyRadius
                : 0U;
        const uint32_t frequencyEnd = std::min(
            spectrumSize_ - 1U,
            bin + params::kPercussiveFrequencyRadius);
        std::size_t frequencyCount = 0U;
        for (uint32_t neighbor = frequencyStart;
             neighbor <= frequencyEnd;
             ++neighbor) {
            frequencyValues[frequencyCount++] = magnitudeSpectrum_[neighbor];
        }
        const float percussiveEstimate = Median(
            frequencyValues, frequencyCount);
        const float harmonicSquare = harmonicEstimate * harmonicEstimate;
        const float percussiveSquare = percussiveEstimate * percussiveEstimate;
        const float maskDenominator = harmonicSquare + percussiveSquare;
        const float percussiveMask = maskDenominator <= 1.0e-18F
            ? 0.0F
            : percussiveSquare / maskDenominator;
        const float binEnergy = magnitude * magnitude;
        const float percussiveBinEnergy = binEnergy * percussiveMask;
        const float percussiveDifference = superDifference * percussiveMask;

        const float frequency = static_cast<float>(bin) *
                                static_cast<float>(sampleRate_) /
                                static_cast<float>(fftSize_);
        if (frequency >= params::kLowBandMinimumHz &&
            frequency < params::kLowBandMaximumHz) {
            lowFlux += difference;
            percussiveLowFlux += percussiveDifference;
            lowEnergy += binEnergy;
            totalEnergy += binEnergy;
            percussiveLowEnergy += percussiveBinEnergy;
            percussiveEnergy += percussiveBinEnergy;
            harmonicEnergy += binEnergy - percussiveBinEnergy;
            ++lowBins;
        } else if (frequency < params::kMidBandMaximumHz &&
                   frequency >= params::kLowBandMaximumHz) {
            midFlux += difference;
            percussiveMidFlux += percussiveDifference;
            totalEnergy += binEnergy;
            percussiveEnergy += percussiveBinEnergy;
            harmonicEnergy += binEnergy - percussiveBinEnergy;
            ++midBins;
        } else if (frequency < params::kHighBandMaximumHz &&
                   frequency >= params::kMidBandMaximumHz) {
            highFlux += difference;
            percussiveHighFlux += percussiveDifference;
            totalEnergy += binEnergy;
            percussiveEnergy += percussiveBinEnergy;
            harmonicEnergy += binEnergy - percussiveBinEnergy;
            ++highBins;
        }
    }

    magnitudeHistoryPosition_ =
        (magnitudeHistoryPosition_ + 1U) % params::kPercussiveTemporalFrames;
    std::copy(currentPcen_.begin(), currentPcen_.end(), previousPcen_.begin());

    output.lowNovelty = lowBins == 0U ? 0.0F : lowFlux / static_cast<float>(lowBins);
    output.midNovelty = midBins == 0U ? 0.0F : midFlux / static_cast<float>(midBins);
    output.highNovelty = highBins == 0U ? 0.0F : highFlux / static_cast<float>(highBins);
    output.novelty = params::kLowNoveltyWeight * output.lowNovelty +
                     params::kMidNoveltyWeight * output.midNovelty +
                     params::kHighNoveltyWeight * output.highNovelty;
    const float percussiveLowNovelty = lowBins == 0U
        ? 0.0F
        : percussiveLowFlux / static_cast<float>(lowBins);
    const float percussiveMidNovelty = midBins == 0U
        ? 0.0F
        : percussiveMidFlux / static_cast<float>(midBins);
    const float percussiveHighNovelty = highBins == 0U
        ? 0.0F
        : percussiveHighFlux / static_cast<float>(highBins);
    output.percussiveNovelty =
        params::kLowNoveltyWeight * percussiveLowNovelty +
        params::kMidNoveltyWeight * percussiveMidNovelty +
        params::kHighNoveltyWeight * percussiveHighNovelty;
    const float separatedEnergy = percussiveEnergy + harmonicEnergy;
    output.percussiveSalience = separatedEnergy <= 1.0e-12F
        ? 0.0F
        : Clamp(percussiveEnergy / separatedEnergy, 0.0F, 1.0F);
    output.harmonicSalience = separatedEnergy <= 1.0e-12F
        ? 0.0F
        : Clamp(harmonicEnergy / separatedEnergy, 0.0F, 1.0F);
    output.percussiveLowBandRatio = percussiveEnergy <= 1.0e-12F
        ? 0.0F
        : Clamp(percussiveLowEnergy / percussiveEnergy, 0.0F, 1.0F);
    output.rms = static_cast<float>(std::sqrt(
        hopSumSquares_ /
        static_cast<double>(hopSize_ * channelCount_)));
    output.peak = hopPeak_;
    output.lowBandRatio = totalEnergy <= 1.0e-12F
        ? 0.0F
        : Clamp(lowEnergy / totalEnergy, 0.0F, 1.0F);
    const double stereoSum = hopLeftSquares_ + hopRightSquares_;
    output.stereoPan = stereoSum <= 1.0e-12
        ? 0.0F
        : Clamp(static_cast<float>(
              (hopRightSquares_ - hopLeftSquares_) / stereoSum), -1.0F, 1.0F);
    output.streamEndSample = totalSamples_;
    output.analysisIndex = analysisIndex_;
    ++analysisIndex_;
}

void FeatureExtractor::Reset() noexcept {
    std::fill(history_.begin(), history_.end(), 0.0F);
    std::fill(powerSpectrum_.begin(), powerSpectrum_.end(), 0.0F);
    std::fill(magnitudeSpectrum_.begin(), magnitudeSpectrum_.end(), 0.0F);
    std::fill(pcenSmoother_.begin(), pcenSmoother_.end(), 1.0e-6F);
    std::fill(currentPcen_.begin(), currentPcen_.end(), 0.0F);
    std::fill(previousPcen_.begin(), previousPcen_.end(), 0.0F);
    std::fill(magnitudeHistory_.begin(), magnitudeHistory_.end(), 0.0F);
    magnitudeHistoryPosition_ = 0U;
    writeIndex_ = 0;
    samplesInHop_ = 0;
    analysisIndex_ = 0;
    totalSamples_ = 0;
    hopSumSquares_ = 0.0;
    hopLeftSquares_ = 0.0;
    hopRightSquares_ = 0.0;
    hopPeak_ = 0.0F;
}

} // namespace moonlight::haptics::core
