/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2026 Moonlight/AlkaidLab
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "audio_haptics_engine.h"

#include <algorithm>
#include <cstring>

AudioHapticsEngine::~AudioHapticsEngine() {
    Cleanup();
}

uint32_t AudioHapticsEngine::FloatToBits(float value) noexcept {
    uint32_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

float AudioHapticsEngine::BitsToFloat(uint32_t value) noexcept {
    float result = 0.0F;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

bool AudioHapticsEngine::Init(uint32_t sampleRate,
                              uint32_t channelCount) noexcept {
    Cleanup();
    if (sampleRate == 0U || channelCount == 0U || channelCount > 8U) {
        return false;
    }

    sampleRate_ = sampleRate;
    channelCount_ = channelCount;

    AhConfig config{};
    if (ah_config_init(&config, sampleRate_, channelCount_) != AH_STATUS_OK) {
        Cleanup();
        return false;
    }
    config.requested_scene =
        std::min(requestedScene_.load(std::memory_order_acquire),
                 static_cast<uint32_t>(AH_SCENE_AUTO));
    config.sensitivity = std::clamp(
        BitsToFloat(requestedSensitivityBits_.load(std::memory_order_acquire)),
        0.1F, 3.0F);
    if (ah_create(&config, &engine_) != AH_STATUS_OK) {
        Cleanup();
        return false;
    }

    appliedSensitivity_ = config.sensitivity;
    appliedScene_ = config.requested_scene;
    resetRequested_.store(true, std::memory_order_release);
    return true;
}

void AudioHapticsEngine::Cleanup() noexcept {
    ah_destroy(engine_);
    engine_ = nullptr;
    sampleRate_ = 0;
    channelCount_ = 0;
    streamFrames_ = 0;
    processingEnabled_ = false;
    appliedSensitivity_ = -1.0F;
    appliedScene_ = AH_SCENE_UNKNOWN;
    resetRequested_.store(false, std::memory_order_relaxed);
}

void AudioHapticsEngine::Reset() noexcept {
    resetRequested_.store(true, std::memory_order_release);
}

void AudioHapticsEngine::SetConfig(bool enabled,
                                   float sensitivity,
                                   uint32_t scene) noexcept {
    requestedSensitivityBits_.store(
        FloatToBits(std::clamp(sensitivity, 0.1F, 3.0F)),
        std::memory_order_release);
    requestedScene_.store(
        std::min(scene, static_cast<uint32_t>(AH_SCENE_AUTO)),
        std::memory_order_release);
    const bool previous =
        requestedEnabled_.exchange(enabled, std::memory_order_acq_rel);
    if (enabled != previous) {
        resetRequested_.store(true, std::memory_order_release);
    }
}

bool AudioHapticsEngine::ApplyRequestedConfig() noexcept {
    const float sensitivity = BitsToFloat(
        requestedSensitivityBits_.load(std::memory_order_acquire));
    const uint32_t scene = requestedScene_.load(std::memory_order_acquire);
    if (sensitivity == appliedSensitivity_ && scene == appliedScene_) {
        return true;
    }

    AhConfig config{};
    if (ah_config_init(&config, sampleRate_, channelCount_) != AH_STATUS_OK) {
        return false;
    }
    config.sensitivity = sensitivity;
    config.requested_scene = scene;
    const AhStatus status = ah_update_config(engine_, &config);
    if (status != AH_STATUS_OK) {
        return false;
    }
    appliedSensitivity_ = sensitivity;
    appliedScene_ = scene;
    return true;
}

void AudioHapticsEngine::ResetOnAudioThread() noexcept {
    ah_reset(engine_);
    streamFrames_ = 0;
    processingEnabled_ = false;
}

bool AudioHapticsEngine::ProcessFrame(const int16_t* interleavedPcm,
                                      uint32_t frameCount,
                                      AhHapticFrame* outputFrames,
                                      uint32_t outputCapacity,
                                      uint32_t* outputCount) noexcept {
    if (outputCount == nullptr) return false;
    *outputCount = 0;
    if (engine_ == nullptr || interleavedPcm == nullptr || frameCount == 0U ||
        outputFrames == nullptr || outputCapacity == 0U) {
        return false;
    }

    if (resetRequested_.exchange(false, std::memory_order_acq_rel)) {
        ResetOnAudioThread();
    }
    if (!requestedEnabled_.load(std::memory_order_acquire)) {
        if (processingEnabled_) ResetOnAudioThread();
        return true;
    }
    if (!processingEnabled_) {
        ah_reset(engine_);
        streamFrames_ = 0;
        processingEnabled_ = true;
    }
    if (!ApplyRequestedConfig()) return false;

    const uint32_t required = ah_get_max_output_frames(engine_, frameCount);
    if (required == 0U || required > outputCapacity) return false;

    AhProcessInput input{};
    input.struct_size = AH_PROCESS_INPUT_V1_SIZE;
    input.interleaved_pcm = interleavedPcm;
    input.frame_count = frameCount;
    input.first_sample_time_us =
        streamFrames_ * 1000000ULL / sampleRate_;

    const AhStatus status = ah_process_i16(
        engine_, &input, outputFrames, outputCapacity, outputCount);
    if (status != AH_STATUS_OK && status != AH_STATUS_OUTPUT_AVAILABLE) {
        *outputCount = 0;
        return false;
    }
    streamFrames_ += frameCount;
    return true;
}
