#include "frame_rate_request.h"
#include <cassert>
#include <limits>

int main() {
    // Fractional stream timing remains separate from integer display requests.
    assert(FrameRateRequestHz(59.94) == 60);
    assert(FrameRateRequestHz(119.88) == 120);
    for (double fps : {60.0, 90.0, 120.0, 144.0, 165.0, 240.0}) {
        const int expected = FrameRateRequestHz(fps);
        assert(expected > 0);
        assert(expected == fps);
    }
    // Check the public API's upper bound, not just min <= expected <= max.
    assert(DisplaySoloistRequestHz(90) == 90);
    assert(DisplaySoloistRequestHz(119.88) == 120);
    assert(DisplaySoloistRequestHz(120) == 120);
    assert(DisplaySoloistRequestHz(144) == 0);
    assert(DisplaySoloistRequestHz(165) == 0);
    assert(DisplaySoloistRequestHz(240) == 0);
    assert(DisplaySoloistRequestHz(0) == 0);
    assert(DisplaySoloistRequestHz(-120) == 0);
    assert(DisplaySoloistRequestHz(std::numeric_limits<double>::quiet_NaN()) == 0);
    assert(DisplaySoloistRequestHz(std::numeric_limits<double>::infinity()) == 0);
    assert(FrameRateRequestHz(0) == 0);
    assert(FrameRateRequestHz(-120) == 0);
    assert(FrameRateRequestHz(std::numeric_limits<double>::quiet_NaN()) == 0);
    assert(FrameRateRequestHz(std::numeric_limits<double>::infinity()) == 0);
    assert(FrameRateRequestHz(1e20) == 0);
    assert(FrameRateRequestHz(2147483647.0) == 0);
}
