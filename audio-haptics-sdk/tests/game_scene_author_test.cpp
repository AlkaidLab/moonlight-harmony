// SPDX-License-Identifier: Apache-2.0

#include "core/game_scene_author.h"

#include <cassert>

namespace {

moonlight::haptics::core::FeatureFrame PhysicalImpactFrame() {
    moonlight::haptics::core::FeatureFrame frame;
    frame.lowBandRatio = 0.82F;
    frame.lowNovelty = 0.060F;
    frame.midNovelty = 0.008F;
    frame.highNovelty = 0.002F;
    frame.percussiveNovelty = 0.052F;
    frame.percussiveSalience = 0.92F;
    frame.harmonicSalience = 0.08F;
    frame.percussiveLowBandRatio = 0.76F;
    frame.tactilePeak = 0.090F;
    return frame;
}

moonlight::haptics::core::FeatureFrame SkillAttackFrame() {
    moonlight::haptics::core::FeatureFrame frame;
    frame.lowBandRatio = 0.08F;
    frame.lowNovelty = 0.004F;
    frame.midNovelty = 0.035F;
    frame.highNovelty = 0.050F;
    frame.percussiveNovelty = 0.034F;
    frame.percussiveSalience = 0.82F;
    frame.harmonicSalience = 0.18F;
    frame.percussiveLowBandRatio = 0.05F;
    frame.tactilePeak = 0.030F;
    return frame;
}

moonlight::haptics::core::FeatureFrame RumbleFrame() {
    auto frame = PhysicalImpactFrame();
    frame.percussiveNovelty = 0.002F;
    frame.percussiveSalience = 0.54F;
    frame.harmonicSalience = 0.46F;
    frame.percussiveLowBandRatio = 0.72F;
    frame.tactilePeak = 0.025F;
    return frame;
}

moonlight::haptics::core::FeatureFrame OrchestralFrame() {
    moonlight::haptics::core::FeatureFrame frame;
    frame.lowBandRatio = 0.22F;
    frame.lowNovelty = 0.025F;
    frame.midNovelty = 0.040F;
    frame.highNovelty = 0.022F;
    frame.percussiveNovelty = 0.0007F;
    frame.percussiveSalience = 0.14F;
    frame.harmonicSalience = 0.86F;
    frame.percussiveLowBandRatio = 0.10F;
    frame.tactilePeak = 0.012F;
    return frame;
}

moonlight::haptics::core::OnsetResult Onset(float sharpness) {
    moonlight::haptics::core::OnsetResult onset;
    onset.detected = true;
    onset.amplitude = 0.70F;
    onset.sharpness = sharpness;
    onset.confidence = 0.78F;
    return onset;
}

void AssertContinuousNeedsPersistentNonTonalRumble() {
    moonlight::haptics::core::GameSceneAuthor author;
    const auto rumble = RumbleFrame();
    const moonlight::haptics::core::OnsetResult noOnset;

    for (uint32_t hop = 0U; hop < 11U; ++hop) {
        const auto intent = author.Process(
            0.60F, 0.90F, 0.0F, false, rumble, noOnset);
        assert(intent.continuousAmplitude == 0.0F);
    }
    const auto started = author.Process(
        0.60F, 0.90F, 0.0F, false, rumble, noOnset);
    assert(started.continuousAmplitude > 0.04F);
    assert(started.continuousAmplitude <= 0.24F);

    author.Reset();
    const auto orchestral = OrchestralFrame();
    for (uint32_t hop = 0U; hop < 400U; ++hop) {
        const auto intent = author.Process(
            0.80F, 0.70F, 0.0F, false, orchestral, noOnset);
        assert(intent.continuousAmplitude == 0.0F);
    }
}

void AssertContinuousReleasesAndFatigues() {
    moonlight::haptics::core::GameSceneAuthor author;
    const auto rumble = RumbleFrame();
    const moonlight::haptics::core::OnsetResult noOnset;
    float early = 0.0F;
    float late = 0.0F;
    for (uint32_t hop = 0U; hop < 2400U; ++hop) {
        const auto intent = author.Process(
            0.65F, 0.92F, 0.0F, false, rumble, noOnset);
        if (hop == 100U) early = intent.continuousAmplitude;
        if (hop == 2399U) late = intent.continuousAmplitude;
    }
    assert(early > 0.15F);
    assert(early <= 0.24F);
    assert(late > 0.04F);
    assert(late < early * 0.60F);

    const moonlight::haptics::core::FeatureFrame silence;
    for (uint32_t hop = 0U; hop < 100U; ++hop) {
        author.Process(0.0F, 0.0F, 0.0F, false, silence, noOnset);
    }
    const auto stopped = author.Process(
        0.0F, 0.0F, 0.0F, false, silence, noOnset);
    assert(stopped.continuousAmplitude == 0.0F);
}

void AssertOrchestrationAndVibratoAreRejected() {
    moonlight::haptics::core::GameSceneAuthor author;
    const auto onset = Onset(0.70F);
    const auto rejected = author.Process(
        0.40F, 0.55F, 0.80F, true, OrchestralFrame(), onset);
    assert(!rejected.hasTransient);
    assert(rejected.transientAmplitude == 0.0F);
}

void AssertImpactAndSkillAttackRemainDistinct() {
    moonlight::haptics::core::GameSceneAuthor impactAuthor;
    const auto impact = impactAuthor.Process(
        0.0F, 0.92F, 0.70F, true,
        PhysicalImpactFrame(), Onset(0.12F));
    assert(impact.hasTransient);

    moonlight::haptics::core::GameSceneAuthor skillAuthor;
    const auto skill = skillAuthor.Process(
        0.0F, 0.22F, 0.70F, true,
        SkillAttackFrame(), Onset(0.92F));
    assert(skill.hasTransient);

    assert(impact.transientAmplitude > skill.transientAmplitude);
    assert(impact.transientDurationMs > skill.transientDurationMs + 20.0F);
    assert(impact.sharpness < skill.sharpness);
}

void AssertStableBgmBeatIsSuppressedButImpactBypassesIt() {
    moonlight::haptics::core::GameSceneAuthor beatAuthor;
    const auto stableBeat = beatAuthor.Process(
        0.0F, 0.22F, 0.70F, true,
        SkillAttackFrame(), Onset(0.75F), true, 0.95F);
    assert(!stableBeat.hasTransient);

    moonlight::haptics::core::GameSceneAuthor impactAuthor;
    const auto physicalImpact = impactAuthor.Process(
        0.0F, 0.92F, 0.70F, true,
        PhysicalImpactFrame(), Onset(0.12F), true, 0.95F);
    assert(physicalImpact.hasTransient);
}

void AssertFatigueNeverReducesTransient() {
    moonlight::haptics::core::GameSceneAuthor fresh;
    moonlight::haptics::core::GameSceneAuthor fatigued;
    const auto rumble = RumbleFrame();
    const moonlight::haptics::core::OnsetResult noOnset;
    for (uint32_t hop = 0U; hop < 2400U; ++hop) {
        fatigued.Process(0.65F, 0.92F, 0.0F, false, rumble, noOnset);
    }

    const auto freshImpact = fresh.Process(
        0.0F, 0.92F, 0.75F, true,
        PhysicalImpactFrame(), Onset(0.15F));
    const auto fatiguedImpact = fatigued.Process(
        0.65F, 0.92F, 0.75F, true,
        PhysicalImpactFrame(), Onset(0.15F));
    assert(freshImpact.transientAmplitude ==
           fatiguedImpact.transientAmplitude);
}

} // namespace

int main() {
    AssertContinuousNeedsPersistentNonTonalRumble();
    AssertContinuousReleasesAndFatigues();
    AssertOrchestrationAndVibratoAreRejected();
    AssertImpactAndSkillAttackRemainDistinct();
    AssertStableBgmBeatIsSuppressedButImpactBypassesIt();
    AssertFatigueNeverReducesTransient();
    return 0;
}
