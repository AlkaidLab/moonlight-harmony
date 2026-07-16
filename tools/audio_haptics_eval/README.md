# Audio haptics P0 evaluator

This host tool establishes the reproducible aubio baseline required by Phase
P0 of `docs/AUDIO_HAPTICS_SDK_IMPLEMENTATION_PLAN.md`.

It deliberately links the current GPL aubio subset and compares it with the
current clean-room `SpectralOnsetDetector` and the public ABI of the new SDK.
The evaluator belongs to the GPL host project and must not be copied into the
Apache-2.0 SDK.

## One-command baseline

Requirements: CMake 3.20+, Ninja, a C/C++17 compiler, and Python 3.10+.

```bash
python tools/audio_haptics_eval/run_baseline.py
```

This command:

1. Configures and builds a Release host executable.
2. Generates deterministic PCM16 WAV fixtures and labels.
3. Runs aubio, the current native detector, and the SDK Core on every fixture.
4. Writes per-case event CSV/JSON and aggregate `baseline.csv/json` under
   `tools/audio_haptics_eval/out`.
5. Validates dataset hashes/rights metadata and writes `shadow_events.csv`,
   `shadow_report.json`, and a human-readable `shadow_report.md`.

## Run one file

```bash
tools/audio_haptics_eval/build/audio_haptics_eval \
  --input sample.wav \
  --labels sample.labels.csv \
  --backend all \
  --events-out events.csv \
  --summary-out summary.json
```

Input is little-endian RIFF PCM16 with 1–8 interleaved channels. Event
timestamps describe when the detector returned an onset, measured at the end
of the input hop. This intentionally includes algorithmic lookahead and is the
timestamp used for P0 latency comparisons.

## Output metrics

- Precision, recall and F1 use greedy one-to-one matching within 50 ms.
- Timing error is detector output time minus the annotated onset time.
- `call_pXX_us` measures one `ProcessFrame` call, excluding initialization and
  WAV I/O.
- `realtime_factor` is audio duration divided by median processing time.

Synthetic fixture scores are diagnostic. Removal gates must be evaluated again
on the versioned, licensed real-world dataset and on target mobile hardware.

## Real-world dataset

Keep licensed WAV files outside Git and create a manifest using the schema in
`datasets/manifest.template.csv`. Every item records its rights basis,
redistribution policy, expected haptic behavior, critical-event status, split,
and SHA-256 hashes. Validate and run it with:

```bash
python tools/audio_haptics_eval/validate_dataset.py --manifest <dataset>/manifest.csv --require-real-world
python tools/audio_haptics_eval/run_baseline.py --fixtures-dir <dataset> --manifest <dataset>/manifest.csv --skip-generate
```

The shadow report stores event timestamps, descriptors, metrics, and gate
results only; it does not copy raw PCM into the report directory.

The `sdk_core` backend exercises the portable P2 C ABI implementation: a
channel-aware STFT, adaptive normalization, causal onset detector, and haptic
IR mapper. It is evaluated without changing the Harmony production path.

# Device-side shadow capture

The device path logs aggregate counters and fixed latency buckets only. It never
captures PCM. With an internal HAP where the runtime shadow switch is enabled,
capture one reproducible scenario with:

```powershell
python capture_device_shadow.py `
  --output-dir out/device `
  --device-class phone_performance `
  --scenario-id game-combat-01 `
  --scenario-category game_strong_transient `
  --duration-seconds 60
```

The command discovers a single HDC target, hashes its serial, queries non-content
device properties, filters `[HAPTICS_SHADOW]` lines, and emits metadata plus JSON
and Markdown summaries. Build the admission report after collecting all required
scenarios on at least two device classes:

```powershell
python device_shadow_gate.py out/device --output-dir out/device-admission
```

The admission gate requires real captures, two distinct devices/classes, all
six scenario categories on each class, zero processing errors, consistent
latency histograms, and a P99
processing-time bucket upper bound no greater than 500 microseconds.
