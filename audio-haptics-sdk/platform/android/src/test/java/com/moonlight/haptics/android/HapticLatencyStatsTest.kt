// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android

import org.junit.Assert.assertEquals
import org.junit.Test

class HapticLatencyStatsTest {
    @Test
    fun reportsNearestRankPercentilesAndResetsWindow() {
        val stats = HapticLatencyAccumulator(capacity = 32)
        for (sample in 1L..20L) {
            stats.record(dispatchUs = sample, audioSkewUs = sample * 10L)
        }
        stats.recordStaleDrop()
        stats.recordSupersededDrop()
        stats.recordScheduled()
        stats.recordClockDecision(
            accepted = false,
            clockAgeUs = 20_000L,
            streamClockDeltaUs = 150_000L,
            rawTargetDeltaUs = 120_000L
        )

        val snapshot = stats.takeSnapshot()
        assertEquals(20, snapshot.renderedCount)
        assertEquals(10L, snapshot.dispatchP50Us)
        assertEquals(19L, snapshot.dispatchP95Us)
        assertEquals(20L, snapshot.dispatchP99Us)
        assertEquals(100L, snapshot.audioSkewP50Us)
        assertEquals(190L, snapshot.audioSkewP95Us)
        assertEquals(200L, snapshot.audioSkewP99Us)
        assertEquals(1L, snapshot.staleTransientDrops)
        assertEquals(1L, snapshot.supersededTransientDrops)
        assertEquals(1L, snapshot.scheduledFrames)
        assertEquals(0L, snapshot.clockAcceptedDecisions)
        assertEquals(1L, snapshot.clockRejectedDecisions)
        assertEquals(20_000L, snapshot.latestClockAgeUs)
        assertEquals(150_000L, snapshot.latestStreamClockDeltaUs)
        assertEquals(120_000L, snapshot.latestRawTargetDeltaUs)

        val empty = stats.takeSnapshot()
        assertEquals(0, empty.renderedCount)
        assertEquals(0L, empty.dispatchP99Us)
        assertEquals(0L, empty.staleTransientDrops)
    }
}
