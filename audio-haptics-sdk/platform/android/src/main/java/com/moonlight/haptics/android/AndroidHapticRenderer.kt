// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import com.moonlight.haptics.HapticFrame
import com.moonlight.haptics.android.internal.HapticDevicePolicy
import com.moonlight.haptics.android.internal.HapticDeviceProfiles
import com.moonlight.haptics.android.internal.HapticEffectLeaseGuard
import com.moonlight.haptics.android.internal.MutableHapticFrame
import com.moonlight.haptics.android.internal.HapticTimingPolicy
import com.moonlight.haptics.android.internal.SpscHapticFrameQueue
import java.io.Closeable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
import kotlin.math.max

/**
 * Renders HapticFrame IR on the Android device vibrator.
 *
 * [submit] is non-blocking and may be called by one real-time producer. Frames
 * enter a fixed-capacity SPSC queue; all Android vibration APIs run on the
 * renderer's private worker thread. App-specific strength and phone/gamepad
 * routing are applied before submission; actuator-class scene mapping happens
 * inside this renderer.
 */
class AndroidHapticRenderer(
    context: Context,
    private val config: HapticRenderConfig = HapticRenderConfig(),
    workerLooper: Looper? = null
) : Closeable {
    val capabilities: AndroidHapticCapabilities = AndroidHapticCapabilities.detect(context)
    private val deviceProfile = HapticDeviceProfiles.resolve(
        Build.MANUFACTURER,
        Build.MODEL,
        config.enableDeviceProfiles
    )
    val deviceProfileId: String
        get() = deviceProfile.id

    private val vibrator: Vibrator? = AndroidHapticCapabilities.vibrator(context)
    private val queue = SpscHapticFrameQueue(config.queueCapacity)
    private val ownedWorker = if (workerLooper == null) {
        HandlerThread(
            "moonlight-haptics-renderer",
            Process.THREAD_PRIORITY_DISPLAY
        ).apply { start() }
    } else {
        null
    }
    private val renderLooper = workerLooper ?: checkNotNull(ownedWorker).looper
    private val handler = Handler(renderLooper)
    private val deliveryEpoch = AtomicLong(0L)
    private val drainScheduled = AtomicBoolean(false)
    private val stopRequested = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val droppedFrames = AtomicLong(0L)
    private val audioClockFramePosition = AtomicLong(-1L)
    private val audioClockSystemTimeUs = AtomicLong(-1L)
    private val audioClockSampleRate = AtomicLong(0L)
    private val latency = HapticLatencyAccumulator()
    private val drainRunnable = Runnable { drainQueue() }

    // Worker-thread-only state.
    private var lastTimestampUs = -1L
    private var lastSubmitTimeMs = 0L
    private var lastContinuousAmplitude = 0f
    private var active = false
    private val effectLeaseGuard = HapticEffectLeaseGuard()

    val droppedFrameCount: Long
        get() = droppedFrames.get()

    fun updateAudioPresentationClock(
        framePosition: Long,
        systemNanoTime: Long,
        sampleRate: Int
    ) {
        if (framePosition < 0L || systemNanoTime <= 0L || sampleRate <= 0) {
            clearAudioPresentationClock()
            return
        }
        audioClockFramePosition.set(framePosition)
        audioClockSystemTimeUs.set(systemNanoTime / 1_000L)
        audioClockSampleRate.set(sampleRate.toLong())
    }

    fun clearAudioPresentationClock() {
        audioClockSampleRate.set(0L)
        audioClockFramePosition.set(-1L)
        audioClockSystemTimeUs.set(-1L)
    }

    fun takeLatencySnapshot(): HapticLatencySnapshot = latency.takeSnapshot()

    fun submit(frame: HapticFrame): Boolean = submit(
        frame.timestampUs,
        frame.flags,
        frame.continuousAmplitude,
        frame.transientAmplitude,
        frame.transientDurationMs,
        frame.sharpness,
        frame.lowBandRatio,
        frame.stereoPan,
        frame.confidence,
        frame.activeScene,
        frame.producerTimeUs
    )

    /** Allocation-free submission path intended for JNI and audio callbacks. */
    fun submit(
        timestampUs: Long,
        flags: Int,
        continuousAmplitude: Float,
        transientAmplitude: Float,
        transientDurationMs: Float,
        sharpness: Float,
        lowBandRatio: Float,
        stereoPan: Float,
        confidence: Float,
        activeScene: Int,
        producerTimeUs: Long = 0L
    ): Boolean {
        if (closed.get()) return false
        val normalizedProducerTimeUs = producerTimeUs.takeIf { it > 0L }
            ?: monotonicTimeUs()
        val accepted = queue.offer(
            timestampUs,
            normalizedProducerTimeUs,
            flags,
            continuousAmplitude,
            transientAmplitude,
            transientDurationMs,
            sharpness,
            lowBandRatio,
            stereoPan,
            confidence,
            activeScene
        )
        if (!accepted) {
            droppedFrames.incrementAndGet()
            if (flags and HapticFrame.FLAG_STOP != 0) stopRequested.set(true)
        }
        scheduleDrain(urgent = flags and HapticFrame.FLAG_STOP != 0)
        return accepted
    }

    /** Flushes queued frames and synchronously fences/cancels the active effect. */
    fun stop() {
        if (closed.get()) return
        deliveryEpoch.incrementAndGet()
        if (Looper.myLooper() == renderLooper) {
            stopOnWorker()
            return
        }
        val stoppedLatch = CountDownLatch(1)
        val posted = handler.postAtFrontOfQueue {
            stopOnWorker()
            stoppedLatch.countDown()
        }
        if (posted) {
            stoppedLatch.await(WORKER_FENCE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } else {
            stopOnWorker()
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        deliveryEpoch.incrementAndGet()
        if (Looper.myLooper() == renderLooper) {
            closeOnWorker()
            return
        }
        val closedLatch = CountDownLatch(1)
        val posted = handler.postAtFrontOfQueue {
            closeOnWorker()
            closedLatch.countDown()
        }
        if (posted) {
            closedLatch.await(WORKER_FENCE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } else {
            closeOnWorker()
        }
    }

    private fun scheduleDrain(urgent: Boolean = false) {
        if (Looper.myLooper() == renderLooper && !drainScheduled.get()) {
            drainScheduled.set(true)
            drainQueue()
            return
        }
        if (urgent) {
            handler.removeCallbacks(drainRunnable)
            drainScheduled.set(true)
            if (!handler.postAtFrontOfQueue(drainRunnable)) drainScheduled.set(false)
            return
        }
        if (drainScheduled.compareAndSet(false, true)) {
            if (!handler.post(drainRunnable)) drainScheduled.set(false)
        }
    }

    private fun drainQueue() {
        val epoch = deliveryEpoch.get()
        if (stopRequested.getAndSet(false) || queue.hasPendingStop()) {
            queue.clearFromConsumer()
            stopInternal()
        }

        while (!closed.get() && epoch == deliveryEpoch.get()) {
            val frame = queue.peek() ?: break
            val delayUs = render(
                frame,
                hasNewerTransient = queue.hasNewerTransientAfterHead()
            )
            if (delayUs > 0L) {
                latency.recordScheduled()
                val delayMs = ((delayUs + 999L) / 1_000L).coerceAtLeast(1L)
                if (!handler.postDelayed(drainRunnable, delayMs)) {
                    drainScheduled.set(false)
                }
                return
            }
            queue.pop()
        }

        drainScheduled.set(false)
        if (!closed.get() && epoch == deliveryEpoch.get() &&
            (queue.peek() != null || stopRequested.get())
        ) {
            scheduleDrain()
        }
    }

    private fun stopOnWorker() {
        stopRequested.set(false)
        queue.clearFromConsumer()
        stopInternal()
    }

    private fun closeOnWorker() {
        stopOnWorker()
        ownedWorker?.quitSafely()
    }

    /** Returns a positive delay when the head frame must remain queued. */
    private fun render(frame: MutableHapticFrame, hasNewerTransient: Boolean): Long {
        if (!capabilities.hasVibrator || frame.timestampUs < lastTimestampUs) return 0L

        val stop = frame.flags and HapticFrame.FLAG_STOP != 0
        val originalTransient = frame.flags and HapticFrame.FLAG_TRANSIENT != 0
        val continuousChanged = frame.flags and HapticFrame.FLAG_CONTINUOUS_CHANGED != 0
        if (stop) {
            stopInternal()
            lastTimestampUs = frame.timestampUs
            if (!originalTransient) return 0L
        }

        val nowUs = monotonicTimeUs()
        val timing = HapticTimingPolicy.decide(
            nowUs = nowUs,
            producerTimeUs = frame.producerTimeUs,
            streamTimestampUs = frame.timestampUs,
            clockFramePosition = audioClockFramePosition.get(),
            clockSystemTimeUs = audioClockSystemTimeUs.get(),
            sampleRate = audioClockSampleRate.get().toInt(),
            actuatorLeadUs = config.actuatorLeadMs * 1_000L,
            staleDeadlineUs = config.transientStaleDeadlineMs * 1_000L,
            maximumScheduleAheadUs = config.maximumScheduleAheadMs * 1_000L
        )
        timing.rawTargetVibrateTimeUs?.let { rawTargetUs ->
            val sampleRate = audioClockSampleRate.get().toInt()
            val clockFramePosition = audioClockFramePosition.get()
            val clockSystemTimeUs = audioClockSystemTimeUs.get()
            if (sampleRate > 0 && clockFramePosition >= 0L && clockSystemTimeUs >= 0L) {
                val clockStreamTimeUs = clockFramePosition * 1_000_000L / sampleRate
                latency.recordClockDecision(
                    accepted = timing.targetVibrateTimeUs != null,
                    clockAgeUs = nowUs - clockSystemTimeUs,
                    streamClockDeltaUs = frame.timestampUs - clockStreamTimeUs,
                    rawTargetDeltaUs = rawTargetUs - nowUs
                )
            }
        }
        if (!stop && timing.delayUs > 0L) return timing.delayUs

        val suppressTransient = HapticTimingPolicy.shouldSuppressTransient(
            frame.flags,
            timing,
            hasNewerTransient
        )
        if (suppressTransient) {
            if (timing.dropTransient) latency.recordStaleDrop()
            if (hasNewerTransient) latency.recordSupersededDrop()
        }
        val transientFlag = originalTransient && !suppressTransient
        lastTimestampUs = frame.timestampUs
        if (!transientFlag && !continuousChanged) return 0L

        val authoredContinuous = frame.continuousAmplitude.coerceIn(0f, 1f)
        val deviceIntent = HapticDevicePolicy.map(
            continuousAmplitude = authoredContinuous,
            transientAmplitude = frame.transientAmplitude,
            transientDurationMs = frame.transientDurationMs,
            flags = frame.flags,
            activeScene = frame.activeScene,
            capabilityLevel = capabilities.level,
            musicContinuousGain = deviceProfile.musicContinuousGain
        )
        val continuous = deviceIntent.continuousAmplitude
        val transient = deviceIntent.transientAmplitude
        val selected = if (transientFlag) max(continuous, transient) else continuous
        if (selected < config.minimumAmplitude) {
            if (continuousChanged) stopInternal()
            return 0L
        }

        val now = SystemClock.elapsedRealtime()
        if (!transientFlag && active &&
            abs(authoredContinuous - lastContinuousAmplitude) < config.continuousAmplitudeHysteresis
        ) {
            return 0L
        }
        val minimumInterval = if (transientFlag) {
            config.transientMinimumIntervalMs
        } else {
            config.continuousMinimumIntervalMs
        }
        if (now - lastSubmitTimeMs < minimumInterval) return 0L

        lastSubmitTimeMs = now
        lastContinuousAmplitude = authoredContinuous
        val renderTimeUs = monotonicTimeUs()
        latency.record(
            dispatchUs = (renderTimeUs - frame.producerTimeUs).coerceAtLeast(0L),
            audioSkewUs = timing.targetVibrateTimeUs?.let { target ->
                (renderTimeUs - target).coerceAtLeast(0L)
            }
        )
        renderEffect(
            continuous,
            transient,
            deviceIntent.transientDurationMs,
            frame.sharpness,
            transientFlag,
            if (frame.activeScene == HapticFrame.SCENE_MUSIC) {
                deviceProfile.musicContinuousMaximumHoldMs
            } else {
                null
            }
        )
        return 0L
    }

    private fun renderEffect(
        continuous: Float,
        transient: Float,
        transientDurationMs: Float,
        sharpness: Float,
        hasTransient: Boolean,
        maximumContinuousHoldMs: Long?
    ) {
        val target = vibrator ?: return
        val generation = effectLeaseGuard.beginEffect()
        val duration = transientDurationMs.toLong().coerceIn(
            config.minimumTransientDurationMs,
            config.maximumTransientDurationMs
        )
        try {
            // A new vibrate() request supersedes the running effect. Avoid an
            // eager cancel here because it inserts a vendor-dependent gap.
            if (continuous >= config.minimumAmplitude) {
                renderContinuous(target, continuous, transient, duration, hasTransient)
            } else if (hasTransient && transient >= config.minimumAmplitude) {
                renderTransient(target, transient, duration, sharpness.coerceIn(0f, 1f))
            } else {
                stopInternal()
                return
            }
            active = true
        } catch (_: RuntimeException) {
            try {
                renderFallback(target, max(continuous, transient), duration)
                active = true
            } catch (_: RuntimeException) {
                active = false
            }
        }
        if (active && continuous >= config.minimumAmplitude && maximumContinuousHoldMs != null) {
            handler.postDelayed(
                { stopBoundedContinuous(generation) },
                maximumContinuousHoldMs
            )
        }
    }

    private fun renderContinuous(
        target: Vibrator,
        continuous: Float,
        transient: Float,
        duration: Long,
        hasTransient: Boolean
    ) {
        val repeatIndex = if (hasTransient) 2 else 1
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && capabilities.hasAmplitudeControl) {
            val continuousLevel = amplitudeByte(continuous)
            val effect = if (hasTransient && transient >= config.minimumAmplitude) {
                VibrationEffect.createWaveform(
                    longArrayOf(0L, duration, config.continuousSegmentMs),
                    intArrayOf(0, amplitudeByte(max(transient, continuous)), continuousLevel),
                    repeatIndex
                )
            } else {
                VibrationEffect.createWaveform(
                    longArrayOf(0L, config.continuousSegmentMs),
                    intArrayOf(0, continuousLevel),
                    repeatIndex
                )
            }
            vibrate(target, effect)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val timings = if (hasTransient) {
                longArrayOf(0L, duration, config.continuousSegmentMs)
            } else {
                longArrayOf(0L, config.continuousSegmentMs)
            }
            vibrate(target, VibrationEffect.createWaveform(timings, repeatIndex))
        } else {
            @Suppress("DEPRECATION")
            target.vibrate(config.continuousSegmentMs)
        }
    }

    private fun stopBoundedContinuous(expectedGeneration: Long) {
        if (!active || !effectLeaseGuard.tryExpire(expectedGeneration)) return
        try {
            vibrator?.cancel()
        } catch (_: RuntimeException) {
            // Expiring a device-profile lease is best-effort.
        }
        active = false
        lastContinuousAmplitude = 0f
    }

    private fun renderTransient(target: Vibrator, amplitude: Float, duration: Long, sharpness: Float) {
        when (capabilities.level) {
            AndroidHapticCapabilityLevel.ENVELOPE -> renderEnvelope(target, amplitude, duration, sharpness)
            AndroidHapticCapabilityLevel.PRIMITIVES -> renderPrimitive(target, amplitude, duration, sharpness)
            AndroidHapticCapabilityLevel.AMPLITUDE -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrate(target, VibrationEffect.createOneShot(duration, amplitudeByte(amplitude)))
            }
            AndroidHapticCapabilityLevel.ON_OFF -> renderFallback(target, amplitude, duration)
            AndroidHapticCapabilityLevel.NONE -> Unit
        }
    }

    private fun renderEnvelope(target: Vibrator, amplitude: Float, duration: Long, sharpness: Float) {
        if (Build.VERSION.SDK_INT < 36) {
            renderFallback(target, amplitude, duration)
            return
        }
        val attack = minOf(5L, duration)
        val effect = VibrationEffect.BasicEnvelopeBuilder()
            .setInitialSharpness(sharpness)
            .addControlPoint(amplitude, sharpness, attack)
            .addControlPoint(0f, sharpness, duration - attack)
            .build()
        vibrate(target, effect)
    }

    private fun renderPrimitive(target: Vibrator, amplitude: Float, duration: Long, sharpness: Float) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            renderFallback(target, amplitude, duration)
            return
        }
        val preferClick = sharpness >= 0.5f
        val primitive = when {
            preferClick && capabilities.supportsClickPrimitive ->
                VibrationEffect.Composition.PRIMITIVE_CLICK
            capabilities.supportsThudPrimitive -> VibrationEffect.Composition.PRIMITIVE_THUD
            capabilities.supportsClickPrimitive -> VibrationEffect.Composition.PRIMITIVE_CLICK
            else -> {
                renderFallback(target, amplitude, duration)
                return
            }
        }
        val effect = VibrationEffect.startComposition()
            .addPrimitive(primitive, amplitude.coerceAtLeast(0.1f))
            .compose()
        vibrate(target, effect)
    }

    private fun renderFallback(target: Vibrator, amplitude: Float, duration: Long) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val level = if (capabilities.hasAmplitudeControl) {
                amplitudeByte(amplitude)
            } else {
                VibrationEffect.DEFAULT_AMPLITUDE
            }
            vibrate(target, VibrationEffect.createOneShot(duration, level))
        } else {
            @Suppress("DEPRECATION")
            target.vibrate(duration)
        }
    }

    private fun vibrate(target: Vibrator, effect: VibrationEffect) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val attributes = VibrationAttributes.Builder()
                .setUsage(VibrationAttributes.USAGE_MEDIA)
                .build()
            target.vibrate(effect, attributes)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            target.vibrate(effect)
        }
    }

    private fun stopInternal() {
        effectLeaseGuard.invalidate()
        try {
            vibrator?.cancel()
        } catch (_: RuntimeException) {
            // Stopping must remain best-effort on vendor vibrator services.
        }
        active = false
        lastContinuousAmplitude = 0f
        lastTimestampUs = -1L
    }

    private fun amplitudeByte(value: Float): Int =
        (value.coerceIn(0f, 1f) * 255f).toInt().coerceIn(1, 255)

    companion object {
        private const val WORKER_FENCE_TIMEOUT_MS = 2_000L

        // AudioTimestamp.nanoTime and native std::chrono::steady_clock both use
        // the System.nanoTime/CLOCK_MONOTONIC time domain on Android.
        private fun monotonicTimeUs(): Long = System.nanoTime() / 1_000L
    }
}
