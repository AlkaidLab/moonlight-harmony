<!-- SPDX-License-Identifier: Apache-2.0 -->

# Algorithm provenance

Moonlight Audio Haptics 0.5 contains four provenance classes:

1. the FFT, spectral/PCEN feature path, robust onset picker, IR mapping, and
   platform-neutral engine are project-written Apache-2.0 code;
2. `src/dsp/aosp_haptic_envelope.*` is an Apache-2.0 portable adaptation of the
   Android Open Source Project HapticGenerator filter chain;
3. `src/core/causal_rhythm_clock.*` is project-written Apache-2.0 code informed
   by the published Real-Time Predominant Local Pulse method;
4. the GAME percussive/tonal features are project-written Apache-2.0 code
   informed by published median-filter HPSS and SuperFlux methods.

The SDK does not compile or link aubio. It has no third-party runtime binary or
model dependency.

## Public methods used

- The iterative radix-2 transform uses the standard Cooley-Tukey FFT
  decomposition described by J. W. Cooley and J. W. Tukey, *An Algorithm for
  the Machine Calculation of Complex Fourier Series*, Mathematics of
  Computation 19 (1965), DOI
  [10.1090/S0025-5718-1965-0178586-1](https://doi.org/10.1090/S0025-5718-1965-0178586-1).
- The onset novelty function uses positive changes between adjacent magnitude
  spectra (half-wave rectified spectral flux), a standard onset-detection
  family surveyed by Simon Dixon in
  [Simple Spectrum-Based Onset Detection](https://eecs.qmul.ac.uk/~simond/pub/2006/mirex-onset.pdf)
  (MIREX 2006).
- Per-bin automatic gain control and dynamic compression are inspired by PCEN,
  introduced by Yuxuan Wang et al. in
  [Trainable Frontend for Robust and Far-Field Keyword Spotting](https://arxiv.org/abs/1607.05666).
- Median/MAD adaptive thresholds, refractory timing, multiband weighting, and
  haptic IR mapping are project-specific compositions and parameter choices.

## GAME percussive and vibrato-suppression references

The GAME feature path is informed by Derry FitzGerald,
[Harmonic/Percussive Separation using Median Filtering](https://www.dafx.de/paper-archive/details/DsmIVcydPX66AuaqEmKyTQ)
(DAFx-10), and Sebastian Böck and Gerhard Widmer,
[Maximum Filter Vibrato Suppression for Onset Detection](https://www.dafx.de/paper-archive/details.php?id=0oee-99Z88WL7pSo749gcA)
(DAFx-13, also known as SuperFlux).

Moonlight does not copy an HPSS or SuperFlux reference implementation. The
project-written C++17 path uses a trailing nine-frame magnitude median instead
of a centred time median, a seven-bin current-frame frequency median, soft
percussive masks, and a five-bin maximum-filtered previous PCEN spectrum. It
therefore uses current and past samples only, reconstructs no separated audio,
and allocates all history at engine creation. `GameSceneAuthor` combines those
features with the existing causal rhythm clock: stable beat-locked moderate
events are attenuated, while strong low-frequency physical impacts bypass the
music penalty. These mobile thresholds, persistence rules, fatigue budget,
and haptic mappings are project-specific compositions.

## Real-Time PLP reference

The rhythm layer is informed by Peter Meier, Ching-Yu Chiu, and Meinard
Muller's 2024 paper, [A Real-Time Beat Tracking System with Zero Latency and
Enhanced Controllability](https://doi.org/10.5334/tismir.189), and its
[MIT-licensed reference repository](https://github.com/groupmm/real_time_plp).
The reference uses a causal novelty function, a local Fourier tempogram, and
overlap-added predominant-pulse kernels.

Moonlight does not copy or translate the Python/NumPy/SciPy implementation.
`causal_rhythm_clock.cpp` is a clean C++17 implementation using a fixed bank of
121 exponentially windowed complex resonators from 60 through 180 BPM. The
project-written `rhythm_activation_extractor.cpp` supplies a causal,
low-frequency-prioritized pulse likelihood from per-band PCEN flux and the
actuator-shaped tactile envelope; broadband onsets can assist but cannot alone
become strong tempo events. The clock adds mobile-specific lock hysteresis,
weak-evidence gating, onset de-duplication, tempo-change settling, and silence
unlock. There is no Python package, model, generated table, or Real-Time PLP
source file in the SDK binary or source distribution.

## AOSP HapticGenerator adaptation

The actuator-shaped branch is derived from these Android Open Source Project
files, copyright The Android Open Source Project and licensed Apache-2.0:

- [`Processors.cpp`](https://android.googlesource.com/platform/frameworks/av/+/refs/heads/main/media/libeffects/hapticgenerator/Processors.cpp)
- [`Processors.h`](https://android.googlesource.com/platform/frameworks/av/+/refs/heads/main/media/libeffects/hapticgenerator/Processors.h)
- [`EffectHapticGenerator.cpp`](https://android.googlesource.com/platform/frameworks/av/+/refs/heads/main/media/libeffects/hapticgenerator/EffectHapticGenerator.cpp)

The portable adaptation retains the AOSP default sequence and tuning: 50 Hz
high-pass, 9 kHz low-pass, half-wave rectification, 60 Hz high-pass, cascaded
700/400/500 Hz low-passes, a 150 Hz resonant band-pass, 5 Hz partial envelope
normalization with exponent -0.8, resonant band-stop shaping, cubic coring,
300 Hz low-pass, and a soft limiter with output gain 1.5.

AOSP writes the resulting waveform to an audio haptic channel. Moonlight does
not copy that Audio HAL integration. It processes each PCM channel with private
filter state, fuses the maximum absolute output, summarizes the waveform every
5 ms over a causal 40 ms rolling energy window, and combines that summary with
the existing spectral onset branch to produce the unchanged `AhHapticFrame`
ABI. The rolling window is project-specific output summarization; it suppresses
actuator-carrier phase ripple and does not add look-ahead.

## Implementation boundary

- `src/dsp/real_fft.cpp` contains a project-written radix-2 FFT with
  precomputed bit-reversal and twiddle tables.
- `src/core/feature_extractor.cpp` owns all fixed-capacity history and scratch
  buffers, computes each channel spectrum independently, then fuses power. This
  prevents antiphase waveform cancellation. Its GAME-only trailing medians and
  previous-spectrum maximum filter add no look-ahead and no process-time heap
  allocation; MUSIC continues to consume the pre-existing novelty fields.
- `src/core/causal_onset_detector.cpp` uses only current and past feature
  frames. It has no future-frame peak picker or model asset.
- `src/core/causal_rhythm_clock.cpp` uses only current and past activation,
  allocates no process-time memory, and never reinforces a predicted beat
  without current acoustic support.
- `src/dsp/aosp_haptic_envelope.cpp` has per-channel causal IIR state and no
  process-time allocation. Its source attribution is also recorded in
  `THIRD_PARTY_NOTICES.md`.
- The runtime path has no dynamic allocation after `ah_create()` and makes no
  platform, logging, callback, or lock call.

Any future external source, binary, model, or generated table must receive a
license review and be added to `THIRD_PARTY_NOTICES.md` before distribution.
