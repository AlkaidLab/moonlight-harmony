#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

// Physical game-mouse motion only. Touch, absolute positioning and gamepad
// emulation must not inherit this multiplier. Caller serializes access.
class RelativeMouseMotion {
public:
    struct Delta { int16_t x; int16_t y; };

    void setSensitivity(double value)
    {
        const double next = std::isfinite(value) ? std::clamp(value, 0.1, 10.0) : 1.0;
        if (next != sensitivity_) reset();
        sensitivity_ = next;
    }

    double sensitivity() const { return sensitivity_; }
    void setAccelerationEnabled(bool enabled)
    {
        if (enabled != accelerated_) reset();
        accelerated_ = enabled;
    }

    double accelerationGain() const { return accelerationGain_; }

    void reset()
    {
        remainderX_ = remainderY_ = 0.0;
        lastMotionTimeMs_ = 0.0;
        filteredSpeed_ = 0.0;
        accelerationGain_ = 1.0;
    }

    Delta move(double x, double y, bool applySensitivity = true, int32_t deviceId = -1,
               double eventTimeMs = 0.0)
    {
        if (deviceId != lastDeviceId_ || applySensitivity != lastApplySensitivity_) reset();
        lastDeviceId_ = deviceId;
        lastApplySensitivity_ = applySensitivity;
        accelerationGain_ = accelerated_ ? motionGain(x, y, eventTimeMs) : 1.0;
        const double gain = (applySensitivity ? sensitivity_ : 1.0) * accelerationGain_;
        return {scale(x, remainderX_, gain), scale(y, remainderY_, gain)};
    }

private:
    double motionGain(double x, double y, double timeMs)
    {
        // Use input timestamps, not callback/render timing. Without a usable
        // interval we keep linear input; do not guess a velocity or drop motion.
        if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(timeMs) || timeMs <= 0.0) {
            lastMotionTimeMs_ = 0.0;
            filteredSpeed_ = 0.0;
            return 1.0;
        }
        const double elapsedMs = timeMs - lastMotionTimeMs_;
        const bool first = lastMotionTimeMs_ <= 0.0;
        lastMotionTimeMs_ = std::max(lastMotionTimeMs_, timeMs);
        if (first || elapsedMs <= 0.0 || elapsedMs > 120.0) {
            filteredSpeed_ = 0.0;
            return 1.0;
        }
        const double intervalMs = std::max(1.0, elapsedMs);
        const double speed = std::hypot(x, y) * 1000.0 / intervalMs;
        // Smooth acceleration over 25 ms, but immediately respect slowing
        // down so a fast swipe does not amplify the following fine correction.
        const double alpha = -std::expm1(-intervalMs / 25.0);
        filteredSpeed_ = speed < filteredSpeed_ ? speed :
            filteredSpeed_ + alpha * (speed - filteredSpeed_);
        // Client-defined curve in raw counts/second; not the OS desktop curve.
        // Continuous gain 1..3 with flat endpoints, independent of sensitivity.
        const double t = std::clamp((filteredSpeed_ - 120.0) / (1600.0 - 120.0), 0.0, 1.0);
        return 1.0 + 2.0 * t * t * (3.0 - 2.0 * t);
    }

    int16_t scale(double delta, double& remainder, double gain)
    {
        if (delta == 0.0) return 0; // A stationary axis must not consume its carry.
        const double scaled = delta * gain + remainder;
        if (!std::isfinite(scaled)) {
            remainder = 0.0;
            return 0;
        }
        // Symmetric rounding plus carry preserves sub-count motion in either
        // direction. Bound before narrowing to prevent int16 wrap/reversal.
        const double rounded = std::round(scaled);
        const double bounded = std::clamp(rounded, -32768.0, 32767.0);
        remainder = rounded == bounded ? scaled - rounded : 0.0;
        return static_cast<int16_t>(bounded);
    }

    double sensitivity_ = 1.0;
    double remainderX_ = 0.0;
    double remainderY_ = 0.0;
    int32_t lastDeviceId_ = -1;
    bool lastApplySensitivity_ = true;
    bool accelerated_ = false;
    double lastMotionTimeMs_ = 0.0;
    double filteredSpeed_ = 0.0;
    double accelerationGain_ = 1.0;
};
