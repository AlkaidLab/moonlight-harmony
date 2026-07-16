// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

enum class AndroidHapticCapabilityLevel {
    NONE,
    ON_OFF,
    AMPLITUDE,
    PRIMITIVES,
    ENVELOPE
}

data class AndroidHapticCapabilities(
    val level: AndroidHapticCapabilityLevel,
    val hasAmplitudeControl: Boolean,
    val supportsClickPrimitive: Boolean,
    val supportsThudPrimitive: Boolean
) {
    val hasVibrator: Boolean
        get() = level != AndroidHapticCapabilityLevel.NONE

    companion object {
        internal fun vibrator(context: Context): Vibrator? {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE)
                    as? VibratorManager
                manager?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
        }

        fun detect(context: Context): AndroidHapticCapabilities {
            val vibrator = vibrator(context)
            if (vibrator == null || !vibrator.hasVibrator()) {
                return AndroidHapticCapabilities(
                    AndroidHapticCapabilityLevel.NONE,
                    hasAmplitudeControl = false,
                    supportsClickPrimitive = false,
                    supportsThudPrimitive = false
                )
            }

            val amplitudeControl = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                vibrator.hasAmplitudeControl()
            var click = false
            var thud = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    val supported = vibrator.arePrimitivesSupported(
                        VibrationEffect.Composition.PRIMITIVE_CLICK,
                        VibrationEffect.Composition.PRIMITIVE_THUD
                    )
                    click = supported.getOrElse(0) { false }
                    thud = supported.getOrElse(1) { false }
                } catch (_: RuntimeException) {
                    // Vendor implementations may reject capability queries.
                }
            }

            val envelope = if (Build.VERSION.SDK_INT >= 36) {
                try {
                    vibrator.areEnvelopeEffectsSupported()
                } catch (_: RuntimeException) {
                    false
                }
            } else {
                false
            }

            val level = when {
                envelope -> AndroidHapticCapabilityLevel.ENVELOPE
                click || thud -> AndroidHapticCapabilityLevel.PRIMITIVES
                amplitudeControl -> AndroidHapticCapabilityLevel.AMPLITUDE
                else -> AndroidHapticCapabilityLevel.ON_OFF
            }
            return AndroidHapticCapabilities(level, amplitudeControl, click, thud)
        }
    }
}
