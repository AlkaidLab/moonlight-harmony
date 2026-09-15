#ifndef MOONLIGHT_FRAME_RATE_REQUEST_H
#define MOONLIGHT_FRAME_RATE_REQUEST_H

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

// Display requests use integer Hz; stream scheduling keeps the original FPS.
// Reject invalid values before converting them to an integer.
inline int32_t FrameRateRequestHz(double fps) {
    if (!std::isfinite(fps) || fps <= 0 ||
        fps > static_cast<double>(std::numeric_limits<int32_t>::max()) - 1.0) {
        return 0;
    }
    return std::max(1, static_cast<int32_t>(std::lround(fps)));
}

// NativeDisplaySoloist's public contract limits ALL range fields to [0, 120].
// Do not cast a >120 Hz display request as a 120 Hz Soloist request: leave that
// target to ArkUI, whose range is bounded by the device's display capability.
inline int32_t DisplaySoloistRequestHz(double fps) {
    const int32_t expected = FrameRateRequestHz(fps);
    return expected <= 120 ? expected : 0;
}

#endif
