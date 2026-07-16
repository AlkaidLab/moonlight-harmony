<!-- SPDX-License-Identifier: Apache-2.0 -->

# Third-party notices

The SDK core has no third-party runtime binary or model dependencies. It
contains the following attributed source adaptation.

## Android Open Source Project HapticGenerator

- Project: Android Open Source Project, `platform/frameworks/av`
- Component: `media/libeffects/hapticgenerator`
- Source: https://android.googlesource.com/platform/frameworks/av/+/refs/heads/main/media/libeffects/hapticgenerator/
- License: Apache License 2.0
- Copyright: Copyright (C) 2020 The Android Open Source Project
- Adapted files in this package: `src/dsp/aosp_haptic_envelope.h` and
  `src/dsp/aosp_haptic_envelope.cpp`

The adaptation keeps the HapticGenerator filter equations and default tuning,
while replacing Android audio-effect, HAL, logging, property, and buffer code
with a platform-independent summary emitted every 5 ms from a causal 40 ms
rolling energy window. The original copyright and Apache-2.0 license header are
preserved in the adapted files.

The radix-2 FFT, STFT feature extraction, PCEN-style adaptation, robust onset
picker, hybrid decision logic, rhythm clock, and haptic IR mapping elsewhere in
this package are project-written Apache-2.0 source code. No aubio source code is
included or copied.

## Real-Time PLP research reference (not included)

- Project: Real-Time PLP, Peter Meier, Ching-Yu Chiu, and Meinard Muller
- Source: https://github.com/groupmm/real_time_plp
- Reference license: MIT
- Included source/binary/model dependency: none

The project-written causal rhythm clock is informed by the published method;
it is not a source adaptation or translation of the Python reference. This
entry records algorithm provenance and license review, not a bundled third-
party component.

## GAME feature research references (not included)

- Derry FitzGerald, *Harmonic/Percussive Separation using Median Filtering*,
  DAFx-10: https://www.dafx.de/paper-archive/details/DsmIVcydPX66AuaqEmKyTQ
- Sebastian Böck and Gerhard Widmer, *Maximum Filter Vibrato Suppression for
  Onset Detection*, DAFx-13:
  https://www.dafx.de/paper-archive/details.php?id=0oee-99Z88WL7pSo749gcA
- Included source/binary/model dependency: none

The fixed-capacity causal C++ implementation is project-written from the
published algorithm descriptions. It copies no reference source, model, or
generated table. These entries record research provenance, not bundled
third-party components.

Toolchain-provided C/C++ runtime libraries are not bundled by this source tree.
This file must be updated before adding an external FFT implementation,
inference runtime, model, generated asset, or platform library to a distributed
package.
