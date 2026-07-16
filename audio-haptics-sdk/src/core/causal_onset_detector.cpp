// SPDX-License-Identifier: Apache-2.0

#include "core/causal_onset_detector.h"

#include "core/dsp_parameters.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace moonlight::haptics::core {

namespace {

namespace params = parameters;

float Clamp01(float value) noexcept {
    return std::max(0.0F, std::min(1.0F, value));
}

float Lerp(float start, float end, float amount) noexcept {
    return start + (end - start) * amount;
}

} // namespace

CausalOnsetDetector::CausalOnsetDetector(uint32_t sampleRate, uint32_t hopSize)
    : refractoryFrames_(std::max(
          1U,
          static_cast<uint32_t>(std::ceil(
              static_cast<double>(params::kRefractorySeconds) *
              static_cast<double>(sampleRate) /
              static_cast<double>(hopSize))))),
      sensitiveRefractoryFrames_(std::max(
          1U,
          static_cast<uint32_t>(std::ceil(
              static_cast<double>(params::kSensitiveRefractorySeconds) *
              static_cast<double>(sampleRate) /
              static_cast<double>(hopSize))))) {
    Reset();
}

OnsetResult CausalOnsetDetector::Process(const FeatureFrame& features,
                                         float sensitivity) noexcept {
    OnsetResult result;
    const float previousSlowRms = slowRms_;
    const float previousSlowTactileMeanAbsolute = slowTactileMeanAbsolute_;
    const float rmsAlpha = params::kSlowRmsAlpha;
    slowRms_ += rmsAlpha * (features.rms - slowRms_);
    slowTactileMeanAbsolute_ += params::kTactileSlowAlpha *
        (features.tactileMeanAbsolute - slowTactileMeanAbsolute_);

    const float median = MedianHistory();
    const float mad = MedianAbsoluteDeviation(median);
    const float robustDeviation = params::kRobustDeviationScale * mad;
    const float sensitivityScale =
        1.0F / std::max(params::kMinimumSensitivityDenominator, sensitivity);
    const float threshold =
        median + sensitivityScale *
                     (params::kRobustThresholdMultiplier * robustDeviation +
                      params::kNoveltyThresholdFloor);
    const float energyRise = features.rms / (previousSlowRms + 0.0010F);
    const float crest = features.peak / (features.rms + 1.0e-6F);
    const float sensitivityBlend = Clamp01(
        (sensitivity - 1.0F) / (params::kMaximumSensitivity - 1.0F));
    const uint32_t effectiveRefractoryFrames = static_cast<uint32_t>(std::lround(
        Lerp(static_cast<float>(refractoryFrames_),
             static_cast<float>(sensitiveRefractoryFrames_),
             sensitivityBlend)));
    const float minimumEnergyRise = Lerp(
        params::kMinimumEnergyRise,
        params::kSensitiveMinimumEnergyRise,
        sensitivityBlend);
    const float minimumLocalEnergySlope = Lerp(
        params::kMinimumLocalEnergySlope,
        params::kSensitiveMinimumLocalEnergySlope,
        sensitivityBlend);
    const float minimumCrest = Lerp(
        params::kMinimumCrest,
        params::kSensitiveMinimumCrest,
        sensitivityBlend);
    const float strongEnergyRise = Lerp(
        params::kStrongEnergyRise,
        params::kSensitiveStrongEnergyRise,
        sensitivityBlend);
    const float noveltyRiseMultiplier = Lerp(
        params::kNoveltyRiseMultiplier,
        params::kSensitiveNoveltyRiseMultiplier,
        sensitivityBlend);
    const float tactileMinimumPeak = Lerp(
        params::kTactileMinimumPeak,
        params::kSensitiveTactileMinimumPeak,
        sensitivityBlend);
    const float tactileMinimumRise = Lerp(
        params::kTactileMinimumRise,
        params::kSensitiveTactileMinimumRise,
        sensitivityBlend);
    const float tactileMinimumSlope = Lerp(
        params::kTactileMinimumSlope,
        params::kSensitiveTactileMinimumSlope,
        sensitivityBlend);
    const float tactileRise = features.tactileMeanAbsolute /
        (previousSlowTactileMeanAbsolute + params::kTactileRiseOffset);
    const float tactileSlope = features.tactileMeanAbsolute /
        (previousTactileMeanAbsolute_ + params::kTactileRiseOffset);
    const float localEnergySlope = features.rms /
        (previousRms_ + params::kTactileRiseOffset);
    const bool warm = framesSeen_ >= 8U;
    const bool refractoryDone = framesSinceOnset_ >= effectiveRefractoryFrames;
    const bool rising =
        features.novelty >= previousNovelty_ * noveltyRiseMultiplier;
    const bool transientShape = crest >= minimumCrest ||
                                energyRise >= strongEnergyRise;
    const bool audible = features.rms >= params::kMinimumRms;
    const bool spectralCandidate = rising && transientShape &&
                                   features.novelty > threshold &&
                                   energyRise >= minimumEnergyRise &&
                                   localEnergySlope >= minimumLocalEnergySlope;
    const bool tactileCandidate =
        features.tactilePeak >= tactileMinimumPeak &&
        tactileRise >= tactileMinimumRise &&
        tactileSlope >= tactileMinimumSlope;
    const bool candidate = warm && refractoryDone && audible &&
                           (spectralCandidate || tactileCandidate);

    if (candidate) {
        const float margin = (features.novelty - threshold) / (threshold + 1.0e-6F);
        const float energyScore = (energyRise - 1.0F) / 3.0F;
        const float crestScore = (crest - 1.4F) / 3.0F;
        const float spectralAmplitude = Clamp01(
            0.50F * Clamp01(margin / 3.0F) +
            0.35F * Clamp01(energyScore) +
            0.15F * Clamp01(crestScore));
        const float tactileRiseScore = Clamp01(
            (tactileRise - 1.0F) /
            params::kTactileRiseScoreRange);
        const float tactileLevelScore = Clamp01(
            features.tactilePeak * params::kTactileLevelScoreGain);
        const float tactileAmplitude = tactileCandidate
            ? Clamp01(0.55F * tactileRiseScore + 0.45F * tactileLevelScore)
            : 0.0F;
        result.amplitude = std::max(spectralAmplitude, tactileAmplitude);
        const float noveltySum = features.lowNovelty + features.midNovelty +
                                 features.highNovelty + 1.0e-6F;
        result.sharpness = Clamp01(
            (0.45F * features.midNovelty + features.highNovelty) / noveltySum);
        const float spectralConfidence = Clamp01(
            0.65F * Clamp01(margin / 2.0F) +
            0.35F * Clamp01((energyRise - 1.0F) / 2.0F));
        result.confidence = std::max(
            spectralConfidence,
            tactileCandidate ? tactileRiseScore : 0.0F);
        const float hapticFloor = Clamp01(
            params::kHapticAmplitudeFloor -
            params::kSensitivityFloorSlope * (sensitivity - 1.0F));
        result.detected = result.amplitude >= hapticFloor;
    }
    if (result.detected) {
        framesSinceOnset_ = 0;
    } else if (framesSinceOnset_ < std::numeric_limits<uint32_t>::max()) {
        ++framesSinceOnset_;
    }

    const float historyCeiling = median + 4.0F * robustDeviation + 0.01F;
    PushHistory(std::min(features.novelty, historyCeiling));
    previousNovelty_ = features.novelty;
    previousRms_ = features.rms;
    previousTactileMeanAbsolute_ = features.tactileMeanAbsolute;
    ++framesSeen_;
    return result;
}

float CausalOnsetDetector::MedianHistory() const noexcept {
    if (historyCount_ == 0U) return 0.0F;
    std::array<float, kHistoryCapacity> sorted{};
    std::copy_n(history_.begin(), historyCount_, sorted.begin());
    std::sort(sorted.begin(), sorted.begin() + historyCount_);
    const uint32_t middle = historyCount_ / 2U;
    if ((historyCount_ & 1U) != 0U) return sorted[middle];
    return 0.5F * (sorted[middle - 1U] + sorted[middle]);
}

float CausalOnsetDetector::MedianAbsoluteDeviation(float median) const noexcept {
    if (historyCount_ == 0U) return 0.0F;
    std::array<float, kHistoryCapacity> deviations{};
    for (uint32_t index = 0; index < historyCount_; ++index) {
        deviations[index] = std::abs(history_[index] - median);
    }
    std::sort(deviations.begin(), deviations.begin() + historyCount_);
    const uint32_t middle = historyCount_ / 2U;
    if ((historyCount_ & 1U) != 0U) return deviations[middle];
    return 0.5F * (deviations[middle - 1U] + deviations[middle]);
}

void CausalOnsetDetector::PushHistory(float value) noexcept {
    history_[historyPosition_] = value;
    historyPosition_ = (historyPosition_ + 1U) % kHistoryCapacity;
    historyCount_ = std::min<uint32_t>(historyCount_ + 1U, kHistoryCapacity);
}

void CausalOnsetDetector::Reset() noexcept {
    history_.fill(0.0F);
    historyPosition_ = 0;
    historyCount_ = 0;
    framesSeen_ = 0;
    framesSinceOnset_ = refractoryFrames_;
    slowRms_ = 0.0F;
    previousRms_ = 0.0F;
    previousNovelty_ = 0.0F;
    slowTactileMeanAbsolute_ = 0.0F;
    previousTactileMeanAbsolute_ = 0.0F;
}

} // namespace moonlight::haptics::core
