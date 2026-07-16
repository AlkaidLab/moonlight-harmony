// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics

/**
 * Platform-independent haptic intent emitted by moonlight-haptics-core.
 *
 * This is the Kotlin representation of the stable ABI v1 AhHapticFrame. The
 * Android renderer consumes perceptual intent and never receives PCM or DSP
 * features.
 */
data class HapticFrame(
    val timestampUs: Long,
    val flags: Int,
    val continuousAmplitude: Float,
    val transientAmplitude: Float,
    val transientDurationMs: Float,
    val sharpness: Float,
    val lowBandRatio: Float,
    val stereoPan: Float,
    val confidence: Float,
    val activeScene: Int,
    /** Leading tempo candidate; consult [rhythmLocked] before predicting beats. */
    val rhythmTempoBpm: Float = 0f,
    val rhythmConfidence: Float = 0f,
    val rhythmPhase: Float = 0f,
    val rhythmLocked: Boolean = false,
    val rhythmActivation: Float = 0f,
    val rhythmLowFrequencySupport: Float = 0f,
    /** True while tempo/phase memory is retained but predictions are muted. */
    val rhythmCoasting: Boolean = false,
    /** Android monotonic time when this IR entered the native delivery queue. */
    val producerTimeUs: Long = 0L
) {
    fun hasFlag(flag: Int): Boolean = flags and flag != 0

    companion object {
        const val ABI_V1_SIZE_BYTES = 80

        const val FLAG_CONTINUOUS_CHANGED = 1 shl 0
        const val FLAG_TRANSIENT = 1 shl 1
        const val FLAG_STOP = 1 shl 2
        const val FLAG_SCENE_CHANGED = 1 shl 3
        const val FLAG_RHYTHM_PREDICTED = 1 shl 4
        const val FLAG_MUSIC_RESTART = 1 shl 5

        const val SCENE_GAME = 0
        const val SCENE_MUSIC = 1
        const val SCENE_AUTO = 2
        const val SCENE_UNKNOWN = 3
    }
}
