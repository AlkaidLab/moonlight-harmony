<!-- SPDX-License-Identifier: Apache-2.0 -->

# Moonlight Audio Haptics SDK

Portable C++17 audio-to-haptics core shared by HarmonyOS and Android.

Version 0.5 keeps the stable ABI v1 and emits portable haptic IR from mono or
multichannel PCM. It combines channel-aware spectral energy fusion, PCEN-style
adaptation, and robust onset picking with a portable Apache-2.0 adaptation of
AOSP HapticGenerator's causal actuator-shaped waveform. The AOSP waveform is
summarized every 5 ms over a causal 40 ms rolling energy window and fused with
the spectral branch, so compressed music can recover clear transients without
a CNN or platform audio-effect dependency. A fixed-capacity, zero-lookahead
rhythm clock inspired by Real-Time PLP estimates 60--180 BPM. A separate
low-frequency-prioritized activation stage prevents speech and cymbals from
independently becoming strong tempo evidence. In MUSIC the clock adds small
phase-aligned accents and may recover a missed beat only when it is confident
and a current weak acoustic transient supports that prediction.

`MusicSceneAuthor` turns those portable features into the complete MUSIC
intent: transient gain, first/restart attenuation, low-frequency-supported
groove hysteresis, and a bounded continuous bed. It does not encode phone
models. Android actuator-class amplitude floors and durations are applied by
`HapticDevicePolicy` inside the Renderer, after host user gain.
Measured vendor compensation is isolated in explicit Renderer device profiles.
Profiles are neutral for unknown devices and may be disabled with
`HapticRenderConfig(enableDeviceProfiles = false)`.

`GameSceneAuthor` uses a fixed-capacity causal approximation of
median-filter HPSS plus SuperFlux-style frequency maximum filtering for a
BGM-heavy action-RPG profile. Stable orchestration and vocal vibrato are
attenuated, beat-locked background percussion is down-weighted, and strong
low-frequency physical impacts remain distinct from short skill attacks.
Continuous GAME intent requires persistent non-tonal low-frequency evidence,
is capped at 0.24 in portable IR, and is fatigue-ducked without reducing
transients. MUSIC feature and authoring paths are unchanged.

## Build and test

```bash
cmake -S audio-haptics-sdk -B audio-haptics-sdk/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build audio-haptics-sdk/build
ctest --test-dir audio-haptics-sdk/build --output-on-failure
```

The Android adapter is an independently publishable AAR. It owns the native
`AhEngine`, a bounded native IR queue and batched JNI drain, plus Android
vibrator capability detection, bounded renderer dispatch, rate limiting, and
device-level fallback. The portable Core owns the meaning of each scene and
authors device-independent IR. Host applications retain PCM acquisition, scene
selection and product policy, user gain, session orchestration, system-haptics
arbitration, and phone/gamepad routing; they should not re-author generic scene
gain, envelopes, transient duration, or continuous-groove curves.

```bash
./gradlew -p audio-haptics-sdk/platform/android testDebugUnitTest assembleRelease
```

The resulting development artifact is
`platform/android/build/outputs/aar/moonlight-haptics-android-release.aar`.
Maven coordinates are
`com.moonlight.haptics:moonlight-haptics-android:0.5.14-SNAPSHOT`.

The library is also consumed as the CMake target `moonlight::haptics` via
`add_subdirectory` from the HarmonyOS module and the P0 host evaluator.

## ABI rules

- Public types live in `include/moonlight_haptics/audio_haptics.h` and compile as C11.
- Every public struct starts with `struct_size`; callers zero-initialize structs.
- `AhHapticFrame` is fixed at 80 bytes in ABI v1. Minor evolution consumes
  reserved fields; changing the array element size requires a new API/ABI.
- Engine creation may allocate once. Processing performs no allocation, lock,
  platform call, callback, or logging.
- The AOSP-style filter chain is fixed-cost and causal. It processes channels
  independently before max-magnitude fusion to avoid antiphase cancellation.
- Its 40 ms rolling energy window updates every 5 ms, uses history only, and
  prevents the 150 Hz actuator carrier phase from becoming repeated onsets.
- The rhythm clock uses a causal complex-resonator bank, requires six strong
  events to establish lock, and unlocks after two seconds without even weak
  acoustic evidence. It never emits an unsupported metronome pulse.
- One engine has one processing thread. Runtime controls are stored in lock-free
  32-bit atomics and may be updated from one control thread.
- A larger PCM input may span multiple analysis hops, so the caller provides a
  fixed output array sized with `ah_get_max_output_frames()`.

## License boundary

This directory is Apache-2.0 and has no third-party runtime binary dependency.
Its FFT and spectral detector are project-written implementations; its portable
haptic-envelope filter chain is attributed to the Apache-2.0 AOSP
HapticGenerator. See `ALGORITHM_PROVENANCE.md` and `THIRD_PARTY_NOTICES.md`. It
must not contain or link aubio/GPL sources.
The GPL host application may link this SDK, while the SDK remains independently
distributable under Apache-2.0.
