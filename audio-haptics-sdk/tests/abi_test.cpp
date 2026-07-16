// SPDX-License-Identifier: Apache-2.0

#include "moonlight_haptics/audio_haptics.h"

#include <cstddef>
#include <cstdint>
#include <type_traits>

static_assert(std::is_standard_layout<AhConfig>::value, "AhConfig must be standard-layout");
static_assert(std::is_standard_layout<AhProcessInput>::value,
              "AhProcessInput must be standard-layout");
static_assert(std::is_standard_layout<AhHapticFrame>::value,
              "AhHapticFrame must be standard-layout");

static_assert(sizeof(AhStatus) == 4, "AhStatus must have a fixed 32-bit ABI");
static_assert(sizeof(AhScene) == 4, "AhScene must have a fixed 32-bit ABI");
static_assert(sizeof(AhFrameFlags) == 4, "AhFrameFlags must have a fixed 32-bit ABI");
static_assert(AH_FRAME_RHYTHM_PREDICTED == (1u << 4),
              "rhythm prediction flag changed");
static_assert(AH_FRAME_MUSIC_RESTART == (1u << 5),
              "music restart flag changed");
static_assert(sizeof(AhConfig) == 60, "AhConfig ABI v1 changed");
static_assert(sizeof(AhHapticFrame) == 80, "AhHapticFrame ABI v1 changed");
static_assert(offsetof(AhHapticFrame, timestamp_us) == 8, "timestamp offset changed");
static_assert(offsetof(AhHapticFrame, continuous_amplitude) == 16,
              "continuous amplitude offset changed");
static_assert(offsetof(AhHapticFrame, active_scene) == 44, "scene offset changed");
static_assert(offsetof(AhHapticFrame, reserved) == 48, "reserved offset changed");

int main() {
    return AH_HAPTIC_FRAME_V1_SIZE == 80u && AH_CONFIG_V1_SIZE == 60u ? 0 : 1;
}
