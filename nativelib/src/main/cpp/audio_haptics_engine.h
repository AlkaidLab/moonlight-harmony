/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2026 Moonlight/AlkaidLab
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef AUDIO_HAPTICS_ENGINE_H
#define AUDIO_HAPTICS_ENGINE_H

#include <atomic>
#include <cstdint>

#include "moonlight_haptics/audio_haptics.h"

/**
 * Thin host adapter around the portable audio-haptics SDK.
 *
 * Engine ownership and PCM processing stay on the audio decode thread.
 * Settings are published from the ArkTS/N-API thread through atomics and
 * applied at the next PCM block boundary.
 */
class AudioHapticsEngine {
public:
    AudioHapticsEngine() = default;
    ~AudioHapticsEngine();

    AudioHapticsEngine(const AudioHapticsEngine&) = delete;
    AudioHapticsEngine& operator=(const AudioHapticsEngine&) = delete;

    bool Init(uint32_t sampleRate, uint32_t channelCount) noexcept;
    void Cleanup() noexcept;
    void Reset() noexcept;
    void SetConfig(bool enabled, float sensitivity, uint32_t scene) noexcept;

    bool ProcessFrame(const int16_t* interleavedPcm,
                      uint32_t frameCount,
                      AhHapticFrame* outputFrames,
                      uint32_t outputCapacity,
                      uint32_t* outputCount) noexcept;

private:
    static uint32_t FloatToBits(float value) noexcept;
    static float BitsToFloat(uint32_t value) noexcept;
    bool ApplyRequestedConfig() noexcept;
    void ResetOnAudioThread() noexcept;

    AhEngine* engine_ = nullptr;
    uint32_t sampleRate_ = 0;
    uint32_t channelCount_ = 0;
    uint64_t streamFrames_ = 0;
    bool processingEnabled_ = false;
    float appliedSensitivity_ = -1.0F;
    uint32_t appliedScene_ = AH_SCENE_UNKNOWN;

    std::atomic<bool> requestedEnabled_{false};
    // IEEE-754 representation of 1.0F. Keeping the requested value in the
    // object means reconnects preserve settings already published by ArkTS.
    std::atomic<uint32_t> requestedSensitivityBits_{0x3F800000U};
    std::atomic<uint32_t> requestedScene_{AH_SCENE_GAME};
    std::atomic<bool> resetRequested_{false};
};

#endif // AUDIO_HAPTICS_ENGINE_H
