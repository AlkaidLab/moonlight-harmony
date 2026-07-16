// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android.internal

import com.moonlight.haptics.HapticFrame
import com.moonlight.haptics.android.AndroidHapticCapabilityLevel
import org.junit.Assert.assertEquals
import org.junit.Test

class HapticDevicePolicyTest {
    @Test
    fun amplitudeMusicMapsRestartPredictedAndRegularTransients() {
        val restart = mapMusic(HapticFrame.FLAG_MUSIC_RESTART, 0.2f, 60f)
        assertEquals(0.58f, restart.transientAmplitude, 0.0001f)
        assertEquals(46f, restart.transientDurationMs, 0.0001f)

        val predicted = mapMusic(HapticFrame.FLAG_RHYTHM_PREDICTED, 0.2f, 48f)
        assertEquals(0.70f, predicted.transientAmplitude, 0.0001f)
        assertEquals(36f, predicted.transientDurationMs, 0.0001f)

        val regular = mapMusic(0, 0.2f, 50f)
        assertEquals(0.72f, regular.transientAmplitude, 0.0001f)
        assertEquals(40f, regular.transientDurationMs, 0.0001f)
    }

    @Test
    fun preciseMusicKeepsAmplitudeAndUsesShortDuration() {
        val intent = HapticDevicePolicy.map(
            continuousAmplitude = 0.2f,
            transientAmplitude = 0.2f,
            transientDurationMs = 50f,
            flags = HapticFrame.FLAG_TRANSIENT,
            activeScene = HapticFrame.SCENE_MUSIC,
            capabilityLevel = AndroidHapticCapabilityLevel.PRIMITIVES,
            musicContinuousGain = 0.60f
        )

        assertEquals(0.12f, intent.continuousAmplitude, 0.0001f)
        assertEquals(0.2f, intent.transientAmplitude, 0.0001f)
        assertEquals(29f, intent.transientDurationMs, 0.0001f)
    }

    @Test
    fun gameIntentIsNotReauthoredByRenderer() {
        val intent = HapticDevicePolicy.map(
            continuousAmplitude = 0.2f,
            transientAmplitude = 0.3f,
            transientDurationMs = 55f,
            flags = HapticFrame.FLAG_TRANSIENT or HapticFrame.FLAG_MUSIC_RESTART,
            activeScene = HapticFrame.SCENE_GAME,
            capabilityLevel = AndroidHapticCapabilityLevel.AMPLITUDE,
            musicContinuousGain = 0.60f
        )

        assertEquals(0.2f, intent.continuousAmplitude, 0.0001f)
        assertEquals(0.3f, intent.transientAmplitude, 0.0001f)
        assertEquals(55f, intent.transientDurationMs, 0.0001f)
    }

    private fun mapMusic(extraFlags: Int, amplitude: Float, durationMs: Float) =
        HapticDevicePolicy.map(
            continuousAmplitude = 0.2f,
            transientAmplitude = amplitude,
            transientDurationMs = durationMs,
            flags = HapticFrame.FLAG_TRANSIENT or extraFlags,
            activeScene = HapticFrame.SCENE_MUSIC,
            capabilityLevel = AndroidHapticCapabilityLevel.AMPLITUDE,
            musicContinuousGain = 0.60f
        )
}
