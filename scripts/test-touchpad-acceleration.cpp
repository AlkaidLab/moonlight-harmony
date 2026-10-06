#include "../nativelib/src/main/cpp/relative_mouse_motion.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>

static int travel(bool accelerated, double distance, double durationMs, int hz, double sensitivity = 1.0)
{
    RelativeMouseMotion motion;
    motion.setSensitivity(sensitivity);
    motion.setAccelerationEnabled(accelerated);
    const int steps = static_cast<int>(std::round(durationMs * hz / 1000.0));
    int total = 0;
    for (int i = 1; i <= steps; ++i) {
        total += motion.move(distance / steps, 0, true, 15, 1000.0 + durationMs * i / steps).x;
    }
    return total;
}

int main()
{
    // Equal physical/raw travel: linear mode ignores swipe speed; acceleration
    // preserves fine motion and extends fast swipes without screen coordinates.
    assert(travel(false, 1000, 10000, 125) == 1000);
    assert(travel(false, 1000, 500, 125) == 1000);
    assert(travel(true, 1000, 10000, 125) == 1000);
    const int fast = travel(true, 1000, 500, 125);
    assert(fast > 2600 && fast <= 3000);
    assert(travel(true, -1000, 500, 125) == -fast);
    assert(std::abs(travel(true, 1000, 500, 125, 2) - 2 * fast) <= 1);

    // Timestamp-based speed must behave similarly after event coalescing or
    // different polling rates; it must not use "distance per callback".
    const int reference = travel(true, 1800, 2000, 125);
    for (int hz : {30, 60, 125, 250}) {
        const int result = travel(true, 1800, 2000, hz);
        assert(std::abs(result - reference) < reference * 0.04);
        std::cout << hz << " Hz travel=" << result << '\n';
    }

    RelativeMouseMotion motion;
    motion.setAccelerationEnabled(true);
    for (int i = 0; i < 50; ++i) motion.move(16, 0, true, 15, 1000 + 8 * i);
    assert(motion.accelerationGain() > 2.9);
    auto d = motion.move(0.5, 0, true, 15, 1400);
    assert(d.x >= 0 && d.x <= 1); // Fine correction immediately leaves high gain.
    assert(motion.accelerationGain() == 1);
    d = motion.move(1, 0, true, 15, 1700); // Pause/lift: no retained velocity.
    assert(d.x == 1 && motion.accelerationGain() == 1);

    for (int i = 0; i < 50; ++i) motion.move(16, 0, true, 15, 1800 + 8 * i);
    d = motion.move(1, 0, true, 16, 2200); // Device change clears velocity.
    assert(d.x == 1 && motion.accelerationGain() == 1);
    motion.setAccelerationEnabled(false);
    motion.setSensitivity(5);
    d = motion.move(7, -9, true, 20, 2208); // Mouse keeps constant raw gain.
    assert(d.x == 35 && d.y == -45);

    motion.setSensitivity(1);
    motion.setAccelerationEnabled(true);
    // Missing/repeated/out-of-order timestamps retain usable linear motion.
    int sum = 0;
    for (int i = 0; i < 10; ++i) sum += motion.move(0.2, 0, true, 15, 0).x;
    assert(sum == 2);
    motion.move(1, 0, true, 15, 3000);
    assert(motion.move(1, 0, true, 15, 3000).x == 1);
    assert(motion.move(1, 0, true, 15, 2999).x == 1);
    assert(motion.accelerationGain() == 1);
    d = motion.move(std::numeric_limits<double>::quiet_NaN(),
                    std::numeric_limits<double>::infinity(), true, 15, 3010);
    assert(d.x == 0 && d.y == 0);
    motion.reset();
    d = motion.move(1, -1, true, 15, 4000);
    assert(d.x == 1 && d.y == -1);
    std::cout << "Touchpad acceleration tests passed; fast swipe=" << fast << " / raw=1000\n";
}
