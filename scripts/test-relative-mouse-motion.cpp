#include "../nativelib/src/main/cpp/relative_mouse_motion.h"
#include <cassert>
#include <iostream>
#include <limits>

int main()
{
    RelativeMouseMotion motion;
    auto d = motion.move(17, -23);
    assert(d.x == 17 && d.y == -23); // 1x preserves integer hardware deltas.
    motion.setSensitivity(5);
    d = motion.move(17, -23);
    assert(d.x == 85 && d.y == -115);

    // Tiny movements must accumulate instead of being rounded away per event.
    for (double gain : {0.1, 0.7, 1.0, 2.3, 5.0, 10.0}) {
        motion.setSensitivity(gain);
        motion.reset();
        int x = 0, y = 0;
        for (int i = 0; i < 1000; ++i) {
            d = motion.move(0.17, -0.13);
            x += d.x; y += d.y;
        }
        assert(std::abs(x - 170 * gain) <= 0.500001);
        assert(std::abs(y + 130 * gain) <= 0.500001);
    }

    motion.setSensitivity(1);
    motion.reset();
    d = motion.move(0.5, -0.5);
    assert(d.x == 1 && d.y == -1); // Symmetric half-count rounding.
    d = motion.move(0, 1);
    assert(d.x == 0); // Other-axis motion must not produce an X-axis reversal.
    motion.reset();
    d = motion.move(-0.5, 0.5);
    assert(d.x == -1 && d.y == 1);

    motion.reset();
    motion.move(0.4, 0.4);
    motion.reset(); // Menu/focus/stream lifecycle clears carry.
    d = motion.move(0.2, 0.2);
    assert(d.x == 0 && d.y == 0);
    motion.setSensitivity(2); // A sensitivity change also clears carry.
    d = motion.move(0.2, 0.2);
    assert(d.x == 0 && d.y == 0);

    motion.setSensitivity(10);
    d = motion.move(100000, -100000);
    assert(d.x == 32767 && d.y == -32768); // Never wrap and reverse direction.
    d = motion.move(0.1, -0.1);
    assert(d.x == 1 && d.y == -1); // No delayed backlog after saturation.
    d = motion.move(std::numeric_limits<double>::quiet_NaN(),
                    std::numeric_limits<double>::infinity());
    assert(d.x == 0 && d.y == 0);

    motion.setSensitivity(std::numeric_limits<double>::quiet_NaN());
    assert(motion.sensitivity() == 1);
    motion.setSensitivity(100);
    assert(motion.sensitivity() == 10);
    motion.setSensitivity(-1);
    assert(motion.sensitivity() == 0.1);

    motion.setSensitivity(5);
    d = motion.move(7, -9, true, 20); // External mouse.
    assert(d.x == 35 && d.y == -45);
    d = motion.move(7, -9, false, 15); // Touchpad keeps original speed.
    assert(d.x == 7 && d.y == -9);
    d = motion.move(7, -9, false, -1); // Unidentified/native monitor input.
    assert(d.x == 7 && d.y == -9);
    motion.move(0.08, 0, true, 20); // 0.4 fractional count from mouse.
    d = motion.move(0.2, 0, false, 15);
    assert(d.x == 0); // The touchpad must not inherit the mouse's remainder.
    d = motion.move(0.08, 0, true, 21);
    assert(d.x == 0); // Neither may another mouse inherit its remainder.
    d = motion.move(0.2, 0, false, 21);
    assert(d.x == 0); // Reclassification of the same ID resets the carry too.
    motion.setSensitivity(2); // Explicit touchpad multiplier selected by ArkTS.
    d = motion.move(7, -9, true, 15);
    assert(d.x == 14 && d.y == -18);
    motion.setSensitivity(5);
    d = motion.move(7, -9, true, 20);
    assert(d.x == 35 && d.y == -45);
    motion.setSensitivity(1); // Touchpad switch disabled, preserved mouse setting is 5x.
    d = motion.move(7, -9, true, 15);
    assert(d.x == 7 && d.y == -9);
    std::cout << "Relative mouse motion tests passed\n";
}
