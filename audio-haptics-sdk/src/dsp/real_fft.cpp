// SPDX-License-Identifier: Apache-2.0

#include "dsp/real_fft.h"

#include <cmath>
#include <stdexcept>
#include <utility>

namespace moonlight::haptics::dsp {

namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;

bool IsPowerOfTwo(uint32_t value) noexcept {
    return value >= 2U && (value & (value - 1U)) == 0U;
}

} // namespace

RealFft::RealFft(uint32_t size)
    : size_(size),
      bitReverse_(size),
      twiddleReal_(size / 2U),
      twiddleImaginary_(size / 2U) {
    if (!IsPowerOfTwo(size_)) {
        throw std::invalid_argument("FFT size must be a power of two");
    }

    uint32_t bitCount = 0;
    for (uint32_t value = size_; value > 1U; value >>= 1U) ++bitCount;
    for (uint32_t index = 0; index < size_; ++index) {
        uint32_t source = index;
        uint32_t reversed = 0;
        for (uint32_t bit = 0; bit < bitCount; ++bit) {
            reversed = (reversed << 1U) | (source & 1U);
            source >>= 1U;
        }
        bitReverse_[index] = reversed;
    }

    for (uint32_t index = 0; index < size_ / 2U; ++index) {
        const double angle = -2.0 * kPi * static_cast<double>(index) /
                             static_cast<double>(size_);
        twiddleReal_[index] = static_cast<float>(std::cos(angle));
        twiddleImaginary_[index] = static_cast<float>(std::sin(angle));
    }
}

void RealFft::Transform(float* real, float* imaginary) const noexcept {
    for (uint32_t index = 0; index < size_; ++index) {
        const uint32_t reversed = bitReverse_[index];
        if (reversed > index) {
            std::swap(real[index], real[reversed]);
            std::swap(imaginary[index], imaginary[reversed]);
        }
    }

    for (uint32_t length = 2U; length <= size_; length <<= 1U) {
        const uint32_t half = length / 2U;
        const uint32_t twiddleStep = size_ / length;
        for (uint32_t block = 0; block < size_; block += length) {
            for (uint32_t offset = 0; offset < half; ++offset) {
                const uint32_t twiddle = offset * twiddleStep;
                const uint32_t evenIndex = block + offset;
                const uint32_t oddIndex = evenIndex + half;
                const float oddReal =
                    twiddleReal_[twiddle] * real[oddIndex] -
                    twiddleImaginary_[twiddle] * imaginary[oddIndex];
                const float oddImaginary =
                    twiddleReal_[twiddle] * imaginary[oddIndex] +
                    twiddleImaginary_[twiddle] * real[oddIndex];
                const float evenReal = real[evenIndex];
                const float evenImaginary = imaginary[evenIndex];
                real[evenIndex] = evenReal + oddReal;
                imaginary[evenIndex] = evenImaginary + oddImaginary;
                real[oddIndex] = evenReal - oddReal;
                imaginary[oddIndex] = evenImaginary - oddImaginary;
            }
        }
    }
}

} // namespace moonlight::haptics::dsp
