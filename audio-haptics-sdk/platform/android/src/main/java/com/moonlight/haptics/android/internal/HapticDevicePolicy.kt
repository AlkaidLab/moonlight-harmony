// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android.internal

import com.moonlight.haptics.HapticFrame
import com.moonlight.haptics.android.AndroidHapticCapabilityLevel

internal data class DeviceHapticIntent(
    val continuousAmplitude: Float,
    val transientAmplitude: Float,
    val transientDurationMs: Float
)

/** Maps portable scene intent to actuator-class amplitude and duration bounds. */
internal object HapticDevicePolicy {
    fun map(
        continuousAmplitude: Float,
        transientAmplitude: Float,
        transientDurationMs: Float,
        flags: Int,
        activeScene: Int,
        capabilityLevel: AndroidHapticCapabilityLevel,
        musicContinuousGain: Float
    ): DeviceHapticIntent {
        val continuous = continuousAmplitude.coerceIn(0f, 1f)
        val amplitude = transientAmplitude.coerceIn(0f, 1f)
        val mappedContinuous = if (activeScene == HapticFrame.SCENE_MUSIC) {
            (continuous * musicContinuousGain).coerceIn(0f, 1f)
        } else {
            continuous
        }
        val hasTransient = flags and HapticFrame.FLAG_TRANSIENT != 0
        if (!hasTransient || activeScene != HapticFrame.SCENE_MUSIC) {
            return DeviceHapticIntent(mappedContinuous, amplitude, transientDurationMs)
        }

        val preciseActuator = capabilityLevel == AndroidHapticCapabilityLevel.PRIMITIVES ||
            capabilityLevel == AndroidHapticCapabilityLevel.ENVELOPE
        val predicted = flags and HapticFrame.FLAG_RHYTHM_PREDICTED != 0
        val restart = flags and HapticFrame.FLAG_MUSIC_RESTART != 0

        val duration = when {
            preciseActuator -> (transientDurationMs * PRECISE_DURATION_SCALE)
                .coerceIn(PRECISE_MIN_DURATION_MS, PRECISE_MAX_DURATION_MS)
            predicted -> (transientDurationMs * RHYTHM_DURATION_SCALE)
                .coerceIn(RHYTHM_MIN_DURATION_MS, RHYTHM_MAX_DURATION_MS)
            else -> (transientDurationMs * ONE_SHOT_DURATION_SCALE)
                .coerceIn(ONE_SHOT_MIN_DURATION_MS, ONE_SHOT_MAX_DURATION_MS)
        }
        val minimumAmplitude = when {
            preciseActuator -> 0f
            restart -> RESTART_MIN_AMPLITUDE
            predicted -> RHYTHM_MIN_AMPLITUDE
            else -> ONE_SHOT_MIN_AMPLITUDE
        }
        return DeviceHapticIntent(
            continuousAmplitude = mappedContinuous,
            transientAmplitude = amplitude.coerceAtLeast(minimumAmplitude),
            transientDurationMs = duration
        )
    }

    private const val RESTART_MIN_AMPLITUDE = 0.58f
    private const val ONE_SHOT_MIN_AMPLITUDE = 0.72f
    private const val RHYTHM_MIN_AMPLITUDE = 0.70f
    private const val ONE_SHOT_DURATION_SCALE = 0.78f
    private const val ONE_SHOT_MIN_DURATION_MS = 40f
    private const val ONE_SHOT_MAX_DURATION_MS = 46f
    private const val RHYTHM_DURATION_SCALE = 0.75f
    private const val RHYTHM_MIN_DURATION_MS = 36f
    private const val RHYTHM_MAX_DURATION_MS = 42f
    private const val PRECISE_DURATION_SCALE = 0.58f
    private const val PRECISE_MIN_DURATION_MS = 28f
    private const val PRECISE_MAX_DURATION_MS = 34f
}
