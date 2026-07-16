// SPDX-License-Identifier: GPL-3.0-or-later

#include "audio_haptics_shadow.h"

#include <cassert>
#include <cstdint>

int main() {
    AudioHapticsShadowAnalyzer shadow;
    assert(!shadow.Init(48000U, 2U));
    shadow.SetEnabled(true);
    const int16_t pcm[480]{};
    shadow.ProcessFrame(pcm, 240U);
    const AudioHapticsShadowSnapshot snapshot = shadow.GetSnapshot();
    assert(!snapshot.compiled);
    assert(!snapshot.enabled);
    assert(snapshot.inputBlocks == 0U);
    assert(snapshot.inputFrames == 0U);
    return 0;
}
