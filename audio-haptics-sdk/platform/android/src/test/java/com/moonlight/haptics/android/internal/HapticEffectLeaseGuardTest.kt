// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android.internal

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HapticEffectLeaseGuardTest {
    @Test
    fun currentLeaseExpiresOnlyOnce() {
        val guard = HapticEffectLeaseGuard()
        val lease = guard.beginEffect()

        assertTrue(guard.tryExpire(lease))
        assertFalse(guard.tryExpire(lease))
    }

    @Test
    fun newerEffectProtectsItselfFromOlderLease() {
        val guard = HapticEffectLeaseGuard()
        val oldLease = guard.beginEffect()
        val currentLease = guard.beginEffect()

        assertFalse(guard.tryExpire(oldLease))
        assertTrue(guard.tryExpire(currentLease))
    }

    @Test
    fun lifecycleStopInvalidatesPendingLease() {
        val guard = HapticEffectLeaseGuard()
        val lease = guard.beginEffect()

        guard.invalidate()

        assertFalse(guard.tryExpire(lease))
    }
}
