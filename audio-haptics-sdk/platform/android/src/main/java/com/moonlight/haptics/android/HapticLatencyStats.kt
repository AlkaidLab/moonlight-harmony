// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android

import kotlin.math.ceil

data class HapticLatencySnapshot(
    val renderedCount: Int,
    val dispatchP50Us: Long,
    val dispatchP95Us: Long,
    val dispatchP99Us: Long,
    val audioSkewP50Us: Long,
    val audioSkewP95Us: Long,
    val audioSkewP99Us: Long,
    val staleTransientDrops: Long,
    val supersededTransientDrops: Long,
    val scheduledFrames: Long,
    val clockAcceptedDecisions: Long,
    val clockRejectedDecisions: Long,
    val latestClockAgeUs: Long,
    val latestStreamClockDeltaUs: Long,
    val latestRawTargetDeltaUs: Long
)

internal class HapticLatencyAccumulator(private val capacity: Int = 256) {
    private val dispatchSamples = LongArray(capacity)
    private val skewSamples = LongArray(capacity)
    private var dispatchCount = 0
    private var skewCount = 0
    private var dispatchWrite = 0
    private var skewWrite = 0
    private var staleDrops = 0L
    private var supersededDrops = 0L
    private var scheduled = 0L
    private var clockAccepted = 0L
    private var clockRejected = 0L
    private var latestClockAgeUs = 0L
    private var latestStreamClockDeltaUs = 0L
    private var latestRawTargetDeltaUs = 0L

    @Synchronized
    fun record(dispatchUs: Long, audioSkewUs: Long?) {
        dispatchSamples[dispatchWrite] = dispatchUs.coerceAtLeast(0L)
        dispatchWrite = (dispatchWrite + 1) % capacity
        dispatchCount = (dispatchCount + 1).coerceAtMost(capacity)
        if (audioSkewUs != null) {
            skewSamples[skewWrite] = audioSkewUs.coerceAtLeast(0L)
            skewWrite = (skewWrite + 1) % capacity
            skewCount = (skewCount + 1).coerceAtMost(capacity)
        }
    }

    @Synchronized
    fun recordStaleDrop() {
        staleDrops++
    }

    @Synchronized
    fun recordSupersededDrop() {
        supersededDrops++
    }

    @Synchronized
    fun recordScheduled() {
        scheduled++
    }

    @Synchronized
    fun recordClockDecision(
        accepted: Boolean,
        clockAgeUs: Long,
        streamClockDeltaUs: Long,
        rawTargetDeltaUs: Long
    ) {
        if (accepted) clockAccepted++ else clockRejected++
        latestClockAgeUs = clockAgeUs
        latestStreamClockDeltaUs = streamClockDeltaUs
        latestRawTargetDeltaUs = rawTargetDeltaUs
    }

    @Synchronized
    fun takeSnapshot(): HapticLatencySnapshot {
        val dispatch = dispatchSamples.copyOf(dispatchCount).apply { sort() }
        val skew = skewSamples.copyOf(skewCount).apply { sort() }
        val snapshot = HapticLatencySnapshot(
            renderedCount = dispatchCount,
            dispatchP50Us = percentile(dispatch, 0.50),
            dispatchP95Us = percentile(dispatch, 0.95),
            dispatchP99Us = percentile(dispatch, 0.99),
            audioSkewP50Us = percentile(skew, 0.50),
            audioSkewP95Us = percentile(skew, 0.95),
            audioSkewP99Us = percentile(skew, 0.99),
            staleTransientDrops = staleDrops,
            supersededTransientDrops = supersededDrops,
            scheduledFrames = scheduled,
            clockAcceptedDecisions = clockAccepted,
            clockRejectedDecisions = clockRejected,
            latestClockAgeUs = latestClockAgeUs,
            latestStreamClockDeltaUs = latestStreamClockDeltaUs,
            latestRawTargetDeltaUs = latestRawTargetDeltaUs
        )
        dispatchCount = 0
        skewCount = 0
        dispatchWrite = 0
        skewWrite = 0
        staleDrops = 0L
        supersededDrops = 0L
        scheduled = 0L
        clockAccepted = 0L
        clockRejected = 0L
        latestClockAgeUs = 0L
        latestStreamClockDeltaUs = 0L
        latestRawTargetDeltaUs = 0L
        return snapshot
    }

    private fun percentile(sorted: LongArray, quantile: Double): Long {
        if (sorted.isEmpty()) return 0L
        val index = (ceil(sorted.size * quantile).toInt() - 1)
            .coerceIn(0, sorted.lastIndex)
        return sorted[index]
    }
}
