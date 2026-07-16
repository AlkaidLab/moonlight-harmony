// SPDX-License-Identifier: GPL-3.0-or-later

#include "audio_haptics_shadow.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <vector>

namespace {

constexpr uint32_t kSampleRate = 48000U;
constexpr uint32_t kChannels = 2U;
constexpr uint32_t kBlockFrames = 240U;

int16_t ToPcm16(float value) {
    const float clamped = std::max(-1.0F, std::min(1.0F, value));
    return static_cast<int16_t>(std::lround(clamped * 32767.0F));
}

std::vector<int16_t> RenderAntiphaseClicks() {
    const uint32_t frameCount = 125000U;
    std::vector<int16_t> pcm(static_cast<size_t>(frameCount) * kChannels, 0);
    uint32_t randomState = 20002U;
    for (uint32_t eventFrame : {24000U, 48000U, 72000U, 96000U}) {
        for (uint32_t offset = 0; offset < 480U; ++offset) {
            randomState ^= randomState << 13U;
            randomState ^= randomState >> 17U;
            randomState ^= randomState << 5U;
            const float noise = static_cast<float>(randomState & 0xffffU) /
                                    32767.5F -
                                1.0F;
            const float envelope = std::exp(
                -static_cast<float>(offset) /
                (0.003F * static_cast<float>(kSampleRate)));
            const int16_t sample = ToPcm16(0.82F * envelope * noise);
            const size_t index =
                static_cast<size_t>(eventFrame + offset) * kChannels;
            pcm[index] = sample;
            pcm[index + 1U] = static_cast<int16_t>(-sample);
        }
    }
    return pcm;
}

} // namespace

int main() {
    AudioHapticsShadowAnalyzer shadow;
    assert(shadow.Init(kSampleRate, kChannels));
    shadow.SetConfig(1.0F, AH_SCENE_GAME);
    shadow.SetEnabled(true);

    const std::vector<int16_t> pcm = RenderAntiphaseClicks();
    const uint32_t totalFrames = static_cast<uint32_t>(pcm.size() / kChannels);
    for (uint32_t firstFrame = 0; firstFrame < totalFrames;
         firstFrame += kBlockFrames) {
        const uint32_t count = std::min(kBlockFrames, totalFrames - firstFrame);
        shadow.ProcessFrame(
            pcm.data() + static_cast<size_t>(firstFrame) * kChannels, count);
    }

    AudioHapticsShadowSnapshot snapshot = shadow.GetSnapshot();
    assert(snapshot.compiled);
    assert(snapshot.enabled);
    assert(snapshot.inputBlocks > 0U);
    assert(snapshot.inputFrames == totalFrames);
    assert(snapshot.referenceEvents == 0U);
    assert(snapshot.candidateEvents == 4U);
    assert(snapshot.matchedEvents == 0U);
    assert(snapshot.referenceOnlyEvents == 0U);
    assert(snapshot.candidateOnlyEvents == 4U);
    assert(snapshot.pendingReferenceEvents == 0U);
    assert(snapshot.pendingCandidateEvents == 0U);
    assert(snapshot.processErrors == 0U);
    uint64_t histogramTotal = 0;
    for (uint64_t count : snapshot.processTimeHistogram) histogramTotal += count;
    assert(histogramTotal == snapshot.inputBlocks);

    shadow.SetEnabled(false);
    shadow.ProcessFrame(pcm.data(), kBlockFrames);
    const AudioHapticsShadowSnapshot disabled = shadow.GetSnapshot();
    assert(!disabled.enabled);
    assert(disabled.inputBlocks == snapshot.inputBlocks);
    return 0;
}
