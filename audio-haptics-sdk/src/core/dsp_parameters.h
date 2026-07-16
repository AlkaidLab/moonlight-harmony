// SPDX-License-Identifier: Apache-2.0

#ifndef MOONLIGHT_HAPTICS_CORE_DSP_PARAMETERS_H
#define MOONLIGHT_HAPTICS_CORE_DSP_PARAMETERS_H

#include "moonlight_haptics/version.h"

#include <cstdint>

namespace moonlight::haptics::core::parameters {

inline constexpr char kParameterSetVersion[] =
    MOONLIGHT_HAPTICS_PARAMETER_SET_VERSION;

inline constexpr uint32_t kAnalysisHopsPerSecond = 200U;
inline constexpr uint32_t kWindowHops = 4U;
inline constexpr uint32_t kMaximumFftSize = 4096U;
inline constexpr float kPcenTimeConstantSeconds = 0.40F;
inline constexpr float kPcenExponent = 0.80F;
inline constexpr float kPcenOffset = 2.0F;

inline constexpr float kLowBandMinimumHz = 20.0F;
inline constexpr float kLowBandMaximumHz = 150.0F;
inline constexpr float kMidBandMaximumHz = 2000.0F;
inline constexpr float kHighBandMaximumHz = 8000.0F;
inline constexpr float kLowNoveltyWeight = 0.45F;
inline constexpr float kMidNoveltyWeight = 0.35F;
inline constexpr float kHighNoveltyWeight = 0.20F;

// Causal action-RPG features. Fitzgerald's median-filter HPSS uses time and
// frequency medians; the mobile path replaces the centred time median with a
// trailing 45 ms history. SuperFlux compares the current PCEN spectrum with a
// frequency-max-filtered previous frame to avoid vibrato false positives.
inline constexpr uint32_t kPercussiveTemporalFrames = 9U;
inline constexpr uint32_t kPercussiveFrequencyRadius = 3U;
inline constexpr uint32_t kSuperFluxFrequencyRadius = 2U;

inline constexpr float kRefractorySeconds = 0.120F;
inline constexpr float kSensitiveRefractorySeconds = 0.075F;
inline constexpr float kSlowRmsAlpha = 0.0125F;
inline constexpr float kRobustDeviationScale = 1.4826F;
inline constexpr float kRobustThresholdMultiplier = 3.0F;
inline constexpr float kNoveltyThresholdFloor = 0.0015F;
inline constexpr float kMinimumSensitivityDenominator = 0.35F;
inline constexpr float kMaximumSensitivity = 3.0F;
inline constexpr float kMinimumRms = 0.0012F;
inline constexpr float kMinimumEnergyRise = 1.18F;
inline constexpr float kSensitiveMinimumEnergyRise = 1.06F;
inline constexpr float kMinimumLocalEnergySlope = 1.08F;
inline constexpr float kSensitiveMinimumLocalEnergySlope = 1.08F;
inline constexpr float kMinimumCrest = 1.70F;
inline constexpr float kSensitiveMinimumCrest = 1.35F;
inline constexpr float kStrongEnergyRise = 2.0F;
inline constexpr float kSensitiveStrongEnergyRise = 1.50F;
inline constexpr float kNoveltyRiseMultiplier = 1.03F;
inline constexpr float kSensitiveNoveltyRiseMultiplier = 1.005F;
inline constexpr float kHapticAmplitudeFloor = 0.82F;
inline constexpr float kSensitivityFloorSlope = 0.25F;

// AOSP HapticGenerator waveform summary branch. These thresholds operate on
// the final soft-limited haptic waveform, not on raw PCM amplitude.
inline constexpr float kTactileSlowAlpha = 0.025F;
inline constexpr float kTactileRiseOffset = 0.0010F;
inline constexpr float kTactileMinimumPeak = 0.010F;
inline constexpr float kSensitiveTactileMinimumPeak = 0.0035F;
inline constexpr float kTactileMinimumRise = 2.20F;
inline constexpr float kSensitiveTactileMinimumRise = 1.30F;
inline constexpr float kTactileMinimumSlope = 1.15F;
inline constexpr float kSensitiveTactileMinimumSlope = 1.30F;
inline constexpr float kTactileLevelScoreGain = 10.0F;
inline constexpr float kTactileRiseScoreRange = 1.5F;

inline constexpr float kContinuousNoiseFloor = 0.002F;
inline constexpr float kContinuousFullScaleRms = 0.10F;
inline constexpr float kContinuousCurveExponent = 1.4F;
inline constexpr float kContinuousAttack = 0.35F;
inline constexpr float kContinuousRelease = 0.06F;
inline constexpr float kContinuousStopFloor = 0.004F;
inline constexpr float kContinuousStartFloor = 0.015F;
inline constexpr float kContinuousChangeThreshold = 0.035F;
inline constexpr uint32_t kContinuousMinimumUpdateHops = 4U;

// Portable MUSIC scene authoring. Device-specific amplitude floors and
// transient duration constraints belong to the platform renderer.
inline constexpr float kMusicTransientGain = 1.45F;
inline constexpr float kMusicRestartTransientGain = 0.75F;
inline constexpr uint64_t kMusicRestartGapUs = 30000000ULL;
inline constexpr float kMusicGrooveBedStartInput = 0.12F;
inline constexpr float kMusicGrooveBedSustainInput = 0.08F;
inline constexpr float kMusicGrooveBedStartSupport = 0.18F;
inline constexpr float kMusicGrooveBedSustainSupport = 0.12F;
inline constexpr float kMusicGrooveBedFullSupport = 0.45F;
inline constexpr float kMusicGrooveBedMinimumSupportScale = 0.35F;
inline constexpr float kMusicGrooveBedGain = 0.65F;
inline constexpr float kMusicGrooveBedMaximumAmplitude = 0.26F;
inline constexpr float kMusicGrooveBedOutputFloor = 0.05F;

// Portable GAME scene authoring for BGM-heavy action RPGs. Stable harmonic
// content and beat-locked percussion are attenuated; surprising percussive
// events and low-frequency physical impacts remain. Actuator choices stay in
// Renderer policy. At 200 hops/second, 12 hops add 60 ms of causal evidence
// before any repeating low-frequency bed can start.
inline constexpr bool kUseActionRpgGameSceneAuthor = true;
inline constexpr float kGameNoiseFloorAlpha = 0.010F;
inline constexpr float kGameNoiseFloorMargin = 0.025F;
inline constexpr float kGameContinuousStartInput = 0.110F;
inline constexpr float kGameContinuousSustainInput = 0.070F;
inline constexpr float kGameContinuousStartSupport = 0.50F;
inline constexpr float kGameContinuousSustainSupport = 0.35F;
inline constexpr float kGameContinuousStartLowRatio = 0.28F;
inline constexpr float kGameContinuousSustainLowRatio = 0.20F;
inline constexpr float kGameContinuousStartPercussive = 0.36F;
inline constexpr float kGameContinuousSustainPercussive = 0.24F;
inline constexpr float kGameContinuousStartHarmonicMaximum = 0.72F;
inline constexpr float kGameContinuousSustainHarmonicMaximum = 0.84F;
inline constexpr float kGameContinuousSupportRange = 0.50F;
inline constexpr float kGameContinuousMinimumSupportScale = 0.25F;
inline constexpr uint32_t kGameContinuousStartHops = 12U;
inline constexpr uint32_t kGameContinuousReleaseHops = 4U;
inline constexpr float kGameContinuousGain = 0.58F;
inline constexpr float kGameContinuousMaximumAmplitude = 0.24F;
inline constexpr float kGameContinuousAttack = 0.28F;
inline constexpr float kGameContinuousRelease = 0.14F;
inline constexpr float kGameContinuousStopFloor = 0.004F;
inline constexpr float kGameFatigueActiveFloor = 0.06F;
inline constexpr float kGameFatigueAttack = 0.0022F;
inline constexpr float kGameFatigueBaseLoad = 0.30F;
inline constexpr float kGameFatigueRecovery = 0.0040F;
inline constexpr float kGameFatigueDuckStart = 0.38F;
inline constexpr float kGameFatigueMaximumDuck = 0.65F;
inline constexpr float kGameTransientOutputFloor = 0.025F;
inline constexpr float kGameTransientBaseGain = 0.76F;
inline constexpr float kGameImpactGain = 0.42F;
inline constexpr float kGameClickGain = 0.14F;
inline constexpr float kGameTactileImpactFloor = 0.008F;
inline constexpr float kGameTactileImpactRange = 0.070F;
inline constexpr float kGamePercussiveSalienceFloor = 0.38F;
inline constexpr float kGamePercussiveSalienceRange = 0.52F;
inline constexpr float kGamePercussiveNoveltyFloor = 0.0010F;
inline constexpr float kGamePercussiveNoveltyRange = 0.020F;
inline constexpr float kGameTransientAcceptanceFloor = 0.40F;
inline constexpr float kGameStableBeatMaximumPenalty = 0.62F;
inline constexpr float kGameTransientActivityDecay = 0.985F;
inline constexpr float kGameTransientActivityIncrement = 0.18F;
inline constexpr float kGameTransientActivityPenaltyStart = 0.22F;
inline constexpr float kGameTransientActivityPenaltyRange = 0.45F;
inline constexpr float kGameTransientActivityMaximumPenalty = 0.28F;
inline constexpr float kGameMinimumTransientDurationMs = 15.0F;
inline constexpr float kGameImpactDurationRangeMs = 42.0F;
inline constexpr float kGameHeavyTailDurationRangeMs = 10.0F;
inline constexpr float kGameImpactSharpnessDuck = 0.26F;
inline constexpr float kGameImpactConfidenceScale = 0.72F;
inline constexpr float kGameClickConfidenceScale = 0.32F;
inline constexpr float kGameStrongImpactFloor = 0.66F;
inline constexpr uint32_t kGameTransientDuckHops = 14U;
inline constexpr float kGameTransientMaximumDuck = 0.32F;

} // namespace moonlight::haptics::core::parameters

#endif // MOONLIGHT_HAPTICS_CORE_DSP_PARAMETERS_H
