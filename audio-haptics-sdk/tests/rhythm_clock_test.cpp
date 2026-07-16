// SPDX-License-Identifier: Apache-2.0

#include "core/causal_rhythm_clock.h"
#include "core/rhythm_activation_extractor.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdint>

namespace {

constexpr uint32_t kSampleRate = 48000U;
constexpr uint32_t kHopSize = 240U;
constexpr uint32_t kHopsPerSecond = kSampleRate / kHopSize;

struct RunResult {
    float tempo = 0.0F;
    float candidateTempo = 0.0F;
    float confidence = 0.0F;
    uint32_t reinforcements = 0U;
    uint32_t firstLockHop = 0U;
    bool locked = false;
};

RunResult RunPulseTrain(moonlight::haptics::core::CausalRhythmClock& clock,
                        float bpm,
                        float seconds,
                        bool markOnsets,
                        float activation = 0.90F) {
    RunResult result;
    const float periodHops = 60.0F * static_cast<float>(kHopsPerSecond) / bpm;
    const uint32_t totalHops = static_cast<uint32_t>(
        seconds * static_cast<float>(kHopsPerSecond));
    float nextBeat = 0.0F;
    for (uint32_t hop = 0U; hop < totalHops; ++hop) {
        const bool beat = static_cast<float>(hop) + 0.5F >= nextBeat;
        if (beat) nextBeat += periodHops;
        const auto frame = clock.ProcessActivation(
            beat ? activation : 0.0F,
            true,
            markOnsets && beat,
            markOnsets && beat);
        if (frame.reinforceBeat) ++result.reinforcements;
        if (frame.locked && !result.locked) result.firstLockHop = hop;
        result.locked = frame.locked;
        result.tempo = frame.tempoBpm;
        result.candidateTempo = frame.candidateTempoBpm;
        result.confidence = frame.confidence;
    }
    return result;
}

RunResult RunAccentedDoubleTime(
    moonlight::haptics::core::CausalRhythmClock& clock,
    float tactusBpm,
    float seconds) {
    RunResult result;
    const float subdivisionPeriodHops =
        60.0F * static_cast<float>(kHopsPerSecond) / (2.0F * tactusBpm);
    const uint32_t totalHops = static_cast<uint32_t>(
        seconds * static_cast<float>(kHopsPerSecond));
    float nextSubdivision = 0.0F;
    uint32_t subdivisionIndex = 0U;
    for (uint32_t hop = 0U; hop < totalHops; ++hop) {
        const bool pulse = static_cast<float>(hop) + 0.5F >= nextSubdivision;
        float activation = 0.0F;
        if (pulse) {
            // A common kick/snare pattern has evidence on every half-beat but
            // a clearly stronger tactus accent on alternating events. The
            // clock should not oscillate between the event rate and half-rate.
            activation = (subdivisionIndex & 1U) == 0U ? 0.95F : 0.30F;
            ++subdivisionIndex;
            nextSubdivision += subdivisionPeriodHops;
        }
        const auto frame = clock.ProcessActivation(
            activation, true, pulse, pulse);
        if (frame.reinforceBeat) ++result.reinforcements;
        if (frame.locked && !result.locked) result.firstLockHop = hop;
        result.locked = frame.locked;
        result.tempo = frame.tempoBpm;
        result.candidateTempo = frame.candidateTempoBpm;
        result.confidence = frame.confidence;
    }
    return result;
}

void AssertLocksKnownTempos() {
    for (float bpm : {72.0F, 90.0F, 120.0F, 160.0F}) {
        moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
        const RunResult result = RunPulseTrain(clock, bpm, 8.0F, true);
        if (std::abs(result.tempo - bpm) > 2.0F) {
            std::fprintf(
                stderr,
                "known tempo %.1f resolved to %.1f, candidate %.1f, "
                "confidence %.3f\n",
                bpm,
                result.tempo,
                result.candidateTempo,
                result.confidence);
        }
        assert(result.locked);
        assert(std::abs(result.tempo - bpm) <= 2.0F);
        assert(result.confidence >= 0.65F);
        assert(result.firstLockHop <= static_cast<uint32_t>(
            5.0F * static_cast<float>(kHopsPerSecond)));
        // Detected onsets must never be duplicated as predicted beats.
        assert(result.reinforcements == 0U);
    }
}

void AssertWeakSupportedBeatsAreReinforced() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    const RunResult locked = RunPulseTrain(clock, 120.0F, 5.0F, true);
    assert(locked.locked);

    // The onset detector misses these quieter events, but the current acoustic
    // evidence remains phase-aligned with the already locked clock.
    const RunResult weak = RunPulseTrain(clock, 120.0F, 4.0F, false, 0.18F);
    assert(weak.locked);
    assert(weak.reinforcements >= 5U);
    assert(weak.reinforcements <= 9U);
}

void AssertFeaturePathReinforcesCompressedBeats() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    moonlight::haptics::core::RhythmActivationExtractor extractor(
        kSampleRate, kHopSize);
    const uint32_t periodHops = kHopsPerSecond / 2U;
    uint32_t reinforcements = 0U;
    bool locked = false;

    for (uint32_t hop = 0U; hop < 10U * kHopsPerSecond; ++hop) {
        const bool beat = hop % periodHops == 0U;
        const bool training = hop < 5U * kHopsPerSecond;
        moonlight::haptics::core::FeatureFrame features;
        features.rms = 0.10F;
        features.lowBandRatio = beat ? 0.45F : 0.30F;
        features.lowNovelty = beat ? (training ? 0.040F : 0.010F) : 0.006F;
        features.midNovelty = beat ? (training ? 0.015F : 0.004F) : 0.003F;
        features.highNovelty = beat ? (training ? 0.005F : 0.001F) : 0.001F;
        features.novelty = 0.45F * features.lowNovelty +
                           0.35F * features.midNovelty +
                           0.20F * features.highNovelty;
        features.tactileMeanAbsolute =
            beat ? (training ? 0.030F : 0.018F) : 0.016F;
        moonlight::haptics::core::OnsetResult onset;
        onset.detected = beat && training;
        onset.amplitude = onset.detected ? 0.80F : 0.0F;

        const auto activation = extractor.Process(features, onset);
        const auto frame = clock.ProcessActivation(
            activation.activation,
            activation.audible,
            activation.acousticOnset,
            activation.evidenceEvent);
        locked = locked || frame.locked;
        if (!training && frame.reinforceBeat) ++reinforcements;
    }

    assert(locked);
    assert(reinforcements >= 6U);
    assert(reinforcements <= 11U);
}

void AssertNoEvidenceMeansNoPredictionAndUnlocks() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    assert(RunPulseTrain(clock, 100.0F, 6.0F, true).locked);

    uint32_t reinforcements = 0U;
    moonlight::haptics::core::RhythmClockFrame finalFrame;
    for (uint32_t hop = 0U; hop < 3U * kHopsPerSecond; ++hop) {
        finalFrame = clock.ProcessActivation(0.0F, false, false, false);
        if (finalFrame.reinforceBeat) ++reinforcements;
    }
    assert(reinforcements == 0U);
    assert(!finalFrame.locked);
    assert(finalFrame.tempoBpm == 0.0F);
}

void AssertTracksTempoChange() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    assert(RunPulseTrain(clock, 120.0F, 7.0F, true).locked);
    const RunResult changed = RunPulseTrain(clock, 90.0F, 8.0F, true);
    assert(changed.locked);
    assert(std::abs(changed.tempo - 90.0F) <= 3.0F);
}

void AssertAccentedDoubleTimeSelectsStableTactus() {
    for (float tactusBpm : {70.0F, 85.0F}) {
        moonlight::haptics::core::CausalRhythmClock clock(
            kSampleRate, kHopSize);
        const RunResult result = RunAccentedDoubleTime(
            clock, tactusBpm, 12.0F);
        if (std::abs(result.tempo - tactusBpm) > 2.0F) {
            std::fprintf(
                stderr,
                "accented tactus %.1f resolved to %.1f (confidence %.3f)\n",
                tactusBpm,
                result.tempo,
                result.confidence);
        }
        assert(result.locked);
        assert(std::abs(result.tempo - tactusBpm) <= 2.0F);
        assert(result.confidence >= 0.58F);
        assert(result.firstLockHop <= static_cast<uint32_t>(
            7.0F * static_cast<float>(kHopsPerSecond)));
        assert(result.reinforcements == 0U);
    }
}

void AssertShortEvidenceGapPreservesClock() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    assert(RunPulseTrain(clock, 120.0F, 6.0F, true).locked);

    for (uint32_t hop = 0U; hop < kHopsPerSecond / 2U; ++hop) {
        const auto frame = clock.ProcessActivation(0.0F, false, false, false);
        assert(frame.locked);
        assert(!frame.reinforceBeat);
    }

    const RunResult resumed = RunPulseTrain(clock, 120.0F, 3.0F, true);
    assert(resumed.locked);
    assert(std::abs(resumed.tempo - 120.0F) <= 2.0F);
}

void AssertBriefConfidenceDipKeepsLock() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    const RunResult initial = RunPulseTrain(clock, 120.0F, 6.0F, true);
    assert(initial.locked);

    // A short broadband/aperiodic section can temporarily collapse resonator
    // coherence even though the musical tempo has not changed. Do not drop the
    // established clock on a single 50 ms evaluation.
    moonlight::haptics::core::RhythmClockFrame burstFrame;
    for (uint32_t hop = 0U; hop < kHopsPerSecond / 2U; ++hop) {
        burstFrame = clock.ProcessActivation(
            0.35F, true, false, false);
        assert(burstFrame.locked);
        assert(std::abs(burstFrame.tempoBpm - 120.0F) <= 2.0F);
    }

    const RunResult resumed = RunPulseTrain(clock, 120.0F, 3.0F, true);
    if (std::abs(resumed.tempo - 120.0F) > 2.0F) {
        std::fprintf(
            stderr,
            "brief confidence dip resumed at %.1f BPM, candidate %.1f "
            "(confidence %.3f); initial candidate %.1f, burst candidate %.1f\n",
            resumed.tempo,
            resumed.candidateTempo,
            resumed.confidence,
            initial.candidateTempo,
            burstFrame.candidateTempoBpm);
    }
    assert(resumed.locked);
    assert(std::abs(resumed.tempo - 120.0F) <= 2.0F);
}

void AssertSustainedAperiodicInputStillUnlocks() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    assert(RunPulseTrain(clock, 120.0F, 6.0F, true).locked);

    moonlight::haptics::core::RhythmClockFrame finalFrame;
    for (uint32_t hop = 0U; hop < 3U * kHopsPerSecond; ++hop) {
        finalFrame = clock.ProcessActivation(0.35F, true, false, false);
    }
    if (finalFrame.locked) {
        std::fprintf(
            stderr,
            "aperiodic input remained active: candidate %.1f confidence %.3f "
            "phase %.3f coasting=%d\n",
            finalFrame.candidateTempoBpm,
            finalFrame.confidence,
            finalFrame.phase,
            finalFrame.coasting ? 1 : 0);
    }
    assert(!finalFrame.locked);
}

void AssertDormantClockRapidlyRelocksOnAlignedEvents() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    assert(RunPulseTrain(clock, 120.0F, 6.0F, true).locked);

    moonlight::haptics::core::RhythmClockFrame dormantFrame;
    uint32_t transitionPredictions = 0U;
    uint32_t dormantPredictions = 0U;
    for (uint32_t hop = 0U; hop < 3U * kHopsPerSecond; ++hop) {
        dormantFrame = clock.ProcessActivation(0.35F, true, false, false);
        if (dormantFrame.reinforceBeat) {
            ++transitionPredictions;
            if (dormantFrame.coasting) ++dormantPredictions;
        }
    }
    assert(!dormantFrame.locked);
    assert(dormantFrame.coasting);
    assert(dormantPredictions == 0U);
    assert(transitionPredictions <= 2U);
    assert(std::abs(dormantFrame.candidateTempoBpm - 120.0F) <= 2.0F);

    const RunResult resumed = RunPulseTrain(clock, 120.0F, 2.0F, true);
    assert(resumed.locked);
    assert(resumed.firstLockHop <= kHopsPerSecond);
    assert(std::abs(resumed.tempo - 120.0F) <= 2.0F);
}

void AssertOffPhaseEventsDoNotWakeDormantClock() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    assert(RunPulseTrain(clock, 120.0F, 6.0F, true).locked);

    moonlight::haptics::core::RhythmClockFrame frame;
    for (uint32_t hop = 0U; hop < 3U * kHopsPerSecond; ++hop) {
        frame = clock.ProcessActivation(0.35F, true, false, false);
    }
    assert(frame.coasting);

    uint32_t injected = 0U;
    uint32_t injectionCooldown = 0U;
    for (uint32_t hop = 0U; hop < 2U * kHopsPerSecond; ++hop) {
        const bool offPhase = injected < 3U && injectionCooldown == 0U &&
            frame.phase >= 0.30F && frame.phase <= 0.36F;
        frame = clock.ProcessActivation(
            offPhase ? 0.90F : 0.0F,
            true,
            offPhase,
            offPhase);
        if (offPhase) {
            ++injected;
            injectionCooldown = 80U;
        } else if (injectionCooldown > 0U) {
            --injectionCooldown;
        }
        assert(!frame.locked);
        assert(!frame.reinforceBeat);
    }
    assert(injected == 3U);
    assert(frame.coasting);
}

void AssertDormantMemoryEventuallyExpires() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    assert(RunPulseTrain(clock, 120.0F, 6.0F, true).locked);

    moonlight::haptics::core::RhythmClockFrame frame;
    for (uint32_t hop = 0U; hop < 3U * kHopsPerSecond; ++hop) {
        frame = clock.ProcessActivation(0.35F, true, false, false);
    }
    assert(frame.coasting);

    for (uint32_t hop = 0U; hop < 7U * kHopsPerSecond; ++hop) {
        frame = clock.ProcessActivation(0.35F, true, false, false);
        assert(!frame.reinforceBeat);
    }
    assert(!frame.locked);
    assert(!frame.coasting);
}

void AssertBriefTempoChallengerDoesNotMoveLockedClock() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    assert(RunPulseTrain(clock, 120.0F, 6.0F, true).locked);

    const RunResult challenged = RunPulseTrain(clock, 90.0F, 0.75F, true);
    assert(challenged.locked);
    assert(std::abs(challenged.tempo - 120.0F) <= 2.0F);

    const RunResult resumed = RunPulseTrain(clock, 120.0F, 3.0F, true);
    if (std::abs(resumed.tempo - 120.0F) > 2.0F) {
        std::fprintf(
            stderr,
            "brief challenger resumed at %.1f BPM, candidate %.1f, "
            "confidence %.3f\n",
            resumed.tempo,
            resumed.candidateTempo,
            resumed.confidence);
    }
    assert(resumed.locked);
    assert(std::abs(resumed.tempo - 120.0F) <= 2.0F);
}

void AssertTracksSustainedOctaveChange() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    assert(RunPulseTrain(clock, 120.0F, 6.0F, true).locked);

    const RunResult changed = RunPulseTrain(clock, 60.0F, 10.0F, true);
    if (std::abs(changed.tempo - 60.0F) > 2.0F) {
        std::fprintf(
            stderr,
            "sustained octave change resolved to %.1f BPM, candidate %.1f "
            "(confidence %.3f)\n",
            changed.tempo,
            changed.candidateTempo,
            changed.confidence);
    }
    assert(changed.locked);
    assert(std::abs(changed.tempo - 60.0F) <= 2.0F);
}

void AssertIrregularEventsDoNotPredict() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    const uint32_t events[] = {0U, 117U, 297U, 419U, 474U, 645U, 717U};
    std::size_t eventIndex = 0U;
    uint32_t reinforcements = 0U;
    for (uint32_t hop = 0U; hop < 1000U; ++hop) {
        const bool event = eventIndex < (sizeof(events) / sizeof(events[0])) &&
                           hop == events[eventIndex];
        if (event) ++eventIndex;
        const auto frame = clock.ProcessActivation(event ? 0.9F : 0.0F,
                                                   true, event, event);
        if (frame.reinforceBeat) ++reinforcements;
    }
    assert(reinforcements == 0U);

    moonlight::haptics::core::RhythmClockFrame finalFrame;
    for (uint32_t hop = 0U; hop < 3U * kHopsPerSecond; ++hop) {
        finalFrame = clock.ProcessActivation(0.0F, false, false, false);
        assert(!finalFrame.reinforceBeat);
    }
    assert(!finalFrame.locked);
}

void AssertLowBandPulseWinsOverCymbalDistractors() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    moonlight::haptics::core::RhythmActivationExtractor extractor(
        kSampleRate, kHopSize);
    moonlight::haptics::core::RhythmClockFrame finalFrame;

    for (uint32_t hop = 0U; hop < 10U * kHopsPerSecond; ++hop) {
        const bool kick = hop % 100U == 0U;
        const bool cymbal = hop % 50U == 25U;
        moonlight::haptics::core::FeatureFrame features;
        features.rms = 0.10F;
        features.lowBandRatio = kick ? 0.55F : (cymbal ? 0.02F : 0.20F);
        features.lowNovelty = kick ? 0.050F : 0.005F;
        features.midNovelty = kick ? 0.012F : (cymbal ? 0.006F : 0.004F);
        features.highNovelty = kick ? 0.005F : (cymbal ? 0.060F : 0.003F);
        features.novelty = 0.45F * features.lowNovelty +
                           0.35F * features.midNovelty +
                           0.20F * features.highNovelty;
        features.tactileMeanAbsolute = kick ? 0.035F : 0.016F;
        moonlight::haptics::core::OnsetResult onset;
        onset.detected = kick || cymbal;
        onset.amplitude = onset.detected ? 0.80F : 0.0F;

        const auto activation = extractor.Process(features, onset);
        if (cymbal && hop >= 200U) {
            assert(!activation.evidenceEvent);
            assert(activation.activation < 0.20F);
        }
        finalFrame = clock.ProcessActivation(
            activation.activation,
            activation.audible,
            activation.acousticOnset,
            activation.evidenceEvent);
    }

    assert(finalFrame.locked);
    assert(std::abs(finalFrame.tempoBpm - 120.0F) <= 2.0F);
}

void AssertHighFrequencyTransientsCannotLockClock() {
    moonlight::haptics::core::CausalRhythmClock clock(kSampleRate, kHopSize);
    moonlight::haptics::core::RhythmActivationExtractor extractor(
        kSampleRate, kHopSize);
    bool everLocked = false;

    for (uint32_t hop = 0U; hop < 10U * kHopsPerSecond; ++hop) {
        const bool transient = hop % 83U == 17U || hop % 137U == 49U;
        moonlight::haptics::core::FeatureFrame features;
        features.rms = 0.08F;
        features.lowBandRatio = 0.01F;
        features.lowNovelty = 0.0005F;
        features.midNovelty = transient ? 0.004F : 0.001F;
        features.highNovelty = transient ? 0.070F : 0.004F;
        features.novelty = 0.45F * features.lowNovelty +
                           0.35F * features.midNovelty +
                           0.20F * features.highNovelty;
        features.tactileMeanAbsolute = 0.008F;
        moonlight::haptics::core::OnsetResult onset;
        onset.detected = transient;
        onset.amplitude = transient ? 0.90F : 0.0F;

        const auto activation = extractor.Process(features, onset);
        if (transient && hop >= 200U) assert(!activation.evidenceEvent);
        const auto frame = clock.ProcessActivation(
            activation.activation,
            activation.audible,
            activation.acousticOnset,
            activation.evidenceEvent);
        everLocked = everLocked || frame.locked;
        assert(!frame.reinforceBeat);
    }
    assert(!everLocked);
}

} // namespace

int main() {
    AssertLocksKnownTempos();
    AssertWeakSupportedBeatsAreReinforced();
    AssertFeaturePathReinforcesCompressedBeats();
    AssertNoEvidenceMeansNoPredictionAndUnlocks();
    AssertTracksTempoChange();
    AssertAccentedDoubleTimeSelectsStableTactus();
    AssertShortEvidenceGapPreservesClock();
    AssertBriefConfidenceDipKeepsLock();
    AssertSustainedAperiodicInputStillUnlocks();
    AssertDormantClockRapidlyRelocksOnAlignedEvents();
    AssertOffPhaseEventsDoNotWakeDormantClock();
    AssertDormantMemoryEventuallyExpires();
    AssertBriefTempoChallengerDoesNotMoveLockedClock();
    AssertTracksSustainedOctaveChange();
    AssertIrregularEventsDoNotPredict();
    AssertLowBandPulseWinsOverCymbalDistractors();
    AssertHighFrequencyTransientsCannotLockClock();
    return 0;
}
