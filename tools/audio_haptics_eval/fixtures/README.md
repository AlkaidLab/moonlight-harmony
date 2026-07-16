# P0 deterministic fixtures

The fixtures are generated instead of committed as binary WAV files. Run:

```bash
python tools/audio_haptics_eval/generate_fixtures.py
```

The generator always uses 48 kHz signed PCM16 and fixed random seeds.

| Case | Type | Purpose |
|---|---|---|
| `impulse_train_mono` | Positive | Broadband transient timing and recall |
| `kick_train_stereo` | Positive | Low-frequency impact and stereo input |
| `antiphase_impulses_stereo` | Edge | Exposes cancellation caused by waveform downmix |
| `silence_then_hit_mono` | Edge | Detector state recovery after digital silence |
| `steady_tone_stereo` | Negative | False triggers on continuous low-frequency audio |
| `speech_like_mono` | Negative | False triggers on deterministic speech-like audio |

Each WAV has a sibling `*.labels.csv` file with this schema:

```text
time_ms,event_type,importance
```

Generated fixtures are local test artifacts and are ignored by Git. They are a
smoke-test baseline, not a replacement for the licensed real-world evaluation
set required before the aubio removal gate.
