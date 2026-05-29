#!/usr/bin/env bash
# Apply SDK patches needed for CI builds with the public OpenHarmony SDK.
# This script:
#   1. Copies type declaration stubs from ci/sdk-stubs/
#   2. Creates missing shared libraries
#   3. Deduplicates id_defined.json
#   4. Patches hos-config.json for HarmonyOS 6.1.1(API 24)
set -euo pipefail

SDK_HOME="${1:-$HOME/ohos-sdk}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STUBS_DIR="$SCRIPT_DIR/sdk-stubs"
ETS_API="$SDK_HOME/ets/api"
KIT_CONFIGS="$SDK_HOME/ets/build-tools/ets-loader/kit_configs"
ETS_LOADER="$SDK_HOME/ets/build-tools/ets-loader"

echo "=== Applying SDK patches ==="

# ─── Patch hos-config.json for API 24 targetSdkVersion ───
echo "Patching hos-config.json..."
find ~/cmdline-tools -name "hos-config.json" -type f | while read -r cfg; do
  CONFIG_PATH="$cfg" python3 -c "
import json, os
p = os.environ['CONFIG_PATH']
with open(p) as f:
    c = json.load(f)
os_versions = c.setdefault('osVersionMapper', {})
os_names = c.setdefault('osNameMapper', {})
path_versions = c.setdefault('pathVersionMapper', {})

# Keep older CI command-line-tools aware of the API 24 target used by build-profile.json5.
os_versions['6.1.1'] = '24'
os_names['6.1.1'] = os_names.get('6.1.1', 'HarmonyOS NEXT2')
path_versions['6.1.1'] = path_versions.get('6.1.1', 'HarmonyOS NEXT2')

# Public 6.1-Release SDK currently reports API 23, so CI may target 6.1.0(23).
os_versions['6.1.0'] = '23'
os_names['6.1.0'] = os_names.get('6.1.0', 'HarmonyOS NEXT2')
path_versions['6.1.0'] = path_versions.get('6.1.0', 'HarmonyOS NEXT2')

# Preserve the historical API 20 mapping used by the public OpenHarmony SDK fallback.
os_versions['6.0.2'] = '22'
os_names['6.0.2'] = os_names.get('6.0.2', 'HarmonyOS NEXT2')
path_versions['6.0.2'] = path_versions.get('6.0.2', 'HarmonyOS-NEXT2')
os_versions.setdefault('6.0.0', '20')
os_names.setdefault('6.0.0', 'HarmonyOS NEXT2')
path_versions.setdefault('6.0.0', 'HarmonyOS-NEXT2')
with open(p, 'w') as f:
    json.dump(c, f, indent=2)
print('  Patched: ' + p)
"
done

echo "Patching hmos-sdk-loader fallback..."
python3 - <<'PY'
import glob
import os
import re

patched = False
candidates = []
for loader in glob.glob(os.path.expanduser('~/cmdline-tools/**/hmos-sdk-loader.js'), recursive=True):
    candidates.append(loader)
    with open(loader, encoding='utf-8') as f:
        text = f.read()
    if '.getLocalSdks(`${' in text and '.api}`)' in text:
        print('  Already patched: ' + loader)
        patched = True
        continue
    pattern = re.compile(
        r'const\s+([A-Za-z_$][\w$]*)=this\.ohosSdkInfoHandler\.getLocalSdks\(([^;]+)\);'
        r'this\.checkComponentExistence\(([A-Za-z_$][\w$]*),\1,!1\)\|\|_log\.printErrorExit\("SDK_COMPONENT_MISSING"\);'
    )
    match = pattern.search(text)
    if not match:
        idx = text.find('ohosSdkInfoHandler.getLocalSdks')
        if idx >= 0:
            print('  Unmatched loader snippet: ' + text[max(0, idx - 160):idx + 260])
        continue
    sdk_map, version_expr, components = match.groups()
    source = 'e'
    source_match = re.search(r'\$\{([A-Za-z_$][\w$]*)\.(?:fullVersion|version)\}', version_expr)
    if not source_match:
        source_match = re.search(r'([A-Za-z_$][\w$]*)\.(?:fullVersion|version)', version_expr)
    if source_match:
        source = source_match.group(1)
    replacement = (
        f'let {sdk_map}=this.ohosSdkInfoHandler.getLocalSdks({version_expr});'
        f'if(!this.checkComponentExistence({components},{sdk_map},!1)&&{source}.api)'
        f'{sdk_map}=this.ohosSdkInfoHandler.getLocalSdks(`${{{source}.api}}`);'
        f'this.checkComponentExistence({components},{sdk_map},!1)||_log.printErrorExit("SDK_COMPONENT_MISSING");'
    )
    with open(loader, 'w', encoding='utf-8') as f:
        f.write(text[:match.start()] + replacement + text[match.end():])
    print('  Patched: ' + loader)
    patched = True

if not patched:
    raise SystemExit('Could not patch hmos-sdk-loader.js; candidates=' + ','.join(candidates))
PY

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

# ─── @kit.NetworkBoostKit ───
[ ! -f "$KIT_CONFIGS/@kit.NetworkBoostKit.json" ] && \
  cp "$STUBS_DIR/kit.NetworkBoostKit.json" "$KIT_CONFIGS/@kit.NetworkBoostKit.json"
[ ! -f "$ETS_API/@ohos.networkBoost.netQuality.d.ts" ] && \
  cp "$STUBS_DIR/ohos.networkBoost.netQuality.d.ts" "$ETS_API/@ohos.networkBoost.netQuality.d.ts"
cp "$STUBS_DIR/kit.NetworkBoostKit.d.ts" "$ETS_API/@kit.NetworkBoostKit.d.ts"
echo "  Applied NetworkBoostKit stubs"

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

# ─── @kit.ScanKit ───
[ ! -f "$KIT_CONFIGS/@kit.ScanKit.json" ] && \
  cp "$STUBS_DIR/kit.ScanKit.json" "$KIT_CONFIGS/@kit.ScanKit.json"
cp "$STUBS_DIR/kit.ScanKit.d.ts" "$ETS_API/@kit.ScanKit.d.ts"
cp "$STUBS_DIR/ohos.scan.scanCore.d.ts" "$ETS_API/@ohos.scan.scanCore.d.ts"
cp "$STUBS_DIR/ohos.scan.scanBarcode.d.ts" "$ETS_API/@ohos.scan.scanBarcode.d.ts"
echo "  Applied ScanKit stubs"

# ─── @kit.ShareKit ───
[ ! -f "$KIT_CONFIGS/@kit.ShareKit.json" ] && \
  cp "$STUBS_DIR/kit.ShareKit.json" "$KIT_CONFIGS/@kit.ShareKit.json"
cp "$STUBS_DIR/kit.ShareKit.d.ts" "$ETS_API/@kit.ShareKit.d.ts"
cp "$STUBS_DIR/ohos.share.systemShare.d.ts" "$ETS_API/@ohos.share.systemShare.d.ts"
echo "  Applied ShareKit stubs"

# ─── DevKeySecret (CI-only placeholder) ───
DEV_KEY_SECRET="entry/src/main/ets/config/DevKeySecret.ets"
if [ ! -f "$DEV_KEY_SECRET" ]; then
  mkdir -p "$(dirname "$DEV_KEY_SECRET")"
  cp "${DEV_KEY_SECRET}.example" "$DEV_KEY_SECRET"
  echo "  Created DevKeySecret from example"
fi

echo "✅ SDK patches applied"
