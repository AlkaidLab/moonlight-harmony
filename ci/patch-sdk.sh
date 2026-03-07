#!/usr/bin/env bash
# Apply SDK patches needed for CI builds with the public OpenHarmony SDK.
# This script:
#   1. Copies type declaration stubs from ci/sdk-stubs/
#   2. Creates missing shared libraries
#   3. Deduplicates id_defined.json
#   4. Patches hos-config.json for API 20
set -euo pipefail

SDK_HOME="${1:-$HOME/ohos-sdk}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STUBS_DIR="$SCRIPT_DIR/sdk-stubs"
ETS_API="$SDK_HOME/ets/api"
KIT_CONFIGS="$SDK_HOME/ets/build-tools/ets-loader/kit_configs"
ETS_LOADER="$SDK_HOME/ets/build-tools/ets-loader"

echo "=== Applying SDK patches ==="

# ─── Patch hos-config.json for API 20 ───
echo "Patching hos-config.json..."
find ~/cmdline-tools -name "hos-config.json" -type f | while read -r cfg; do
  CONFIG_PATH="$cfg" python3 -c "
import json, os
p = os.environ['CONFIG_PATH']
with open(p) as f:
    c = json.load(f)
c.setdefault('osVersionMapper', {})['6.0.0'] = '20'
c.setdefault('osNameMapper', {})['6.0.0'] = 'HarmonyOS NEXT3'
c.setdefault('pathVersionMapper', {})['6.0.0'] = 'HarmonyOS-NEXT3'
with open(p, 'w') as f:
    json.dump(c, f, indent=2)
print('  Patched: ' + p)
"
done

# ─── aubio config.h ───
AUBIO_CONFIG="nativelib/src/main/cpp/aubio/src/config.h"
if [ ! -f "$AUBIO_CONFIG" ]; then
  cp "$STUBS_DIR/aubio-config.h" "$AUBIO_CONFIG"
  echo "  Created aubio config.h"
fi

# ─── libimage_transcoder_shared.so stub ───
for so_name in libimage_transcoder_shared.so; do
  if ! find "$SDK_HOME" -name "$so_name" -print -quit | grep -q .; then
    echo 'void __stub_placeholder(void) {}' | gcc -shared -x c - -o "$SDK_HOME/toolchains/lib/$so_name"
    echo "  Created stub $so_name"
  fi
done

# ─── Deduplicate id_defined.json ───
ID_FILE="$SDK_HOME/toolchains/id_defined.json"
if [ -f "$ID_FILE" ]; then
  python3 -c "
import json, os
p = os.path.expanduser('$ID_FILE')
with open(p) as f:
    data = json.load(f)
def dedup_records(records):
    seen, deduped = set(), []
    for item in records:
        key = json.dumps(item, sort_keys=True) if isinstance(item, dict) else str(item)
        if key not in seen:
            seen.add(key)
            deduped.append(item)
    for i, item in enumerate(deduped):
        if isinstance(item, dict) and 'order' in item:
            item['order'] = i
    return deduped, len(records) - len(deduped)
changed = False
if isinstance(data, dict):
    for k, v in data.items():
        if isinstance(v, list) and len(v) > 0:
            deduped, removed = dedup_records(v)
            if removed:
                data[k] = deduped
                changed = True
                print(f'  {k}: removed {removed} duplicates')
if changed:
    with open(p, 'w') as f:
        json.dump(data, f, indent=2)
else:
    print('  No duplicates in id_defined.json')
"
fi

# ─── ets-loader externalconfig.json ───
COMPONENTS_DIR="$ETS_LOADER/components"
if [ ! -f "$COMPONENTS_DIR/externalconfig.json" ]; then
  cp "$STUBS_DIR/externalconfig.json" "$COMPONENTS_DIR/externalconfig.json"
  echo "  Created externalconfig.json"
fi

# ─── @kit.RemoteCommunicationKit ───
[ ! -f "$KIT_CONFIGS/@kit.RemoteCommunicationKit.json" ] && \
  cp "$STUBS_DIR/kit.RemoteCommunicationKit.json" "$KIT_CONFIGS/@kit.RemoteCommunicationKit.json"
[ ! -f "$ETS_API/@ohos.net.rcp.d.ts" ] && \
  cp "$STUBS_DIR/ohos.net.rcp.d.ts" "$ETS_API/@ohos.net.rcp.d.ts"
cp "$STUBS_DIR/kit.RemoteCommunicationKit.d.ts" "$ETS_API/@kit.RemoteCommunicationKit.d.ts"
echo "  Applied RemoteCommunicationKit stubs"

# ─── @kit.NetworkKit declare module ───
cp "$STUBS_DIR/kit.NetworkKit.d.ts" "$ETS_API/@kit.NetworkKit.d.ts"
echo "  Applied NetworkKit declare module"

# ─── Socket stub (only if SDK is missing the file) ───
if [ ! -f "$ETS_API/@ohos.net.socket.d.ts" ]; then
  cp "$STUBS_DIR/ohos.net.socket.d.ts" "$ETS_API/@ohos.net.socket.d.ts"
  echo "  Created socket stub"
fi

# ─── display.getBrightnessInfo patch ───
DISPLAY_DTS=$(find "$ETS_API" -name "@ohos.display.d.ts" -o -name "@ohos.display.d.ets" 2>/dev/null | head -1)
if [ -n "$DISPLAY_DTS" ] && ! grep -q "getBrightnessInfo" "$DISPLAY_DTS"; then
  cat "$STUBS_DIR/display-brightness-patch.d.ts" >> "$DISPLAY_DTS"
  echo "  Patched display module"
fi

echo "✅ SDK patches applied"
