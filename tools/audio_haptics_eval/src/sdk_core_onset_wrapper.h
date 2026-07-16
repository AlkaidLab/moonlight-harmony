// SPDX-License-Identifier: GPL-3.0-or-later
// Host-only adapter from the Apache-2.0 SDK C ABI to the P0 detector interface.

#ifndef AUDIO_HAPTICS_EVAL_SDK_CORE_ONSET_WRAPPER_H
#define AUDIO_HAPTICS_EVAL_SDK_CORE_ONSET_WRAPPER_H

#include "moonlight_haptics/audio_haptics.h"

#include <array>
#include <cstdint>

class SdkCoreOnsetWrapper {
public:
    SdkCoreOnsetWrapper() = default;
    ~SdkCoreOnsetWrapper() { Destroy(); }

    SdkCoreOnsetWrapper(const SdkCoreOnsetWrapper&) = delete;
    SdkCoreOnsetWrapper& operator=(const SdkCoreOnsetWrapper&) = delete;

    bool Init(int sampleRate, int hopSize, const char* method = "specflux") {
        (void)method;
        Destroy();
        if (sampleRate <= 0 || hopSize <= 0) return false;

        AhConfig config{};
        if (ah_config_init(&config,
                           static_cast<uint32_t>(sampleRate),
                           1U) != AH_STATUS_OK) {
            return false;
        }
        // The evaluator supplies the actual input channel count to ProcessFrame.
        // Recreate lazily on the first call so the public wrapper signature stays
        // compatible with the two legacy detector adapters.
        config_ = config;
        return true;
    }

    bool ProcessFrame(const int16_t* pcmData,
                      int perChannelSamples,
                      int channelCount,
                      bool& outOnsetDetected) {
        outOnsetDetected = false;
        if (pcmData == nullptr || perChannelSamples <= 0 ||
            channelCount <= 0 || channelCount > 8) {
            return false;
        }
        if (engine_ == nullptr) {
            config_.channel_count = static_cast<uint32_t>(channelCount);
            if (ah_create(&config_, &engine_) != AH_STATUS_OK) return false;
        } else if (config_.channel_count != static_cast<uint32_t>(channelCount)) {
            return false;
        }

        const uint32_t required = ah_get_max_output_frames(
            engine_, static_cast<uint32_t>(perChannelSamples));
        if (required > outputs_.size()) return false;

        AhProcessInput input{};
        input.struct_size = AH_PROCESS_INPUT_V1_SIZE;
        input.interleaved_pcm = pcmData;
        input.frame_count = static_cast<uint32_t>(perChannelSamples);
        input.first_sample_time_us =
            processedFrames_ * 1000000ULL / config_.sample_rate;

        uint32_t outputCount = 0;
        const AhStatus status = ah_process_i16(
            engine_, input.frame_count == 0 ? nullptr : &input,
            outputs_.data(), static_cast<uint32_t>(outputs_.size()), &outputCount);
        if (status != AH_STATUS_OK && status != AH_STATUS_OUTPUT_AVAILABLE) {
            return false;
        }
        processedFrames_ += input.frame_count;
        for (uint32_t i = 0; i < outputCount; ++i) {
            if ((outputs_[i].flags & AH_FRAME_TRANSIENT) != 0U) {
                outOnsetDetected = true;
                lastDescriptor_ = outputs_[i].transient_amplitude;
                lastThresholdedDescriptor_ = outputs_[i].confidence;
            }
        }
        return true;
    }

    void Reset() {
        if (engine_ != nullptr) ah_reset(engine_);
        processedFrames_ = 0;
        lastDescriptor_ = 0.0F;
        lastThresholdedDescriptor_ = 0.0F;
    }

    void Destroy() {
        ah_destroy(engine_);
        engine_ = nullptr;
        processedFrames_ = 0;
    }

    float GetDescriptor() const { return lastDescriptor_; }
    float GetThresholdedDescriptor() const { return lastThresholdedDescriptor_; }

private:
    AhEngine* engine_ = nullptr;
    AhConfig config_{};
    uint64_t processedFrames_ = 0;
    std::array<AhHapticFrame, 8> outputs_{};
    float lastDescriptor_ = 0.0F;
    float lastThresholdedDescriptor_ = 0.0F;
};

#endif // AUDIO_HAPTICS_EVAL_SDK_CORE_ONSET_WRAPPER_H
