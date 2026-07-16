// SPDX-License-Identifier: Apache-2.0

package com.moonlight.haptics.android

import android.util.Log
import com.moonlight.haptics.HapticFrame
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeHapticsSessionDeviceTest {
    @Test
    fun reportsAudioCoupledHapticsAvailability() {
        val available = AndroidAudioCoupledHaptics.isPlatformAvailable()
        Log.i("MoonlightHapticsTest", "audioCoupledAvailable=$available")
    }

    @Test
    fun nativeLibraryAndSessionLifecycle() {
        val renderer = AndroidHapticRenderer(
            InstrumentationRegistry.getInstrumentation().targetContext
        )
        val session = NativeHapticsSession(listener = {})
        assertTrue(session.nativeHandle != 0L)
        session.setScene(HapticFrame.SCENE_MUSIC)
        session.setSensitivity(1.5f)
        assertEquals(0L, session.droppedFrameCount)
        session.stop()
        session.close()
        assertEquals(0L, session.nativeHandle)
        renderer.stop()
        renderer.close()
    }
}
