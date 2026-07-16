// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android

/** Device-level throttling and fallback parameters, independent of app policy. */
data class HapticRenderConfig(
    val minimumAmplitude: Float = 0.05f,
    val continuousAmplitudeHysteresis: Float = 0.08f,
    val transientMinimumIntervalMs: Long = 12L,
    val continuousMinimumIntervalMs: Long = 100L,
    val minimumTransientDurationMs: Long = 20L,
    val maximumTransientDurationMs: Long = 120L,
    val continuousSegmentMs: Long = 1_000L,
    val queueCapacity: Int = 64,
    val actuatorLeadMs: Long = 10L,
    val transientStaleDeadlineMs: Long = 25L,
    val maximumScheduleAheadMs: Long = 500L,
    val enableDeviceProfiles: Boolean = true
) {
    init {
        require(minimumAmplitude in 0f..1f)
        require(continuousAmplitudeHysteresis in 0f..1f)
        require(transientMinimumIntervalMs >= 0L)
        require(continuousMinimumIntervalMs >= 0L)
        require(minimumTransientDurationMs > 0L)
        require(maximumTransientDurationMs >= minimumTransientDurationMs)
        require(continuousSegmentMs > 0L)
        require(actuatorLeadMs >= 0L)
        require(transientStaleDeadlineMs > 0L)
        require(maximumScheduleAheadMs >= actuatorLeadMs)
        require(queueCapacity >= 2 && queueCapacity and (queueCapacity - 1) == 0) {
            "queueCapacity must be a power of two"
        }
    }
}
