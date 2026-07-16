// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import com.moonlight.haptics.HapticFrame
import java.io.Closeable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

fun interface HapticFrameListener {
    fun onHapticFrame(frame: HapticFrame)
}

/**
 * Owns one native AhEngine and drains its fixed-capacity native output queue on
 * a private worker thread. The opaque [nativeHandle] may be registered with a
 * native PCM host that consumes the exported android_adapter.h C ABI.
 */
class NativeHapticsSession(
    private val listener: HapticFrameListener,
    initialScene: Int = HapticFrame.SCENE_GAME,
    sensitivity: Float = 1f,
    outputGain: Float = 1f,
    queueCapacity: Int = 128
) : Closeable {
    private val worker = HandlerThread(
        "moonlight-haptics-native",
        Process.THREAD_PRIORITY_DISPLAY
    ).apply { start() }
    private val handler = Handler(worker.looper)
    private val handle = AtomicLong(0L)
    private val deliveryEpoch = AtomicLong(0L)
    private val drainScheduled = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val timestamps = LongArray(DRAIN_CAPACITY)
    private val producerTimes = LongArray(DRAIN_CAPACITY)
    private val metadata = IntArray(DRAIN_CAPACITY * METADATA_PER_FRAME)
    private val values = FloatArray(DRAIN_CAPACITY * VALUES_PER_FRAME)
    private val drainRunnable = Runnable { drainFrames() }

    init {
        val created = nativeCreate(
            initialScene.coerceIn(HapticFrame.SCENE_GAME, HapticFrame.SCENE_AUTO),
            sensitivity.coerceIn(0.1f, 3f),
            outputGain.coerceIn(0f, 1f),
            queueCapacity
        )
        if (created == 0L) {
            worker.quitSafely()
            throw IllegalStateException("Unable to create native haptics session")
        }
        handle.set(created)
    }

    val nativeHandle: Long
        get() = handle.get()

    /** Looper that drains native IR; renderers may share it to remove one dispatch hop. */
    val deliveryLooper: Looper
        get() = worker.looper

    val droppedFrameCount: Long
        get() = handle.get().takeIf { it != 0L }?.let(::nativeDroppedFrames) ?: 0L

    fun setScene(scene: Int) {
        val current = handle.get()
        if (current != 0L && !closed.get()) {
            nativeSetScene(current, scene.coerceIn(HapticFrame.SCENE_GAME, HapticFrame.SCENE_AUTO))
        }
    }

    /** Updates onset sensitivity without rebuilding the native engine. */
    fun setSensitivity(sensitivity: Float) {
        val current = handle.get()
        if (current != 0L && !closed.get()) {
            nativeSetSensitivity(current, sensitivity.coerceIn(0.1f, 3f))
        }
    }

    /**
     * Synchronously fences listener delivery and discards queued IR without
     * touching the producer-owned native engine.
     */
    fun stop() {
        if (closed.get()) return
        deliveryEpoch.incrementAndGet()
        if (Looper.myLooper() == worker.looper) {
            clearOnWorker()
            return
        }
        val stoppedLatch = CountDownLatch(1)
        val posted = handler.postAtFrontOfQueue {
            clearOnWorker()
            stoppedLatch.countDown()
        }
        if (posted) {
            stoppedLatch.await(WORKER_FENCE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } else {
            clearOnWorker()
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        if (Looper.myLooper() == worker.looper) {
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

    private fun closeOnWorker() {
        val current = handle.getAndSet(0L)
        if (current != 0L) {
            nativeClear(current)
            nativeClose(current)
        }
        worker.quitSafely()
    }

    private fun clearOnWorker() {
        val current = handle.get()
        if (current != 0L) nativeClear(current)
    }

    @Suppress("unused") // Called from JNI after PCM processing leaves its critical section.
    private fun onNativeFramesAvailable() {
        if (!closed.get()) scheduleDrain()
    }

    private fun scheduleDrain() {
        if (drainScheduled.compareAndSet(false, true)) {
            if (!handler.post(drainRunnable)) drainScheduled.set(false)
        }
    }

    private fun drainFrames() {
        val current = handle.get()
        if (current == 0L || closed.get()) {
            drainScheduled.set(false)
            return
        }
        val epoch = deliveryEpoch.get()

        while (!closed.get() && epoch == deliveryEpoch.get()) {
            val count = nativeDrain(
                current,
                timestamps,
                producerTimes,
                metadata,
                values,
                DRAIN_CAPACITY
            )
            if (count <= 0) break
            for (index in 0 until count) {
                if (closed.get() || epoch != deliveryEpoch.get()) break
                val metadataBase = index * METADATA_PER_FRAME
                val valueBase = index * VALUES_PER_FRAME
                try {
                    listener.onHapticFrame(
                        HapticFrame(
                            timestampUs = timestamps[index],
                            producerTimeUs = producerTimes[index],
                            flags = metadata[metadataBase],
                            continuousAmplitude = values[valueBase],
                            transientAmplitude = values[valueBase + 1],
                            transientDurationMs = values[valueBase + 2],
                            sharpness = values[valueBase + 3],
                            lowBandRatio = values[valueBase + 4],
                            stereoPan = values[valueBase + 5],
                            confidence = values[valueBase + 6],
                            activeScene = metadata[metadataBase + 1],
                            rhythmTempoBpm = values[valueBase + 7],
                            rhythmConfidence = values[valueBase + 8],
                            rhythmPhase = values[valueBase + 9],
                            rhythmLocked = values[valueBase + 10] > 0.5f,
                            rhythmActivation = values[valueBase + 11],
                            rhythmLowFrequencySupport = values[valueBase + 12],
                            rhythmCoasting = values[valueBase + 13] > 0.5f
                        )
                    )
                } catch (_: RuntimeException) {
                    // One host callback must not terminate the native drain worker.
                }
            }
        }

        drainScheduled.set(false)
        if (!closed.get() && epoch == deliveryEpoch.get() && nativeHasPending(current)) {
            scheduleDrain()
        }
    }

    private external fun nativeCreate(
        scene: Int,
        sensitivity: Float,
        outputGain: Float,
        queueCapacity: Int
    ): Long
    private external fun nativeDrain(
        handle: Long,
        timestamps: LongArray,
        producerTimes: LongArray,
        metadata: IntArray,
        values: FloatArray,
        capacity: Int
    ): Int
    private external fun nativeHasPending(handle: Long): Boolean
    private external fun nativeClear(handle: Long)
    private external fun nativeSetScene(handle: Long, scene: Int)
    private external fun nativeSetSensitivity(handle: Long, sensitivity: Float)
    private external fun nativeDroppedFrames(handle: Long): Long
    private external fun nativeClose(handle: Long)

    companion object {
        private const val DRAIN_CAPACITY = 32
        private const val METADATA_PER_FRAME = 2
        private const val VALUES_PER_FRAME = 14
        private const val WORKER_FENCE_TIMEOUT_MS = 2_000L

        init {
            System.loadLibrary("moonlight_haptics_android")
        }
    }
}
