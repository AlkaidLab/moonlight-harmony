// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android.internal

import com.moonlight.haptics.HapticFrame
import kotlin.math.abs
import kotlin.math.max

internal data class HapticTimingDecision(
    val delayUs: Long,
    val dropTransient: Boolean,
    val targetVibrateTimeUs: Long?,
    val rawTargetVibrateTimeUs: Long? = targetVibrateTimeUs
)

/** Pure timing policy shared by the Android renderer and host unit tests. */
internal object HapticTimingPolicy {
    fun decide(
        nowUs: Long,
        producerTimeUs: Long,
        streamTimestampUs: Long,
        clockFramePosition: Long,
        clockSystemTimeUs: Long,
        sampleRate: Int,
        actuatorLeadUs: Long,
        staleDeadlineUs: Long,
        maximumScheduleAheadUs: Long
    ): HapticTimingDecision {
        val rawTargetVibrateTimeUs = presentationTargetUs(
            streamTimestampUs,
            clockFramePosition,
            clockSystemTimeUs,
            sampleRate,
            actuatorLeadUs
        )
        val targetVibrateTimeUs = rawTargetVibrateTimeUs
            ?.takeIf { target -> abs(target - nowUs) <= maximumScheduleAheadUs }

        if (targetVibrateTimeUs != null) {
            val delayUs = max(0L, targetVibrateTimeUs - nowUs)
            return HapticTimingDecision(
                delayUs = delayUs,
                dropTransient = nowUs - targetVibrateTimeUs > staleDeadlineUs,
                targetVibrateTimeUs = targetVibrateTimeUs,
                rawTargetVibrateTimeUs = rawTargetVibrateTimeUs
            )
        }

        val producerAgeUs = if (producerTimeUs > 0L) {
            max(0L, nowUs - producerTimeUs)
        } else {
            0L
        }
        return HapticTimingDecision(
            delayUs = 0L,
            dropTransient = producerAgeUs > staleDeadlineUs,
            targetVibrateTimeUs = null,
            rawTargetVibrateTimeUs = rawTargetVibrateTimeUs
        )
    }

    fun shouldSuppressTransient(
        flags: Int,
        timing: HapticTimingDecision,
        hasNewerTransient: Boolean
    ): Boolean {
        val transient = flags and HapticFrame.FLAG_TRANSIENT != 0
        val stop = flags and HapticFrame.FLAG_STOP != 0
        // A newer queued transient only supersedes a frame on the immediate
        // fallback path. With an accepted presentation clock, both transients
        // may be valid future beats and must keep their individual deadlines.
        val supersededFallback = hasNewerTransient && timing.targetVibrateTimeUs == null
        return transient && !stop && (timing.dropTransient || supersededFallback)
    }

    private fun presentationTargetUs(
        streamTimestampUs: Long,
        clockFramePosition: Long,
        clockSystemTimeUs: Long,
        sampleRate: Int,
        actuatorLeadUs: Long
    ): Long? {
        if (streamTimestampUs < 0L || clockFramePosition < 0L ||
            clockSystemTimeUs < 0L || sampleRate <= 0) {
            return null
        }
        val clockStreamTimeUs = clockFramePosition * 1_000_000L / sampleRate
        val presentationTimeUs = clockSystemTimeUs +
            (streamTimestampUs - clockStreamTimeUs)
        return presentationTimeUs - actuatorLeadUs
    }
}
