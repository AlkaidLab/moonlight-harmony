// SPDX-License-Identifier: Apache-2.0

#include "moonlight_haptics/audio_haptics.h"
#include "core/causal_onset_detector.h"
#include "dsp/aosp_haptic_envelope.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <vector>

namespace {

constexpr uint32_t kSampleRate = 48000U;
constexpr uint32_t kBlockFrames = 240U;
constexpr double kPi = 3.14159265358979323846;

int16_t ToPcm16(float value) {
    const float clamped = std::max(-1.0F, std::min(1.0F, value));
    return static_cast<int16_t>(std::lround(clamped * 32767.0F));
}

std::vector<int16_t> RenderClicks(uint32_t channelCount) {
    const uint32_t frameCount = 125000U;
    std::vector<int16_t> pcm(static_cast<size_t>(frameCount) * channelCount, 0);
    uint32_t randomState = 20002U;
    for (uint32_t eventFrame : {24000U, 48000U, 72000U, 96000U}) {
        for (uint32_t offset = 0; offset < 480U; ++offset) {
            randomState ^= randomState << 13U;
            randomState ^= randomState >> 17U;
            randomState ^= randomState << 5U;
            const float noise = static_cast<float>(randomState & 0xffffU) /
                                    32767.5F -
                                1.0F;
            const float envelope = std::exp(
                -static_cast<float>(offset) /
                (0.003F * static_cast<float>(kSampleRate)));
            const int16_t sample = ToPcm16(0.82F * envelope * noise);
            const size_t index = static_cast<size_t>(eventFrame + offset) * channelCount;
            pcm[index] = sample;
            if (channelCount == 2U) pcm[index + 1U] = static_cast<int16_t>(-sample);
        }
    }
    return pcm;
}

std::vector<int16_t> RenderSteadyTone() {
    const uint32_t frameCount = 144000U;
    std::vector<int16_t> pcm(static_cast<size_t>(frameCount) * 2U, 0);
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        const double time = static_cast<double>(frame) / kSampleRate;
        const float gain = 0.22F * std::min(1.0F, static_cast<float>(time / 0.30));
        const int16_t sample = ToPcm16(
            gain * static_cast<float>(std::sin(2.0 * kPi * 60.0 * time)));
        pcm[static_cast<size_t>(frame) * 2U] = sample;
        pcm[static_cast<size_t>(frame) * 2U + 1U] = sample;
    }
    return pcm;
}

std::vector<int16_t> RenderLowRumbleNoise() {
    const uint32_t frameCount = 144000U;
    std::vector<int16_t> pcm(static_cast<size_t>(frameCount) * 2U, 0);
    uint32_t randomState = 0x7f4a7c15U;
    float lowPass = 0.0F;
    float dcTracker = 0.0F;
    const float lowAlpha = 1.0F - std::exp(
        -2.0F * static_cast<float>(kPi) * 95.0F /
        static_cast<float>(kSampleRate));
    const float dcAlpha = 1.0F - std::exp(
        -2.0F * static_cast<float>(kPi) * 18.0F /
        static_cast<float>(kSampleRate));
    for (uint32_t frame = 0U; frame < frameCount; ++frame) {
        randomState ^= randomState << 13U;
        randomState ^= randomState >> 17U;
        randomState ^= randomState << 5U;
        const float noise = static_cast<float>(randomState & 0xffffU) /
                                32767.5F -
                            1.0F;
        lowPass += lowAlpha * (noise - lowPass);
        dcTracker += dcAlpha * (lowPass - dcTracker);
        const float time = static_cast<float>(frame) /
                           static_cast<float>(kSampleRate);
        const float gain = 2.6F * std::min(1.0F, time / 0.30F);
        const int16_t sample = ToPcm16(gain * (lowPass - dcTracker));
        pcm[static_cast<size_t>(frame) * 2U] = sample;
        pcm[static_cast<size_t>(frame) * 2U + 1U] = sample;
    }
    return pcm;
}

std::vector<uint64_t> Process(const std::vector<int16_t>& pcm,
                              uint32_t channelCount,
                              float sensitivity = 1.0F) {
    AhConfig config{};
    assert(ah_config_init(&config, kSampleRate, channelCount) == AH_STATUS_OK);
    config.sensitivity = sensitivity;
    AhEngine* engine = nullptr;
    assert(ah_create(&config, &engine) == AH_STATUS_OK);

    const uint32_t totalFrames =
        static_cast<uint32_t>(pcm.size() / channelCount);
    std::vector<uint64_t> transientTimes;
    for (uint32_t firstFrame = 0; firstFrame < totalFrames;
         firstFrame += kBlockFrames) {
        const uint32_t frameCount =
            std::min(kBlockFrames, totalFrames - firstFrame);
        const uint32_t capacity = ah_get_max_output_frames(engine, frameCount);
        std::vector<AhHapticFrame> outputs(capacity);
        AhProcessInput input{};
        input.struct_size = AH_PROCESS_INPUT_V1_SIZE;
        input.interleaved_pcm = pcm.data() +
                                static_cast<size_t>(firstFrame) * channelCount;
        input.frame_count = frameCount;
        input.first_sample_time_us =
            static_cast<uint64_t>(firstFrame) * 1000000ULL / kSampleRate;
        uint32_t outputCount = 0;
        const AhStatus status = ah_process_i16(
            engine, &input, outputs.data(), capacity, &outputCount);
        assert(status == AH_STATUS_OK || status == AH_STATUS_OUTPUT_AVAILABLE);
        assert(outputCount <= capacity);
        for (uint32_t index = 0; index < outputCount; ++index) {
            const AhHapticFrame& output = outputs[index];
            assert(output.struct_size == AH_HAPTIC_FRAME_V1_SIZE);
            assert(output.continuous_amplitude >= 0.0F &&
                   output.continuous_amplitude <= 1.0F);
            assert(output.transient_amplitude >= 0.0F &&
                   output.transient_amplitude <= 1.0F);
            assert(output.sharpness >= 0.0F && output.sharpness <= 1.0F);
            assert(output.low_band_ratio >= 0.0F && output.low_band_ratio <= 1.0F);
            assert(output.stereo_pan >= -1.0F && output.stereo_pan <= 1.0F);
            assert(output.confidence >= 0.0F && output.confidence <= 1.0F);
            if ((output.flags & AH_FRAME_TRANSIENT) != 0U) {
                transientTimes.push_back(output.timestamp_us);
            }
        }
    }
    ah_destroy(engine);
    return transientTimes;
}

void AssertCausalTiming(const std::vector<uint64_t>& outputs) {
    const uint64_t expected[] = {500000ULL, 1000000ULL, 1500000ULL, 2000000ULL};
    assert(outputs.size() == 4U);
    for (size_t index = 0; index < outputs.size(); ++index) {
        assert(outputs[index] >= expected[index]);
        assert(outputs[index] - expected[index] <= 5000ULL);
    }
}

void AssertHighSensitivityAcceptsCompressedBeat() {
    moonlight::haptics::core::CausalOnsetDetector normal(kSampleRate, kBlockFrames);
    moonlight::haptics::core::CausalOnsetDetector sensitive(kSampleRate, kBlockFrames);
    moonlight::haptics::core::FeatureFrame bed;
    bed.novelty = 0.010F;
    bed.lowNovelty = 0.006F;
    bed.midNovelty = 0.003F;
    bed.highNovelty = 0.001F;
    bed.rms = 0.10F;
    bed.peak = 0.14F;
    for (uint32_t frame = 0; frame < 240U; ++frame) {
        normal.Process(bed, 1.0F);
        sensitive.Process(bed, 2.5F);
    }

    moonlight::haptics::core::FeatureFrame beat = bed;
    beat.novelty = 0.060F;
    beat.lowNovelty = 0.040F;
    beat.midNovelty = 0.015F;
    beat.highNovelty = 0.005F;
    beat.rms = 0.11F;
    beat.peak = 0.16F;
    assert(!normal.Process(beat, 1.0F).detected);
    assert(sensitive.Process(beat, 2.5F).detected);
}

void AssertTactileBranchAcceptsCompressedBeat() {
    moonlight::haptics::core::CausalOnsetDetector normal(kSampleRate, kBlockFrames);
    moonlight::haptics::core::CausalOnsetDetector sensitive(kSampleRate, kBlockFrames);
    moonlight::haptics::core::FeatureFrame bed;
    bed.novelty = 0.010F;
    bed.lowNovelty = 0.006F;
    bed.midNovelty = 0.003F;
    bed.highNovelty = 0.001F;
    bed.rms = 0.10F;
    bed.peak = 0.14F;
    bed.tactileRms = 0.020F;
    bed.tactilePeak = 0.025F;
    bed.tactileMeanAbsolute = 0.016F;
    for (uint32_t frame = 0; frame < 240U; ++frame) {
        normal.Process(bed, 1.0F);
        sensitive.Process(bed, 2.5F);
    }

    // Raw level and spectral novelty barely move, while the actuator-shaped
    // waveform has a clear impulse. This is the compressed-music case the
    // AOSP branch is intended to recover.
    moonlight::haptics::core::FeatureFrame beat = bed;
    beat.tactileRms = 0.035F;
    beat.tactilePeak = 0.060F;
    beat.tactileMeanAbsolute = 0.026F;
    assert(!normal.Process(beat, 1.0F).detected);
    assert(sensitive.Process(beat, 2.5F).detected);
}

void AssertAospEnvelopeIsCausalAndSettles() {
    moonlight::haptics::dsp::AospHapticEnvelope envelope(
        kSampleRate, 2U, kBlockFrames);
    moonlight::haptics::dsp::TactileEnvelopeFrame frame;
    int16_t sample[2] = {0, 0};

    for (uint32_t index = 0; index < 8U * kBlockFrames; ++index) {
        const bool ready = envelope.PushInterleavedSample(sample, frame);
        if (ready) {
            assert(frame.peak == 0.0F);
            assert(frame.rms == 0.0F);
        }
    }

    uint32_t firstActiveHop = 0U;
    float maximumPeak = 0.0F;
    for (uint32_t hop = 1U; hop <= 12U; ++hop) {
        for (uint32_t index = 0; index < kBlockFrames; ++index) {
            sample[0] = hop == 1U && index == 0U ? 32767 : 0;
            sample[1] = static_cast<int16_t>(-sample[0]);
            if (envelope.PushInterleavedSample(sample, frame)) {
                assert(std::isfinite(frame.peak));
                assert(std::isfinite(frame.rms));
                maximumPeak = std::max(maximumPeak, frame.peak);
                if (firstActiveHop == 0U && frame.peak > 1.0e-5F) {
                    firstActiveHop = hop;
                }
            }
        }
    }
    assert(firstActiveHop >= 1U && firstActiveHop <= 3U);
    assert(maximumPeak > 1.0e-4F);

    // All filters are causal and stable: an impulse response must decay.
    assert(frame.peak < maximumPeak * 0.25F);
    envelope.Reset();
}

void AssertMusicAuthoringCrossesThePublicIrBoundary() {
    const std::vector<int16_t> pcm = RenderClicks(1U);
    AhConfig config{};
    assert(ah_config_init(&config, kSampleRate, 1U) == AH_STATUS_OK);
    config.requested_scene = AH_SCENE_MUSIC;
    AhEngine* engine = nullptr;
    assert(ah_create(&config, &engine) == AH_STATUS_OK);

    bool sawFirstTransient = false;
    bool sawLaterTransient = false;
    const uint32_t totalFrames = static_cast<uint32_t>(pcm.size());
    for (uint32_t firstFrame = 0; firstFrame < totalFrames;
         firstFrame += kBlockFrames) {
        const uint32_t frameCount =
            std::min(kBlockFrames, totalFrames - firstFrame);
        const uint32_t capacity = ah_get_max_output_frames(engine, frameCount);
        std::vector<AhHapticFrame> outputs(capacity);
        AhProcessInput input{};
        input.struct_size = AH_PROCESS_INPUT_V1_SIZE;
        input.interleaved_pcm = pcm.data() + firstFrame;
        input.frame_count = frameCount;
        input.first_sample_time_us =
            static_cast<uint64_t>(firstFrame) * 1000000ULL / kSampleRate;
        uint32_t outputCount = 0U;
        const AhStatus status = ah_process_i16(
            engine, &input, outputs.data(), capacity, &outputCount);
        assert(status == AH_STATUS_OK || status == AH_STATUS_OUTPUT_AVAILABLE);
        for (uint32_t index = 0U; index < outputCount; ++index) {
            const AhHapticFrame& output = outputs[index];
            assert(output.active_scene == AH_SCENE_MUSIC);
            assert(output.continuous_amplitude <= 0.26F);
            if ((output.flags & AH_FRAME_TRANSIENT) == 0U) continue;
            if (!sawFirstTransient) {
                assert((output.flags & AH_FRAME_MUSIC_RESTART) != 0U);
                sawFirstTransient = true;
            } else {
                assert((output.flags & AH_FRAME_MUSIC_RESTART) == 0U);
                sawLaterTransient = true;
            }
        }
    }

    ah_destroy(engine);
    assert(sawFirstTransient);
    assert(sawLaterTransient);
}

void AssertGameAuthoringCrossesThePublicIrBoundary() {
    std::vector<int16_t> pcm = RenderLowRumbleNoise();
    const uint64_t rumbleEndUs =
        static_cast<uint64_t>(pcm.size() / 2U) * 1000000ULL / kSampleRate;
    pcm.resize(pcm.size() + static_cast<size_t>(kSampleRate) * 2U, 0);

    AhConfig config{};
    assert(ah_config_init(&config, kSampleRate, 2U) == AH_STATUS_OK);
    config.requested_scene = AH_SCENE_GAME;
    AhEngine* engine = nullptr;
    assert(ah_create(&config, &engine) == AH_STATUS_OK);

    bool sawContinuous = false;
    bool sawStop = false;
    uint64_t stopTimestampUs = 0U;
    const uint32_t totalFrames = static_cast<uint32_t>(pcm.size() / 2U);
    for (uint32_t firstFrame = 0U; firstFrame < totalFrames;
         firstFrame += kBlockFrames) {
        const uint32_t frameCount =
            std::min(kBlockFrames, totalFrames - firstFrame);
        const uint32_t capacity = ah_get_max_output_frames(engine, frameCount);
        std::vector<AhHapticFrame> outputs(capacity);
        AhProcessInput input{};
        input.struct_size = AH_PROCESS_INPUT_V1_SIZE;
        input.interleaved_pcm = pcm.data() +
                                static_cast<size_t>(firstFrame) * 2U;
        input.frame_count = frameCount;
        input.first_sample_time_us =
            static_cast<uint64_t>(firstFrame) * 1000000ULL / kSampleRate;
        uint32_t outputCount = 0U;
        const AhStatus status = ah_process_i16(
            engine, &input, outputs.data(), capacity, &outputCount);
        assert(status == AH_STATUS_OK || status == AH_STATUS_OUTPUT_AVAILABLE);
        for (uint32_t index = 0U; index < outputCount; ++index) {
            const AhHapticFrame& output = outputs[index];
            assert(output.active_scene == AH_SCENE_GAME);
            assert((output.flags & AH_FRAME_RHYTHM_PREDICTED) == 0U);
            assert((output.flags & AH_FRAME_MUSIC_RESTART) == 0U);
            assert(output.continuous_amplitude <= 0.24F);
            if ((output.flags & AH_FRAME_CONTINUOUS_CHANGED) != 0U &&
                output.continuous_amplitude > 0.0F) {
                sawContinuous = true;
            }
            if ((output.flags & AH_FRAME_STOP) != 0U) {
                sawStop = true;
                stopTimestampUs = output.timestamp_us;
            }
        }
    }

    ah_destroy(engine);
    assert(sawContinuous);
    assert(sawStop);
    assert(stopTimestampUs >= rumbleEndUs);
    assert(stopTimestampUs - rumbleEndUs <= 500000ULL);
}

void AssertGameRejectsSteadyHarmonicBed() {
    const std::vector<int16_t> pcm = RenderSteadyTone();
    AhConfig config{};
    assert(ah_config_init(&config, kSampleRate, 2U) == AH_STATUS_OK);
    config.requested_scene = AH_SCENE_GAME;
    AhEngine* engine = nullptr;
    assert(ah_create(&config, &engine) == AH_STATUS_OK);

    const uint32_t totalFrames = static_cast<uint32_t>(pcm.size() / 2U);
    for (uint32_t firstFrame = 0U; firstFrame < totalFrames;
         firstFrame += kBlockFrames) {
        const uint32_t frameCount =
            std::min(kBlockFrames, totalFrames - firstFrame);
        const uint32_t capacity = ah_get_max_output_frames(engine, frameCount);
        std::vector<AhHapticFrame> outputs(capacity);
        AhProcessInput input{};
        input.struct_size = AH_PROCESS_INPUT_V1_SIZE;
        input.interleaved_pcm = pcm.data() +
                                static_cast<size_t>(firstFrame) * 2U;
        input.frame_count = frameCount;
        input.first_sample_time_us =
            static_cast<uint64_t>(firstFrame) * 1000000ULL / kSampleRate;
        uint32_t outputCount = 0U;
        const AhStatus status = ah_process_i16(
            engine, &input, outputs.data(), capacity, &outputCount);
        assert(status == AH_STATUS_OK || status == AH_STATUS_OUTPUT_AVAILABLE);
        for (uint32_t index = 0U; index < outputCount; ++index) {
            assert(outputs[index].continuous_amplitude == 0.0F);
        }
    }
    ah_destroy(engine);
}

} // namespace

int main() {
    AssertCausalTiming(Process(RenderClicks(1U), 1U));
    AssertCausalTiming(Process(RenderClicks(2U), 2U));
    const std::vector<uint64_t> normalTone = Process(RenderSteadyTone(), 2U);
    const std::vector<uint64_t> sensitiveTone =
        Process(RenderSteadyTone(), 2U, 2.5F);
    // A tone fading in from silence may produce one legitimate start event,
    // but its steady carrier must never retrigger at the refractory cadence.
    assert(normalTone.size() <= 1U);
    assert(sensitiveTone.size() <= 1U);
    if (!normalTone.empty()) assert(normalTone.front() <= 100000ULL);
    if (!sensitiveTone.empty()) assert(sensitiveTone.front() <= 100000ULL);
    AssertHighSensitivityAcceptsCompressedBeat();
    AssertTactileBranchAcceptsCompressedBeat();
    AssertAospEnvelopeIsCausalAndSettles();
    AssertMusicAuthoringCrossesThePublicIrBoundary();
    AssertGameAuthoringCrossesThePublicIrBoundary();
    AssertGameRejectsSteadyHarmonicBed();
    return 0;
}
