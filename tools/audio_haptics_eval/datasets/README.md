# Real-world dataset boundary

Audio under test may be copyrighted, private, or licensed only for internal
evaluation. Do not commit it to this repository and do not upload raw PCM as
telemetry.

Copy `manifest.template.csv` to a local dataset directory, store WAV and label
files below that directory, document the rights basis, and calculate SHA-256
for both files. `validate_dataset.py` rejects missing rights metadata, path
escapes, format mismatches, unsorted labels, count mismatches, and hash changes.

Only manifest metadata, aggregate metrics, and event-level differences should
be shared by default. Redistributable audio requires an explicit `yes` in the
manifest and independent confirmation that the stated rights permit it.
