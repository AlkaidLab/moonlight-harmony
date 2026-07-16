// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android.internal

internal data class HapticDeviceProfile(
    val id: String,
    val musicContinuousGain: Float,
    val musicContinuousMaximumHoldMs: Long?
)

/** Explicit, opt-out profiles backed by measured actuator-service behavior. */
internal object HapticDeviceProfiles {
    fun resolve(
        manufacturer: String?,
        model: String?,
        enabled: Boolean
    ): HapticDeviceProfile {
        if (!enabled) return DEFAULT
        return if (
            manufacturer.equals("OPPO", ignoreCase = true) &&
            model.equals("PKJ110", ignoreCase = true)
        ) {
            OPPO_PKJ110
        } else {
            DEFAULT
        }
    }

    private val DEFAULT = HapticDeviceProfile(
        id = "default",
        musicContinuousGain = 1f,
        musicContinuousMaximumHoldMs = null
    )
    private val OPPO_PKJ110 = HapticDeviceProfile(
        id = "oplus-pkj110-media-v4",
        // OPlus vibrator history shows USAGE_MEDIA beds near 0.15/0.26 being
        // rendered near 0.31/0.50, compressing contrast against transients.
        musicContinuousGain = 0.60f,
        // OPlus converts every finite amplitude step into a 45 ms prebaked
        // click. Use its real continuous repeat path, then bound the lease in
        // the Renderer so the bed cannot run indefinitely.
        musicContinuousMaximumHoldMs = 220L
    )
}
