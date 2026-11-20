#!/usr/bin/env python3
"""Ensure CI emits the system-module URL expected by the HarmonyOS runtime."""
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as hap:
    abc = hap.read('ets/modules.abc')
if b'@hms:collaboration.rcp' not in abc or b'@hms.collaboration.rcp' in abc:
    raise SystemExit('CI HAP does not contain the normalized HMS RCP module URL')
print('CI HAP contains the normalized HMS RCP module URL')
