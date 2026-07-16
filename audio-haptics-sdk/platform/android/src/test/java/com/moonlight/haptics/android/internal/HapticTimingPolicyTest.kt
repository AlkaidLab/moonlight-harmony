// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android.internal

import com.moonlight.haptics.HapticFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HapticTimingPolicyTest {
    @Test
    fun schedulesAgainstAudioPresentationWithActuatorLead() {
        val decision = HapticTimingPolicy.decide(
            nowUs = 2_000_000L,
            producerTimeUs = 1_999_000L,
            streamTimestampUs = 1_020_000L,
            clockFramePosition = 48_000L,
            clockSystemTimeUs = 2_000_000L,
            sampleRate = 48_000,
            actuatorLeadUs = 10_000L,
            staleDeadlineUs = 25_000L,
            maximumScheduleAheadUs = 100_000L
        )

        assertEquals(2_010_000L, decision.targetVibrateTimeUs)
        assertEquals(10_000L, decision.delayUs)
        assertFalse(decision.dropTransient)
    }

    @Test
    fun dropsTransientThatMissedAudioDeadline() {
        val decision = HapticTimingPolicy.decide(
            nowUs = 2_040_001L,
            producerTimeUs = 2_039_000L,
            streamTimestampUs = 1_020_000L,
            clockFramePosition = 48_000L,
            clockSystemTimeUs = 2_000_000L,
            sampleRate = 48_000,
            actuatorLeadUs = 10_000L,
            staleDeadlineUs = 25_000L,
            maximumScheduleAheadUs = 100_000L
        )

        assertTrue(decision.dropTransient)
        assertEquals(0L, decision.delayUs)
    }

    @Test
    fun fallsBackToProducerAgeWithoutPresentationClock() {
        val decision = HapticTimingPolicy.decide(
            nowUs = 1_030_001L,
            producerTimeUs = 1_000_000L,
            streamTimestampUs = 10_000L,
            clockFramePosition = -1L,
            clockSystemTimeUs = -1L,
            sampleRate = 0,
            actuatorLeadUs = 10_000L,
            staleDeadlineUs = 25_000L,
            maximumScheduleAheadUs = 100_000L
        )

        assertNull(decision.targetVibrateTimeUs)
        assertTrue(decision.dropTransient)
    }

    @Test
    fun rejectsClockThatSchedulesImplausiblyFarAhead() {
        val decision = HapticTimingPolicy.decide(
            nowUs = 1_000_000L,
            producerTimeUs = 999_000L,
            streamTimestampUs = 1_500_000L,
            clockFramePosition = 48_000L,
            clockSystemTimeUs = 1_000_000L,
            sampleRate = 48_000,
            actuatorLeadUs = 10_000L,
            staleDeadlineUs = 25_000L,
            maximumScheduleAheadUs = 100_000L
        )

        assertNull(decision.targetVibrateTimeUs)
        assertEquals(0L, decision.delayUs)
        assertFalse(decision.dropTransient)
    }

    @Test
    fun rejectsClockWithMismatchedStreamOriginFarBehind() {
        val decision = HapticTimingPolicy.decide(
            nowUs = 2_000_000L,
            producerTimeUs = 1_999_000L,
            streamTimestampUs = 20_000L,
            clockFramePosition = 96_000L,
            clockSystemTimeUs = 2_000_000L,
            sampleRate = 48_000,
            actuatorLeadUs = 10_000L,
            staleDeadlineUs = 25_000L,
            maximumScheduleAheadUs = 100_000L
        )

        assertNull(decision.targetVibrateTimeUs)
        assertEquals(0L, decision.delayUs)
        assertFalse(decision.dropTransient)
    }

    @Test
    fun latestTransientWinsButStopIsNeverSuppressed() {
        val late = HapticTimingDecision(
            delayUs = 0L,
            dropTransient = true,
            targetVibrateTimeUs = null
        )
        assertTrue(
            HapticTimingPolicy.shouldSuppressTransient(
                HapticFrame.FLAG_TRANSIENT,
                late,
                hasNewerTransient = false
            )
        )
        assertTrue(
            HapticTimingPolicy.shouldSuppressTransient(
                HapticFrame.FLAG_TRANSIENT,
                late.copy(dropTransient = false),
                hasNewerTransient = true
            )
        )
        assertFalse(
            HapticTimingPolicy.shouldSuppressTransient(
                HapticFrame.FLAG_TRANSIENT or HapticFrame.FLAG_STOP,
                late,
                hasNewerTransient = true
            )
        )

        val scheduledBeat = HapticTimingDecision(
            delayUs = 10_000L,
            dropTransient = false,
            targetVibrateTimeUs = 2_010_000L
        )
        assertFalse(
            HapticTimingPolicy.shouldSuppressTransient(
                HapticFrame.FLAG_TRANSIENT,
                scheduledBeat,
                hasNewerTransient = true
            )
        )
    }

    @Test
    fun acceptsBluetoothSizedPresentationLeadWithinConfiguredWindow() {
        val decision = HapticTimingPolicy.decide(
            nowUs = 2_000_000L,
            producerTimeUs = 1_999_000L,
            streamTimestampUs = 1_303_000L,
            clockFramePosition = 48_000L,
            clockSystemTimeUs = 2_000_000L,
            sampleRate = 48_000,
            actuatorLeadUs = 10_000L,
            staleDeadlineUs = 25_000L,
            maximumScheduleAheadUs = 500_000L
        )

        assertEquals(2_293_000L, decision.targetVibrateTimeUs)
        assertEquals(293_000L, decision.delayUs)
        assertFalse(decision.dropTransient)
    }
}
