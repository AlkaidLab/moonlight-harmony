// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android.internal

import com.moonlight.haptics.HapticFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpscHapticFrameQueueTest {
    @Test
    fun preservesOrderAndRejectsOverflow() {
        val queue = SpscHapticFrameQueue(2)
        assertTrue(queue.offerFrame(10L, 0.2f))
        assertTrue(queue.offerFrame(20L, 0.8f))
        assertFalse(queue.offerFrame(30L, 1f))

        assertEquals(10L, queue.peek()!!.timestampUs)
        assertEquals(1_010L, queue.peek()!!.producerTimeUs)
        assertEquals(0.2f, queue.peek()!!.continuousAmplitude)
        queue.pop()
        assertEquals(20L, queue.peek()!!.timestampUs)
        queue.pop()
        assertNull(queue.peek())
    }

    @Test
    fun detectsNewerTransientWithoutDiscardingStop() {
        val queue = SpscHapticFrameQueue(4)
        assertTrue(queue.offerFrame(10L, 0.4f, HapticFrame.FLAG_TRANSIENT))
        assertTrue(queue.offerFrame(20L, 0.2f, HapticFrame.FLAG_CONTINUOUS_CHANGED))
        assertTrue(queue.offerFrame(30L, 0.8f, HapticFrame.FLAG_TRANSIENT))

        assertTrue(queue.hasNewerTransientAfterHead())
        queue.pop()
        assertFalse(queue.peek()!!.flags and HapticFrame.FLAG_STOP != 0)
    }

    private fun SpscHapticFrameQueue.offerFrame(
        timestampUs: Long,
        amplitude: Float,
        flags: Int = HapticFrame.FLAG_CONTINUOUS_CHANGED
    ): Boolean = offer(
        timestampUs = timestampUs,
        producerTimeUs = timestampUs + 1_000L,
        flags = flags,
        continuousAmplitude = amplitude,
        transientAmplitude = 0f,
        transientDurationMs = 0f,
        sharpness = 0f,
        lowBandRatio = 0f,
        stereoPan = 0f,
        confidence = 1f,
        activeScene = HapticFrame.SCENE_GAME
    )
}
