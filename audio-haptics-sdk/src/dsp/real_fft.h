// SPDX-License-Identifier: Apache-2.0

#ifndef MOONLIGHT_HAPTICS_DSP_REAL_FFT_H
#define MOONLIGHT_HAPTICS_DSP_REAL_FFT_H

#include <cstddef>
#include <cstdint>
#include <vector>

namespace moonlight::haptics::dsp {

class RealFft {
public:
    explicit RealFft(uint32_t size);

    uint32_t Size() const noexcept { return size_; }
    void Transform(float* real, float* imaginary) const noexcept;

private:
    uint32_t size_ = 0;
    std::vector<uint32_t> bitReverse_;
    std::vector<float> twiddleReal_;
    std::vector<float> twiddleImaginary_;
};

} // namespace moonlight::haptics::dsp

#endif // MOONLIGHT_HAPTICS_DSP_REAL_FFT_H
