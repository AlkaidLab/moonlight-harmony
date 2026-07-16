// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android.internal

import org.junit.Assert.assertEquals
import org.junit.Test

class HapticDeviceProfileTest {
    @Test
    fun verifiedOppoModelGetsMeasuredMediaCompensation() {
        val profile = HapticDeviceProfiles.resolve("oppo", "pkj110", enabled = true)

        assertEquals("oplus-pkj110-media-v4", profile.id)
        assertEquals(0.60f, profile.musicContinuousGain, 0.0001f)
        assertEquals(220L, profile.musicContinuousMaximumHoldMs)
    }

    @Test
    fun unknownOrDisabledDeviceUsesNeutralProfile() {
        val unknown = HapticDeviceProfiles.resolve("OPPO", "OTHER", enabled = true)
        val disabled = HapticDeviceProfiles.resolve("OPPO", "PKJ110", enabled = false)

        assertEquals("default", unknown.id)
        assertEquals(1f, unknown.musicContinuousGain, 0.0001f)
        assertEquals(null, unknown.musicContinuousMaximumHoldMs)
        assertEquals("default", disabled.id)
        assertEquals(1f, disabled.musicContinuousGain, 0.0001f)
        assertEquals(null, disabled.musicContinuousMaximumHoldMs)
    }
}
