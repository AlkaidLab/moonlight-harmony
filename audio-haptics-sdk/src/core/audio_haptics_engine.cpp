// SPDX-License-Identifier: Apache-2.0

#include "moonlight_haptics/audio_haptics.h"

#include "core/causal_onset_detector.h"
#include "core/causal_rhythm_clock.h"
#include "core/dsp_parameters.h"
#include "core/feature_extractor.h"
#include "core/game_scene_author.h"
#include "core/music_scene_author.h"
#include "core/rhythm_activation_extractor.h"
#include "dsp/aosp_haptic_envelope.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>

static_assert(std::atomic<uint32_t>::is_always_lock_free,
              "The real-time config path requires lock-free 32-bit atomics");
static_assert(sizeof(float) == sizeof(uint32_t), "ABI v1 requires 32-bit float");
static_assert(sizeof(AhHapticFrame) == 80, "AhHapticFrame ABI v1 must be 80 bytes");

struct AhEngine {
    AhEngine(uint32_t sampleRateValue, uint32_t channelCountValue)
        : sampleRate(sampleRateValue),
          channelCount(channelCountValue),
          analysisHopFrames(
              (sampleRateValue +
               moonlight::haptics::core::parameters::kAnalysisHopsPerSecond / 2U) /
              moonlight::haptics::core::parameters::kAnalysisHopsPerSecond),
          features(sampleRateValue, channelCountValue),
          tactileEnvelope(sampleRateValue, channelCountValue, analysisHopFrames),
          onset(sampleRateValue, analysisHopFrames),
          rhythmActivation(sampleRateValue, analysisHopFrames),
          rhythm(sampleRateValue, analysisHopFrames) {}

    uint32_t sampleRate;
    uint32_t channelCount;
    uint32_t analysisHopFrames;

    std::atomic<uint32_t> requestedScene{AH_SCENE_GAME};
    std::atomic<uint32_t> sensitivityBits{0};
    std::atomic<uint32_t> outputGainBits{0};
    std::atomic<uint32_t> featureFlags{0};

    uint64_t processedFrames = 0;
    float continuousAmplitude = 0.0F;
    float lastEmittedContinuous = 0.0F;
    uint32_t hopsSinceContinuousOutput = 0;
    moonlight::haptics::core::FeatureExtractor features;
    moonlight::haptics::dsp::AospHapticEnvelope tactileEnvelope;
    moonlight::haptics::core::CausalOnsetDetector onset;
    moonlight::haptics::core::RhythmActivationExtractor rhythmActivation;
    moonlight::haptics::core::CausalRhythmClock rhythm;
    moonlight::haptics::core::GameSceneAuthor gameAuthor;
    moonlight::haptics::core::MusicSceneAuthor musicAuthor;
};

namespace {

constexpr uint32_t kMinimumSampleRate = 8000;
constexpr uint32_t kMaximumSampleRate = 192000;
constexpr uint32_t kMaximumChannels = 8;

uint32_t FloatToBits(float value) noexcept {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

float BitsToFloat(uint32_t bits) noexcept {
    float value = 0.0F;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

float Clamp01(float value) noexcept {
    return std::max(0.0F, std::min(1.0F, value));
}

bool IsFiniteInRange(float value, float minimum, float maximum) noexcept {
    return std::isfinite(value) && value >= minimum && value <= maximum;
}

AhStatus ValidateConfig(const AhConfig* config) noexcept {
    if (config == nullptr || config->struct_size < AH_CONFIG_V1_SIZE) {
        return AH_STATUS_INVALID_ARGUMENT;
    }
    if (config->sample_rate < kMinimumSampleRate ||
        config->sample_rate > kMaximumSampleRate ||
        config->channel_count == 0 ||
        config->channel_count > kMaximumChannels) {
        return AH_STATUS_UNSUPPORTED;
    }
    if (config->requested_scene > AH_SCENE_AUTO ||
        !IsFiniteInRange(config->sensitivity, 0.1F, 3.0F) ||
        !IsFiniteInRange(config->output_gain, 0.0F, 1.0F)) {
        return AH_STATUS_INVALID_ARGUMENT;
    }
    if (config->feature_flags != 0) {
        return AH_STATUS_UNSUPPORTED;
    }
    return AH_STATUS_OK;
}

void StoreRuntimeConfig(AhEngine& engine, const AhConfig& config) noexcept {
    engine.requestedScene.store(config.requested_scene, std::memory_order_release);
    engine.sensitivityBits.store(FloatToBits(config.sensitivity), std::memory_order_release);
    engine.outputGainBits.store(FloatToBits(config.output_gain), std::memory_order_release);
    engine.featureFlags.store(config.feature_flags, std::memory_order_release);
}

} // namespace

extern "C" {

AhStatus ah_config_init(AhConfig* config,
                        uint32_t sample_rate,
                        uint32_t channel_count) {
    if (config == nullptr) return AH_STATUS_INVALID_ARGUMENT;
    std::memset(config, 0, sizeof(*config));
    config->struct_size = AH_CONFIG_V1_SIZE;
    config->sample_rate = sample_rate;
    config->channel_count = channel_count;
    config->requested_scene = AH_SCENE_GAME;
    config->sensitivity = 1.0F;
    config->output_gain = 1.0F;
    return ValidateConfig(config);
}

AhStatus ah_create(const AhConfig* config, AhEngine** out_engine) {
    if (out_engine == nullptr) return AH_STATUS_INVALID_ARGUMENT;
    *out_engine = nullptr;

    const AhStatus validation = ValidateConfig(config);
    if (validation != AH_STATUS_OK) return validation;

    AhEngine* engine = nullptr;
    try {
        engine = new AhEngine(config->sample_rate, config->channel_count);
    } catch (const std::bad_alloc&) {
        return AH_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return AH_STATUS_UNSUPPORTED;
    }
    StoreRuntimeConfig(*engine, *config);
    *out_engine = engine;
    return AH_STATUS_OK;
}

AhStatus ah_update_config(AhEngine* engine, const AhConfig* config) {
    if (engine == nullptr) return AH_STATUS_INVALID_ARGUMENT;
    const AhStatus validation = ValidateConfig(config);
    if (validation != AH_STATUS_OK) return validation;
    if (config->sample_rate != engine->sampleRate ||
        config->channel_count != engine->channelCount) {
        return AH_STATUS_RECREATE_REQUIRED;
    }
    StoreRuntimeConfig(*engine, *config);
    return AH_STATUS_OK;
}

uint32_t ah_get_max_output_frames(const AhEngine* engine,
                                  uint32_t input_frame_count) {
    if (engine == nullptr || input_frame_count == 0 || engine->analysisHopFrames == 0) {
        return 0;
    }
    const uint64_t hops =
        (static_cast<uint64_t>(input_frame_count) + engine->analysisHopFrames - 1U) /
        engine->analysisHopFrames;
    const uint64_t capacity = hops + 2U;
    return capacity > std::numeric_limits<uint32_t>::max()
        ? std::numeric_limits<uint32_t>::max()
        : static_cast<uint32_t>(capacity);
}

AhStatus ah_process_i16(AhEngine* engine,
                        const AhProcessInput* input,
                        AhHapticFrame* out_frames,
                        uint32_t out_capacity,
                        uint32_t* out_count) {
    if (out_count == nullptr) return AH_STATUS_INVALID_ARGUMENT;
    *out_count = 0;
    if (engine == nullptr || input == nullptr ||
        input->struct_size < AH_PROCESS_INPUT_V1_SIZE) {
        return AH_STATUS_INVALID_ARGUMENT;
    }
    if (input->frame_count > 0 && input->interleaved_pcm == nullptr) {
        return AH_STATUS_INVALID_ARGUMENT;
    }

    const uint32_t required = ah_get_max_output_frames(engine, input->frame_count);
    if (out_capacity < required) return AH_STATUS_BUFFER_TOO_SMALL;
    if (required > 0 && out_frames == nullptr) return AH_STATUS_INVALID_ARGUMENT;

    if (input->frame_count >
        std::numeric_limits<uint64_t>::max() - engine->processedFrames) {
        return AH_STATUS_BAD_STATE;
    }
    const uint64_t callDurationUs =
        static_cast<uint64_t>(input->frame_count) * 1000000ULL /
        engine->sampleRate;
    if (input->first_sample_time_us >
        std::numeric_limits<uint64_t>::max() - callDurationUs) {
        return AH_STATUS_BAD_STATE;
    }

    const float sensitivity = BitsToFloat(
        engine->sensitivityBits.load(std::memory_order_acquire));
    const float outputGain = BitsToFloat(
        engine->outputGainBits.load(std::memory_order_acquire));
    const uint32_t requestedScene =
        engine->requestedScene.load(std::memory_order_acquire);
    const uint32_t activeScene = requestedScene == AH_SCENE_AUTO
        ? static_cast<uint32_t>(AH_SCENE_GAME)
        : requestedScene;

    for (uint32_t sampleIndex = 0; sampleIndex < input->frame_count; ++sampleIndex) {
        moonlight::haptics::core::FeatureFrame features;
        moonlight::haptics::dsp::TactileEnvelopeFrame tactile;
        const size_t pcmOffset = static_cast<size_t>(sampleIndex) * engine->channelCount;
        const int16_t* sample = input->interleaved_pcm + pcmOffset;
        const bool tactileReady = engine->tactileEnvelope.PushInterleavedSample(
            sample, tactile);
        if (!engine->features.PushInterleavedSample(sample, features)) {
            continue;
        }
        if (!tactileReady) return AH_STATUS_BAD_STATE;
        features.tactileRms = tactile.rms;
        features.tactilePeak = tactile.peak;
        features.tactileMeanAbsolute = tactile.meanAbsolute;

        const moonlight::haptics::core::OnsetResult onset =
            engine->onset.Process(features, sensitivity);
        const moonlight::haptics::core::RhythmActivationFrame activation =
            engine->rhythmActivation.Process(features, onset);
        const moonlight::haptics::core::RhythmClockFrame rhythm =
            engine->rhythm.ProcessActivation(
                activation.activation,
                activation.audible,
                activation.acousticOnset,
                activation.evidenceEvent);
        const uint64_t frameTimestampUs = input->first_sample_time_us +
            (static_cast<uint64_t>(sampleIndex) + 1U) * 1000000ULL /
                engine->sampleRate;
        const float lowWeight = std::sqrt(features.lowBandRatio);
        float continuousTarget = Clamp01(
            (features.rms -
             moonlight::haptics::core::parameters::kContinuousNoiseFloor) /
            moonlight::haptics::core::parameters::kContinuousFullScaleRms) *
            lowWeight;
        continuousTarget = Clamp01(
            std::pow(continuousTarget,
                     moonlight::haptics::core::parameters::kContinuousCurveExponent) *
            outputGain);
        const float smoothing = continuousTarget > engine->continuousAmplitude
            ? moonlight::haptics::core::parameters::kContinuousAttack
            : moonlight::haptics::core::parameters::kContinuousRelease;
        engine->continuousAmplitude +=
            smoothing * (continuousTarget - engine->continuousAmplitude);
        if (engine->continuousAmplitude <
                moonlight::haptics::core::parameters::kContinuousStopFloor &&
            continuousTarget == 0.0F) {
            engine->continuousAmplitude = 0.0F;
        }

        uint32_t flags = AH_FRAME_NONE;
        const bool musicScene = activeScene == AH_SCENE_MUSIC;
        const bool rhythmPredicted = musicScene && rhythm.reinforceBeat;
        float authoredTransientAmplitude = onset.amplitude;
        if (musicScene && rhythm.onsetOnBeat) {
            authoredTransientAmplitude *= 1.0F + 0.16F * rhythm.confidence;
        }
        if (rhythmPredicted) {
            authoredTransientAmplitude = std::max(
                authoredTransientAmplitude,
                0.34F + 0.22F * rhythm.confidence);
        }
        const float baseTransientAmplitude = Clamp01(
            authoredTransientAmplitude * outputGain);
        const bool transientCandidate = (onset.detected || rhythmPredicted) &&
                                        baseTransientAmplitude >= 0.025F;
        const moonlight::haptics::core::MusicSceneIntent musicIntent =
            musicScene
                ? engine->musicAuthor.Process(
                      engine->continuousAmplitude,
                      activation.lowFrequencySupport,
                      baseTransientAmplitude,
                      transientCandidate,
                      frameTimestampUs)
                : moonlight::haptics::core::MusicSceneIntent{
                      engine->continuousAmplitude,
                      baseTransientAmplitude,
                      false};
        const moonlight::haptics::core::GameSceneIntent gameIntent =
            !musicScene &&
                    moonlight::haptics::core::parameters::
                        kUseActionRpgGameSceneAuthor
                ? engine->gameAuthor.Process(
                      engine->continuousAmplitude,
                      activation.lowFrequencySupport,
                      baseTransientAmplitude,
                      onset.detected && baseTransientAmplitude >= 0.025F,
                      features,
                      onset,
                      rhythm.locked && rhythm.onsetOnBeat,
                      rhythm.confidence)
                : moonlight::haptics::core::GameSceneIntent{
                      engine->continuousAmplitude,
                      baseTransientAmplitude,
                      25.0F + 35.0F * baseTransientAmplitude,
                      onset.sharpness,
                      std::max(onset.confidence,
                               rhythm.onsetOnBeat ? rhythm.confidence : 0.0F),
                      !musicScene && onset.detected &&
                          baseTransientAmplitude >= 0.025F};
        const float continuousAmplitude = musicScene
            ? musicIntent.continuousAmplitude
            : gameIntent.continuousAmplitude;
        const float transientAmplitude = musicScene
            ? musicIntent.transientAmplitude
            : gameIntent.transientAmplitude;
        const bool authoredTransient = musicScene
            ? transientCandidate && transientAmplitude >= 0.025F
            : gameIntent.hasTransient;
        if (authoredTransient) {
            flags |= AH_FRAME_TRANSIENT;
        }
        if (rhythmPredicted && (flags & AH_FRAME_TRANSIENT) != 0U) {
            flags |= AH_FRAME_RHYTHM_PREDICTED;
        }
        if (musicIntent.restartTransient &&
            (flags & AH_FRAME_TRANSIENT) != 0U) {
            flags |= AH_FRAME_MUSIC_RESTART;
        }

        ++engine->hopsSinceContinuousOutput;
        const float continuousDelta = std::abs(
            continuousAmplitude - engine->lastEmittedContinuous);
        const bool continuousStarted = engine->lastEmittedContinuous == 0.0F &&
                                       continuousAmplitude >=
                                           moonlight::haptics::core::parameters::
                                               kContinuousStartFloor;
        const bool continuousStopped = engine->lastEmittedContinuous > 0.0F &&
                                       continuousAmplitude == 0.0F;
        const bool periodicChange =
            engine->hopsSinceContinuousOutput >=
                moonlight::haptics::core::parameters::kContinuousMinimumUpdateHops &&
            continuousDelta >=
                moonlight::haptics::core::parameters::kContinuousChangeThreshold;
        if (continuousStarted || periodicChange) {
            flags |= AH_FRAME_CONTINUOUS_CHANGED;
        }
        if (continuousStopped) flags |= AH_FRAME_STOP;

        if (flags == AH_FRAME_NONE) continue;

        AhHapticFrame& output = out_frames[*out_count];
        std::memset(&output, 0, sizeof(output));
        output.struct_size = AH_HAPTIC_FRAME_V1_SIZE;
        output.flags = flags;
        output.timestamp_us = frameTimestampUs;
        output.continuous_amplitude = continuousAmplitude;
        output.transient_amplitude = transientAmplitude;
        // Keep the portable base duration independent of scene gain. The
        // platform renderer maps it to actuator-specific MUSIC bounds.
        output.transient_duration_ms = musicScene
            ? 25.0F + 35.0F * baseTransientAmplitude
            : gameIntent.transientDurationMs;
        output.sharpness = musicScene
            ? (rhythmPredicted
                   ? std::max(0.25F, onset.sharpness)
                   : onset.sharpness)
            : gameIntent.sharpness;
        output.low_band_ratio = features.lowBandRatio;
        output.stereo_pan = features.stereoPan;
        output.confidence = musicScene
            ? (rhythmPredicted
                   ? rhythm.confidence
                   : std::max(onset.confidence,
                              rhythm.onsetOnBeat ? rhythm.confidence : 0.0F))
            : gameIntent.confidence;
        output.active_scene = activeScene;
        output.reserved[0] = FloatToBits(rhythm.candidateTempoBpm);
        output.reserved[1] = FloatToBits(rhythm.confidence);
        output.reserved[2] = FloatToBits(rhythm.phase);
        output.reserved[3] = rhythm.locked ? 1U : 0U;
        output.reserved[4] = FloatToBits(activation.activation);
        output.reserved[5] = FloatToBits(activation.lowFrequencySupport);
        output.reserved[6] = rhythm.coasting ? 1U : 0U;
        ++(*out_count);

        if ((flags & (AH_FRAME_CONTINUOUS_CHANGED | AH_FRAME_STOP)) != 0U) {
            engine->lastEmittedContinuous = continuousAmplitude;
            engine->hopsSinceContinuousOutput = 0;
        }
    }

    engine->processedFrames += input->frame_count;
    return *out_count == 0U ? AH_STATUS_OK : AH_STATUS_OUTPUT_AVAILABLE;
}

void ah_reset(AhEngine* engine) {
    if (engine == nullptr) return;
    engine->processedFrames = 0;
    engine->continuousAmplitude = 0.0F;
    engine->lastEmittedContinuous = 0.0F;
    engine->hopsSinceContinuousOutput = 0;
    engine->features.Reset();
    engine->tactileEnvelope.Reset();
    engine->onset.Reset();
    engine->rhythmActivation.Reset();
    engine->rhythm.Reset();
    engine->gameAuthor.Reset();
    engine->musicAuthor.Reset();
}

void ah_destroy(AhEngine* engine) {
    delete engine;
}

uint32_t ah_get_abi_version(void) {
    return MOONLIGHT_HAPTICS_ABI_VERSION;
}

const char* ah_get_version_string(void) {
    return MOONLIGHT_HAPTICS_VERSION_STRING;
}

const char* ah_get_parameter_set_version(void) {
    return moonlight::haptics::core::parameters::kParameterSetVersion;
}

const char* ah_status_string(AhStatus status) {
    switch (status) {
        case AH_STATUS_OK: return "ok";
        case AH_STATUS_OUTPUT_AVAILABLE: return "output available";
        case AH_STATUS_INVALID_ARGUMENT: return "invalid argument";
        case AH_STATUS_UNSUPPORTED: return "unsupported";
        case AH_STATUS_BUFFER_TOO_SMALL: return "output buffer too small";
        case AH_STATUS_OUT_OF_MEMORY: return "out of memory";
        case AH_STATUS_BAD_STATE: return "bad state";
        case AH_STATUS_RECREATE_REQUIRED: return "engine recreation required";
        default: return "unknown status";
    }
}

} // extern "C"
