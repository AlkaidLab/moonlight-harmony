// SPDX-License-Identifier: Apache-2.0

#include "core/game_scene_author.h"

#include "core/dsp_parameters.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace moonlight::haptics::core {
namespace {

float Clamp01(float value) noexcept {
    return std::max(0.0F, std::min(1.0F, value));
}

} // namespace

GameSceneIntent GameSceneAuthor::Process(float continuousInput,
                                         float lowFrequencySupport,
                                         float transientAmplitude,
                                         bool hasTransient,
                                         const FeatureFrame& features,
                                         const OnsetResult& onset,
                                         bool onsetOnStableBeat,
                                         float rhythmConfidence) noexcept {
    GameSceneIntent intent;
    const float input = Clamp01(continuousInput);
    const float support = Clamp01(lowFrequencySupport);
    const float lowRatio = Clamp01(features.lowBandRatio);
    const float percussive = Clamp01(features.percussiveSalience);
    const float harmonic = Clamp01(features.harmonicSalience);
    const float percussiveLowRatio = Clamp01(
        features.percussiveLowBandRatio);

    // Freeze the input floor while low-frequency physical evidence is present.
    // Otherwise a slowly rising rumble could adapt itself away before the
    // causal persistence gate has collected enough non-tonal evidence.
    const bool rawLowFrequencyCandidate =
        input >= parameters::kGameContinuousStartInput &&
        support >= parameters::kGameContinuousStartSupport &&
        lowRatio >= parameters::kGameContinuousStartLowRatio;
    if (!continuousActive_ && !rawLowFrequencyCandidate) {
        noiseFloor_ += parameters::kGameNoiseFloorAlpha *
            (input - noiseFloor_);
    }
    const float adaptiveStartFloor = std::max(
        parameters::kGameContinuousStartInput,
        noiseFloor_ + parameters::kGameNoiseFloorMargin);
    const bool qualifies = input >= adaptiveStartFloor &&
                           support >= parameters::kGameContinuousStartSupport &&
                           lowRatio >= parameters::kGameContinuousStartLowRatio &&
                           percussive >=
                               parameters::kGameContinuousStartPercussive &&
                           harmonic <=
                               parameters::kGameContinuousStartHarmonicMaximum;
    if (qualifies) {
        if (qualifyingHops_ < std::numeric_limits<uint32_t>::max()) {
            ++qualifyingHops_;
        }
    } else if (rawLowFrequencyCandidate && qualifyingHops_ > 0U) {
        // Median HPSS salience naturally moves from hop to hop for coloured
        // noise. Treat a weak hop as lost evidence instead of erasing the
        // entire history; tonal or broadband loss still resets immediately.
        --qualifyingHops_;
    } else {
        qualifyingHops_ = 0U;
    }
    if (!continuousActive_ &&
        qualifyingHops_ >= parameters::kGameContinuousStartHops) {
        continuousActive_ = true;
    }
    if (continuousActive_) {
        const bool sustains =
            input >= parameters::kGameContinuousSustainInput &&
            support >= parameters::kGameContinuousSustainSupport &&
            lowRatio >= parameters::kGameContinuousSustainLowRatio &&
            percussive >= parameters::kGameContinuousSustainPercussive &&
            harmonic <=
                parameters::kGameContinuousSustainHarmonicMaximum;
        continuousMissHops_ = sustains ? 0U : continuousMissHops_ + 1U;
        if (continuousMissHops_ >= parameters::kGameContinuousReleaseHops) {
            continuousActive_ = false;
            qualifyingHops_ = 0U;
            continuousMissHops_ = 0U;
        }
    }

    float target = 0.0F;
    if (continuousActive_) {
        const float supportScale = Clamp01(
            (support - parameters::kGameContinuousSustainSupport) /
            parameters::kGameContinuousSupportRange);
        const float percussiveScale = Clamp01(
            (percussive - parameters::kGameContinuousSustainPercussive) /
            (1.0F - parameters::kGameContinuousSustainPercussive));
        target = std::min(
            input * parameters::kGameContinuousGain *
                (parameters::kGameContinuousMinimumSupportScale +
                 (1.0F - parameters::kGameContinuousMinimumSupportScale) *
                     supportScale) *
                (0.55F + 0.45F * percussiveScale),
            parameters::kGameContinuousMaximumAmplitude);
    }
    const float smoothing = target > continuousEnvelope_
        ? parameters::kGameContinuousAttack
        : parameters::kGameContinuousRelease;
    continuousEnvelope_ += smoothing * (target - continuousEnvelope_);
    if (!continuousActive_ &&
        continuousEnvelope_ < parameters::kGameContinuousStopFloor) {
        continuousEnvelope_ = 0.0F;
    }

    // A leaky activity budget gradually ducks only a long-running bed. Clear
    // transients stay intact and therefore retain impact after prolonged play.
    if (continuousEnvelope_ >= parameters::kGameFatigueActiveFloor) {
        fatigue_ = std::min(
            1.0F,
            fatigue_ + parameters::kGameFatigueAttack *
                (parameters::kGameFatigueBaseLoad + continuousEnvelope_));
    } else {
        fatigue_ = std::max(0.0F,
                            fatigue_ - parameters::kGameFatigueRecovery);
    }
    const float fatigueScale = 1.0F - parameters::kGameFatigueMaximumDuck *
        Clamp01((fatigue_ - parameters::kGameFatigueDuckStart) /
                (1.0F - parameters::kGameFatigueDuckStart));

    transientActivity_ *= parameters::kGameTransientActivityDecay;

    intent.transientAmplitude = Clamp01(transientAmplitude);
    intent.sharpness = Clamp01(onset.sharpness);
    intent.confidence = Clamp01(onset.confidence);
    const bool transientCandidate = hasTransient &&
        intent.transientAmplitude >= parameters::kGameTransientOutputFloor;
    if (transientCandidate) {
        const float noveltySum = features.lowNovelty + features.midNovelty +
                                 features.highNovelty + 1.0e-6F;
        const float clickBandShare = Clamp01(
            (0.45F * features.midNovelty + features.highNovelty) / noveltySum);
        const float tactileImpulse = Clamp01(
            (features.tactilePeak - parameters::kGameTactileImpactFloor) /
            parameters::kGameTactileImpactRange);
        const float percussiveScore = Clamp01(
            (percussive - parameters::kGamePercussiveSalienceFloor) /
            parameters::kGamePercussiveSalienceRange);
        const float noveltyScore = Clamp01(
            (features.percussiveNovelty -
             parameters::kGamePercussiveNoveltyFloor) /
            parameters::kGamePercussiveNoveltyRange);
        const float impactScore = Clamp01(
            0.28F * support + 0.18F * lowRatio +
            0.18F * percussiveLowRatio + 0.18F * tactileImpulse +
            0.18F * (1.0F - intent.sharpness));
        const float clickScore = Clamp01(
            0.45F * intent.sharpness + 0.25F * clickBandShare +
            0.30F * percussiveScore);
        const bool strongPhysicalImpact =
            impactScore >= parameters::kGameStrongImpactFloor &&
            (tactileImpulse >= 0.55F || support >= 0.82F) &&
            percussive >= 0.30F;
        const float harmonicPenalty = 0.45F * Clamp01(
            (harmonic - percussive + 0.10F) / 0.55F);
        const float activityPenalty =
            parameters::kGameTransientActivityMaximumPenalty * Clamp01(
                (transientActivity_ -
                 parameters::kGameTransientActivityPenaltyStart) /
                parameters::kGameTransientActivityPenaltyRange);
        const float stableBeatPenalty = onsetOnStableBeat
            ? parameters::kGameStableBeatMaximumPenalty *
                Clamp01(rhythmConfidence) *
                (1.0F - 0.85F * impactScore)
            : 0.0F;
        const float acceptance =
            0.38F * percussiveScore + 0.22F * noveltyScore +
            0.18F * intent.confidence + 0.12F * tactileImpulse +
            0.10F * std::max(impactScore, clickScore) -
            harmonicPenalty - activityPenalty - stableBeatPenalty;

        // Count candidates, not only accepted effects. This makes a dense BGM
        // percussion bed self-limiting while ordinary 1-2 Hz combat actions
        // recover between events. A strong physical impact always bypasses
        // the density and stable-beat attenuation.
        transientActivity_ = std::min(
            1.0F,
            transientActivity_ +
                parameters::kGameTransientActivityIncrement);
        intent.hasTransient = strongPhysicalImpact ||
            acceptance >= parameters::kGameTransientAcceptanceFloor;
        if (intent.hasTransient) {
            const float transientGain =
                parameters::kGameTransientBaseGain +
                parameters::kGameImpactGain * impactScore +
                parameters::kGameClickGain * clickScore;
            const float beatScale = onsetOnStableBeat && !strongPhysicalImpact
                ? 0.82F + 0.18F * (1.0F - Clamp01(rhythmConfidence))
                : 1.0F;
            intent.transientAmplitude = Clamp01(
                intent.transientAmplitude * transientGain * beatScale);
            intent.transientDurationMs =
                parameters::kGameMinimumTransientDurationMs +
                parameters::kGameImpactDurationRangeMs * impactScore +
                parameters::kGameHeavyTailDurationRangeMs *
                    (1.0F - intent.sharpness);
            intent.sharpness = Clamp01(
                0.70F * intent.sharpness + 0.30F * clickScore -
                parameters::kGameImpactSharpnessDuck * impactScore);
            intent.confidence = std::max(
                intent.confidence,
                Clamp01(
                    parameters::kGameImpactConfidenceScale * impactScore +
                    parameters::kGameClickConfidenceScale * clickScore));
            if (impactScore >= parameters::kGameStrongImpactFloor) {
                transientDuckHops_ = parameters::kGameTransientDuckHops;
            }
        } else {
            intent.transientAmplitude = 0.0F;
        }
    } else {
        intent.hasTransient = false;
        intent.transientAmplitude = 0.0F;
    }

    float transientDuckScale = 1.0F;
    if (transientDuckHops_ > 0U) {
        transientDuckScale = parameters::kGameTransientMaximumDuck +
            (1.0F - parameters::kGameTransientMaximumDuck) *
                (1.0F - static_cast<float>(transientDuckHops_) /
                            static_cast<float>(
                                parameters::kGameTransientDuckHops));
        --transientDuckHops_;
    }
    intent.continuousAmplitude = Clamp01(
        continuousEnvelope_ * fatigueScale * transientDuckScale);
    return intent;
}

void GameSceneAuthor::Reset() noexcept {
    continuousActive_ = false;
    qualifyingHops_ = 0U;
    continuousMissHops_ = 0U;
    transientDuckHops_ = 0U;
    continuousEnvelope_ = 0.0F;
    noiseFloor_ = 0.0F;
    fatigue_ = 0.0F;
    transientActivity_ = 0.0F;
}

} // namespace moonlight::haptics::core
