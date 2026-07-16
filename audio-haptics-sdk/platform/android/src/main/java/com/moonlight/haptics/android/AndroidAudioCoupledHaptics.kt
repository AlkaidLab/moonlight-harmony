// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android

import android.annotation.TargetApi
import android.media.AudioAttributes
import android.media.AudioTrack
import android.media.audiofx.AudioEffect
import android.media.audiofx.HapticGenerator
import android.os.Build
import java.io.Closeable

/**
 * Lifecycle-safe adapter for Android's audio-coupled [HapticGenerator].
 *
 * The host owns the [AudioTrack] and calls [configureAudioAttributes] before
 * building it, then [attach] after creation. Unsupported devices simply return
 * `false`, allowing the portable event renderer to remain the fallback.
 */
class AndroidAudioCoupledHaptics(
    private val requested: Boolean = true
) : Closeable {
    enum class AttachStatus {
        NOT_ATTEMPTED,
        NOT_REQUESTED,
        API_UNSUPPORTED,
        INVALID_AUDIO_SESSION,
        EFFECT_UNSUPPORTED,
        EFFECT_LIBRARY_NOT_LOADED,
        ENABLE_FAILED,
        RUNTIME_ERROR,
        ATTACHED
    }

    private var releaseAction: (() -> Unit)? = null

    @Volatile
    var lastAttachStatus: AttachStatus = AttachStatus.NOT_ATTEMPTED
        private set

    val isAvailable: Boolean
        get() = requested && isPlatformAvailable()

    /** Unmutes the generated haptic channel before the platform effect is probed. */
    fun configureAudioAttributes(builder: AudioAttributes.Builder): Boolean {
        if (!requested || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        configureAudioAttributesApi31(builder)
        return true
    }

    /** Attaches and enables the system generator for this exact audio session. */
    @Synchronized
    fun attach(track: AudioTrack): Boolean {
        detach()
        if (!requested) {
            lastAttachStatus = AttachStatus.NOT_REQUESTED
            return false
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            lastAttachStatus = AttachStatus.API_UNSUPPORTED
            return false
        }
        return attachApi31(track.audioSessionId)
    }

    /** Disables and releases the current system effect, if any. */
    @Synchronized
    fun detach() {
        val action = releaseAction ?: return
        releaseAction = null
        action()
    }

    override fun close() = detach()

    @TargetApi(Build.VERSION_CODES.S)
    private fun configureAudioAttributesApi31(builder: AudioAttributes.Builder) {
        builder.setHapticChannelsMuted(false)
    }

    @TargetApi(Build.VERSION_CODES.S)
    private fun attachApi31(audioSessionId: Int): Boolean {
        if (audioSessionId <= 0) {
            lastAttachStatus = AttachStatus.INVALID_AUDIO_SESSION
            return false
        }
        return try {
            // Some vendor images register the effect and haptic output but return false from
            // HapticGenerator.isAvailable(). create() is the definitive public runtime probe: it
            // either creates the effect for this session or throws a documented exception.
            val generator = HapticGenerator.create(audioSessionId) ?: run {
                lastAttachStatus = AttachStatus.EFFECT_UNSUPPORTED
                return false
            }
            if (generator.setEnabled(true) != AudioEffect.SUCCESS) {
                generator.release()
                lastAttachStatus = AttachStatus.ENABLE_FAILED
                false
            } else {
                releaseAction = {
                    try {
                        generator.setEnabled(false)
                    } catch (_: RuntimeException) {
                        // The audio session may already be gone.
                    }
                    try {
                        generator.release()
                    } catch (_: RuntimeException) {
                        // Vendor AudioEffect services may die during teardown.
                    }
                }
                lastAttachStatus = AttachStatus.ATTACHED
                true
            }
        } catch (_: IllegalArgumentException) {
            lastAttachStatus = AttachStatus.EFFECT_UNSUPPORTED
            false
        } catch (_: UnsupportedOperationException) {
            lastAttachStatus = AttachStatus.EFFECT_LIBRARY_NOT_LOADED
            false
        } catch (_: RuntimeException) {
            lastAttachStatus = AttachStatus.RUNTIME_ERROR
            false
        }
    }

    companion object {
        @JvmStatic
        fun isPlatformAvailable(): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
            return isPlatformAvailableApi31()
        }

        @TargetApi(Build.VERSION_CODES.S)
        private fun isPlatformAvailableApi31(): Boolean = try {
            HapticGenerator.isAvailable()
        } catch (_: RuntimeException) {
            false
        }
    }
}
