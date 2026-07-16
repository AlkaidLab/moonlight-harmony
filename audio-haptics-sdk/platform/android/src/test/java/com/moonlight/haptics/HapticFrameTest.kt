// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HapticFrameTest {
    @Test
    fun flagsMatchNativeAbi() {
        val frame = HapticFrame(
            timestampUs = 123L,
            flags = HapticFrame.FLAG_TRANSIENT or
                HapticFrame.FLAG_SCENE_CHANGED or
                HapticFrame.FLAG_RHYTHM_PREDICTED or
                HapticFrame.FLAG_MUSIC_RESTART,
            continuousAmplitude = 0f,
            transientAmplitude = 0.8f,
            transientDurationMs = 40f,
            sharpness = 0.7f,
            lowBandRatio = 0.2f,
            stereoPan = 0f,
            confidence = 0.9f,
            activeScene = HapticFrame.SCENE_MUSIC
        )

        assertTrue(frame.hasFlag(HapticFrame.FLAG_TRANSIENT))
        assertTrue(frame.hasFlag(HapticFrame.FLAG_SCENE_CHANGED))
        assertTrue(frame.hasFlag(HapticFrame.FLAG_RHYTHM_PREDICTED))
        assertTrue(frame.hasFlag(HapticFrame.FLAG_MUSIC_RESTART))
        assertFalse(frame.hasFlag(HapticFrame.FLAG_STOP))
    }
}
