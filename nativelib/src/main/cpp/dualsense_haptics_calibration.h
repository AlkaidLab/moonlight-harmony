#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "moonlight-common-c/src/Limelight.h"

namespace dualsense_haptics {

struct RumbleOutput {
    std::uint16_t lowFrequency;
    std::uint16_t highFrequency;
};

inline float clampUnit(float value) noexcept {
    if (!std::isfinite(value)) {
        return 0.0F;
    }
    return std::clamp(value, 0.0F, 1.0F);
}

/**
 * Fold Sunshine's device-independent DualSense IR lanes into the two motor
 * amplitudes understood by the existing Moonlight rumble path.
 *
 * The IR stream is already analyzed on the host. Keeping this conversion
 * stateless lets every valid frame stand on its own and makes packet loss
 * harmless; STREAM_END and SILENT explicitly clear the output.
 */
inline RumbleOutput renderIrV2(const LI_DS5_HAPTICS_IR_FRAME_V2& frame) noexcept {
    if ((frame.flags & LI_DS5_HAPTICS_IR_FLAG_STREAM_END) != 0U ||
        (frame.flags & LI_DS5_HAPTICS_IR_FLAG_SILENT) != 0U) {
        return {0U, 0U};
    }

    float low = 0.0F;
    float high = 0.0F;
    for (const LI_DS5_HAPTICS_IR_LANE_V2& lane : frame.lanes) {
        const float rms = clampUnit(lane.rmsAmplitude);
        const float lowBand = clampUnit(lane.lowBandRatio);
        const float transient = clampUnit(lane.transientStrength);
        low += rms * (0.35F + 0.65F * lowBand);
        high += rms * (1.0F - lowBand) * 0.65F + transient * 0.35F;
    }

    // Square-root companding preserves quiet authored details while keeping
    // two lanes within the 16-bit rumble range.
    low = std::sqrt(std::clamp(low * 0.5F, 0.0F, 1.0F));
    high = std::sqrt(std::clamp(high * 0.5F, 0.0F, 1.0F));
    return {
        static_cast<std::uint16_t>(low * 65535.0F),
        static_cast<std::uint16_t>(high * 65535.0F),
    };
}

} // namespace dualsense_haptics
