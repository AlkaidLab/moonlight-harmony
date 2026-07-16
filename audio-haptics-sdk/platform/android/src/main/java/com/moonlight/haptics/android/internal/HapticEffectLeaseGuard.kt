// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android.internal

/**
 * Invalidates delayed effect-expiry callbacks when a newer effect or an
 * explicit lifecycle stop has taken ownership of the vibrator.
 *
 * All methods are called from AndroidHapticRenderer's worker thread.
 */
internal class HapticEffectLeaseGuard {
    private var generation = 0L

    fun beginEffect(): Long = ++generation

    fun invalidate() {
        ++generation
    }

    fun tryExpire(expectedGeneration: Long): Boolean {
        if (expectedGeneration != generation) return false
        ++generation
        return true
    }
}
