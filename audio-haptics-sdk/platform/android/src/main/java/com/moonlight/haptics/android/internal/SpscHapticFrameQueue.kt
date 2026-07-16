// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android.internal

import com.moonlight.haptics.HapticFrame
import java.util.concurrent.atomic.AtomicLong

internal class MutableHapticFrame {
    var timestampUs: Long = 0L
    var producerTimeUs: Long = 0L
    var flags: Int = 0
    var continuousAmplitude: Float = 0f
    var transientAmplitude: Float = 0f
    var transientDurationMs: Float = 0f
    var sharpness: Float = 0f
    var lowBandRatio: Float = 0f
    var stereoPan: Float = 0f
    var confidence: Float = 0f
    var activeScene: Int = HapticFrame.SCENE_UNKNOWN

    fun set(
        timestampUs: Long,
        producerTimeUs: Long,
        flags: Int,
        continuousAmplitude: Float,
        transientAmplitude: Float,
        transientDurationMs: Float,
        sharpness: Float,
        lowBandRatio: Float,
        stereoPan: Float,
        confidence: Float,
        activeScene: Int
    ) {
        this.timestampUs = timestampUs
        this.producerTimeUs = producerTimeUs
        this.flags = flags
        this.continuousAmplitude = continuousAmplitude
        this.transientAmplitude = transientAmplitude
        this.transientDurationMs = transientDurationMs
        this.sharpness = sharpness
        this.lowBandRatio = lowBandRatio
        this.stereoPan = stereoPan
        this.confidence = confidence
        this.activeScene = activeScene
    }
}

/** Fixed-capacity, allocation-free queue for one producer and one consumer. */
internal class SpscHapticFrameQueue(capacity: Int) {
    private val mask: Int
    private val slots: Array<MutableHapticFrame>
    private val readIndex = AtomicLong(0L)
    private val writeIndex = AtomicLong(0L)

    init {
        require(capacity >= 2 && capacity and (capacity - 1) == 0)
        mask = capacity - 1
        slots = Array(capacity) { MutableHapticFrame() }
    }

    fun offer(
        timestampUs: Long,
        producerTimeUs: Long,
        flags: Int,
        continuousAmplitude: Float,
        transientAmplitude: Float,
        transientDurationMs: Float,
        sharpness: Float,
        lowBandRatio: Float,
        stereoPan: Float,
        confidence: Float,
        activeScene: Int
    ): Boolean {
        val write = writeIndex.get()
        if (write - readIndex.get() >= slots.size) return false

        slots[(write.toInt() and mask)].set(
            timestampUs,
            producerTimeUs,
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
        writeIndex.lazySet(write + 1L)
        return true
    }

    fun peek(): MutableHapticFrame? {
        val read = readIndex.get()
        if (read >= writeIndex.get()) return null
        return slots[(read.toInt() and mask)]
    }

    fun pop() {
        val read = readIndex.get()
        check(read < writeIndex.get())
        readIndex.lazySet(read + 1L)
    }

    /** Consumer-only latest-wins probe for queued transient bursts. */
    fun hasNewerTransientAfterHead(): Boolean {
        val read = readIndex.get()
        val write = writeIndex.get()
        var cursor = read + 1L
        while (cursor < write) {
            val flags = slots[(cursor.toInt() and mask)].flags
            if (flags and HapticFrame.FLAG_TRANSIENT != 0) return true
            ++cursor
        }
        return false
    }

    /** Consumer-only probe used to make stop bypass any scheduled frame. */
    fun hasPendingStop(): Boolean {
        var cursor = readIndex.get()
        val write = writeIndex.get()
        while (cursor < write) {
            val flags = slots[(cursor.toInt() and mask)].flags
            if (flags and HapticFrame.FLAG_STOP != 0) return true
            ++cursor
        }
        return false
    }

    /** Must only be called by the consumer thread. */
    fun clearFromConsumer() {
        readIndex.lazySet(writeIndex.get())
    }
}
