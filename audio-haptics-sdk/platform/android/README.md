<!-- SPDX-License-Identifier: Apache-2.0 -->

# Moonlight Haptics Android Adapter

Apache-2.0 Android native adapter and renderer for the platform-independent
`HapticFrame` emitted by `moonlight-haptics-core`.

## Boundary

The AAR owns:

- the Kotlin `HapticFrame` ABI v1 representation;
- `NativeHapticsSession`, its native `AhEngine`, and an opaque host handle;
- a fixed-capacity native SPSC IR queue with batched Kotlin drain;
- a monotonic producer timestamp on each queued Android IR frame;
- the public Prefab/C header `moonlight_haptics/android_adapter.h`;
- vibrator capability detection and device-level fallback;
- a fixed-capacity SPSC input queue and private renderer thread;
- Android waveform, primitive, envelope, and one-shot mapping;
- Android 12+ audio-coupled `HapticGenerator` session binding;
- device-level rate limiting, hysteresis, stop, and release.
- optional AudioTrack presentation-clock alignment, stale-transient suppression,
  and dispatch/audio-skew P50/P95/P99 diagnostics.

The host application owns PCM acquisition, scene/product policy, user strength,
session orchestration, and phone/gamepad routing. It registers the AAR's opaque
native session handle with its PCM bridge; it does not own `AhEngine` or copy an
SDK IR struct. The first AAR does not promise a generic gamepad transport.

## Build

From a checkout containing a Gradle wrapper compatible with AGP 9.2.1:

```bash
./gradlew -p audio-haptics-sdk/platform/android testDebugUnitTest assembleRelease lintRelease
```

## Native PCM path

`NativeHapticsSession.nativeHandle` is registered with a native host through
the exported `android_adapter.h` C ABI. The audio thread calls process while it
owns the PCM critical section, then calls notify only after releasing that
section. Processing writes only to the bounded native queue; the AAR worker
drains frames in batches and invokes the typed `HapticFrameListener`.

The queue never blocks the audio producer. It reports dropped frames and gives
an emergency `STOP` priority over queued state when saturated.

For the lowest dispatch overhead, construct `NativeHapticsSession` first and
pass its `deliveryLooper` to `AndroidHapticRenderer`. Native drain, product
policy, and renderer submission then execute on one display-priority worker;
calls into the Android vibrator service remain off the audio callback.

## Presentation-clock alignment

PCM hosts should reuse an `AudioTimestamp` and call
`AndroidHapticRenderer.updateAudioPresentationClock()` after successful
`AudioTrack.write()` operations. The renderer maps each IR stream timestamp to
the estimated acoustic presentation time, subtracts `actuatorLeadMs`, and
schedules the vibration request in the `AudioTimestamp.nanoTime` /
`System.nanoTime()` monotonic time domain.
When no valid timestamp exists, or the audio/IR stream origins are implausibly
far apart, it falls back to the monotonic native producer time.

Transient IR that misses `transientStaleDeadlineMs` is discarded instead of
being rendered late. If several transient frames are queued, the latest wins;
latest-wins applies only to the immediate fallback path, because two frames
with valid future audio deadlines may both be real beats. `STOP` is always
delivered with priority. Continuous state is retained. The default 500 ms
schedule window covers high-latency Bluetooth A2DP presentation clocks while
still rejecting implausible stream-origin mismatches. Use
`takeLatencySnapshot()` for the rolling render-dispatch and audio-target skew
P50/P95/P99 counters plus stale/superseded drop counts.

Call `clearAudioPresentationClock()` whenever the AudioTrack is paused,
flushed, released, or rebuilt.

## Renderer submission

`AndroidHapticRenderer.submit(HapticFrame)` is convenient for ordinary callers.
JNI/audio callback integrations should use the primitive overload, which copies
directly into a preallocated SPSC slot and returns `false` instead of blocking
when the queue is full. All calls to Android's vibrator service execute on the
renderer worker thread.

Call `stop()` when a session loses focus and `close()` when the owning session is
destroyed.
