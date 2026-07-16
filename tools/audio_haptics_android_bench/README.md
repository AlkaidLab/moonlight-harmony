# Android audio haptics SDK Core benchmark

This GPL-3.0 host/deployment tool cross-compiles the Apache-2.0 portable SDK
Core with the Android NDK, deploys a static arm64 executable through ADB, runs
five deterministic workloads, and emits JSON plus Markdown reports.

It is a CPU latency, stability, and C ABI gate. It does not evaluate real-world
event accuracy or actuator feel.

## Run

Requirements: CMake, Ninja, an installed Android NDK, ADB, and one authorized
Android device.

```powershell
python tools/audio_haptics_android_bench/run_android_benchmark.py `
  --duration-seconds 10 `
  --device-class android_phone_performance `
  --output-dir tools/audio_haptics_android_bench/out/formal
```

The runner automatically:

1. Selects one authorized ADB device.
2. Selects the newest complete NDK installation.
3. Builds a static `arm64-v8a` executable.
4. Pushes it to `/data/local/tmp` and runs every workload.
5. Hashes the device serial instead of storing it.
6. Records model, Android/API/ABI, NDK, binary hash, battery temperature, and
   per-call latency distributions.

Formal admission requires at least 10 wall-clock seconds per scenario, zero
SDK errors, and P99 `ah_process_i16()` latency no greater than 500 microseconds
for every scenario. Build products and reports under `build/` and `out/` are
intentionally ignored by Git.
