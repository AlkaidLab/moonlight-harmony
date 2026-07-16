// SPDX-License-Identifier: Apache-2.0

#include "core/music_scene_author.h"

#include <cassert>
#include <cmath>

namespace {

bool Near(float actual, float expected, float tolerance = 1.0e-5F) {
    return std::abs(actual - expected) <= tolerance;
}

void AssertGrooveGateAndHysteresis() {
    moonlight::haptics::core::MusicSceneAuthor author;

    const auto unsupported = author.Process(0.8F, 0.10F, 0.0F, false, 0U);
    assert(unsupported.continuousAmplitude == 0.0F);

    const auto started = author.Process(0.5F, 0.40F, 0.0F, false, 5000U);
    assert(started.continuousAmplitude >= 0.05F);
    assert(started.continuousAmplitude <= 0.26F);

    const auto sustained = author.Process(0.3F, 0.15F, 0.0F, false, 10000U);
    assert(sustained.continuousAmplitude >= 0.05F);

    const auto stopped = author.Process(0.07F, 0.15F, 0.0F, false, 15000U);
    assert(stopped.continuousAmplitude == 0.0F);
}

void AssertTransientGainAndRestart() {
    moonlight::haptics::core::MusicSceneAuthor author;

    const auto first = author.Process(0.0F, 0.0F, 0.4F, true, 1000000U);
    assert(first.restartTransient);
    assert(Near(first.transientAmplitude, 0.4F * 1.45F * 0.75F));

    const auto next = author.Process(0.0F, 0.0F, 0.4F, true, 1500000U);
    assert(!next.restartTransient);
    assert(Near(next.transientAmplitude, 0.4F * 1.45F));

    const auto restarted = author.Process(
        0.0F, 0.0F, 0.4F, true, 31500000U);
    assert(restarted.restartTransient);
    assert(Near(restarted.transientAmplitude, 0.4F * 1.45F * 0.75F));

    author.Reset();
    const auto afterReset = author.Process(0.0F, 0.0F, 1.0F, true, 0U);
    assert(afterReset.restartTransient);
    assert(afterReset.transientAmplitude == 1.0F);
}

} // namespace

int main() {
    AssertGrooveGateAndHysteresis();
    AssertTransientGainAndRestart();
    return 0;
}
