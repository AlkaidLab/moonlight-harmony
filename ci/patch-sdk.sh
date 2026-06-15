#!/usr/bin/env bash
# Apply SDK patches needed for CI builds with the public OpenHarmony SDK.
# This script:
#   1. Copies type declaration stubs from ci/sdk-stubs/
#   2. Creates missing shared libraries
#   3. Deduplicates id_defined.json
#   4. Patches hos-config.json for HarmonyOS 26.0.0(API 26) / 6.x targets
set -euo pipefail

SDK_HOME="${1:-$HOME/ohos-sdk}"
SDK_CONTENT_ROOT="$SDK_HOME"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STUBS_DIR="$SCRIPT_DIR/sdk-stubs"

if [ -d "$SDK_HOME/default/openharmony/ets" ] || [ -d "$SDK_HOME/default/hms/ets" ]; then
  DEVECO_LAYOUT=1
  SDK_CONTENT_ROOT="$SDK_HOME/default"
  OH_SDK_ROOT="$SDK_CONTENT_ROOT/openharmony"
  HMS_SDK_ROOT="$SDK_CONTENT_ROOT/hms"
elif [ -d "$SDK_HOME/openharmony/ets" ] || [ -d "$SDK_HOME/hms/ets" ]; then
  DEVECO_LAYOUT=1
  OH_SDK_ROOT="$SDK_CONTENT_ROOT/openharmony"
  HMS_SDK_ROOT="$SDK_CONTENT_ROOT/hms"
else
  DEVECO_LAYOUT=0
  OH_SDK_ROOT="$SDK_CONTENT_ROOT"
  HMS_SDK_ROOT="$SDK_CONTENT_ROOT"
fi

OH_ETS_API="$OH_SDK_ROOT/ets/api"
OH_ETS_KITS="$OH_SDK_ROOT/ets/kits"
OH_KIT_CONFIGS="$OH_SDK_ROOT/ets/build-tools/ets-loader/kit_configs"
OH_ETS_LOADER="$OH_SDK_ROOT/ets/build-tools/ets-loader"
OH_TOOLCHAINS="$OH_SDK_ROOT/toolchains"

HMS_ETS_API="$HMS_SDK_ROOT/ets/api"
HMS_ETS_KITS="$HMS_SDK_ROOT/ets/kits"
HMS_KIT_CONFIGS="$HMS_SDK_ROOT/ets/build-tools/ets-loader/kit_configs"
HMS_ETS_LOADER="$HMS_SDK_ROOT/ets/build-tools/ets-loader"
HMS_TOOLCHAINS="$HMS_SDK_ROOT/toolchains"

ETS_API="$OH_ETS_API"
ETS_KITS="$OH_ETS_KITS"
KIT_CONFIGS="$OH_KIT_CONFIGS"
ETS_LOADER="$OH_ETS_LOADER"
TOOLCHAINS="$OH_TOOLCHAINS"

echo "=== Applying SDK patches ==="

patch_ci_build_profile_versions() {
  [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
  [ -f "build-profile.json5" ] || return 0

  local target_version
  case "${CI_TARGET_API_VERSION:-}" in
    26) target_version="26.0.0" ;;
    24) target_version="6.1.1(24)" ;;
    23) target_version="6.1.0(23)" ;;
    22) target_version="6.0.2(22)" ;;
    20) target_version="6.0.0(20)" ;;
    *) return 0 ;;
  esac

  TARGET_SDK_VERSION="$target_version" python3 - <<'PY'
import os
import re

path = "build-profile.json5"
with open(path, encoding="utf-8") as f:
    text = f.read()

target_version = os.environ["TARGET_SDK_VERSION"]
text = re.sub(
    r'("compileSdkVersion"\s*:\s*")[^"]+(")',
    rf'\g<1>{target_version}\2',
    text,
)
text = re.sub(
    r'("targetSdkVersion"\s*:\s*")[^"]+(")',
    rf'\g<1>{target_version}\2',
    text,
)
text = re.sub(
    r'("compatibleSdkVersion"\s*:\s*")([0-9]+\.[0-9]+\.[0-9]+)(?:\([0-9]+\))?(")',
    r'\g<1>\2(12)\3',
    text,
)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
print(f"  Patched CI build-profile.json5 SDK versions: compile={target_version}, target={target_version}")
PY
}

patch_ci_build_profile_versions

kit_decl_exists() {
  local kit_name="$1"
  [ -f "$OH_ETS_KITS/$kit_name.d.ts" ] || [ -f "$OH_ETS_KITS/$kit_name.d.ets" ] || \
    [ -f "$HMS_ETS_KITS/$kit_name.d.ts" ] || [ -f "$HMS_ETS_KITS/$kit_name.d.ets" ]
}

cmdline_tool_roots() {
  for root in "${CMDLINE_TOOLS_HOME:-}" "${COMMANDLINE_TOOLS_HOME:-}" "$HOME/cmdline-tools"; do
    [ -n "$root" ] && [ -d "$root" ] && printf '%s\n' "$root"
  done | awk '!seen[$0]++'
}

loader_patch_roots() {
  while IFS= read -r root; do
    case "$root" in
      */DevEco-Studio.app/Contents/tools|*/DevEco-Studio.app/Contents/tools/*)
        echo "  Using official DevEco loader: $root"
        ;;
      *)
        printf '%s\n' "$root"
        ;;
    esac
  done
}

# ─── Patch hos-config.json for HarmonyOS targetSdkVersion aliases ───
echo "Patching hos-config.json..."
CMDLINE_ROOTS="$(cmdline_tool_roots || true)"
if [ -n "$CMDLINE_ROOTS" ]; then
printf '%s\n' "$CMDLINE_ROOTS" | while IFS= read -r root; do
find "$root" -name "hos-config.json" -type f
done | while read -r cfg; do
  CONFIG_PATH="$cfg" python3 -c "
import json, os
p = os.environ['CONFIG_PATH']
with open(p) as f:
    c = json.load(f)
before = json.dumps(c, sort_keys=True)
target_api = os.environ.get('CI_TARGET_API_VERSION', '24')
os_versions = c.setdefault('osVersionMapper', {})
os_names = c.setdefault('osNameMapper', {})
path_versions = c.setdefault('pathVersionMapper', {})

if target_api == '26':
    # Keep older CI command-line-tools aware of the latest local HarmonyOS Beta SDK.
    os_versions.setdefault('26.0.0', '26')
    os_names.setdefault('26.0.0', 'HarmonyOS 26.0.0')
    path_versions.setdefault('26.0.0', 'HarmonyOS-26.0.0')

# Keep older CI command-line-tools aware of the API 24 target used by build-profile.json5.
os_versions.setdefault('6.1.1', '24')
os_names.setdefault('6.1.1', 'HarmonyOS NEXT2')
path_versions.setdefault('6.1.1', 'HarmonyOS NEXT2')

# Public 6.1-Release SDK currently reports API 23, so CI may target 6.1.0(23).
os_versions.setdefault('6.1.0', '23')
os_names.setdefault('6.1.0', 'HarmonyOS NEXT2')
path_versions.setdefault('6.1.0', 'HarmonyOS NEXT2')

# Preserve the historical API 20 mapping used by the public OpenHarmony SDK fallback.
os_versions.setdefault('6.0.2', '22')
os_names.setdefault('6.0.2', 'HarmonyOS NEXT2')
path_versions.setdefault('6.0.2', 'HarmonyOS-NEXT2')
os_versions.setdefault('6.0.0', '20')
os_names.setdefault('6.0.0', 'HarmonyOS NEXT2')
path_versions.setdefault('6.0.0', 'HarmonyOS-NEXT2')
after = json.dumps(c, sort_keys=True)
if after != before:
    with open(p, 'w') as f:
        json.dump(c, f, indent=2)
    print('  Patched: ' + p)
else:
    print('  Already supports target versions: ' + p)
"
done
else
  echo "  No cmdline-tools directory; skipped"
fi

echo "Patching hmos-sdk-loader fallback..."
LOADER_ROOTS="$(printf '%s\n' "$CMDLINE_ROOTS" | loader_patch_roots | awk '/^  Using official DevEco loader:/ {next} {print}')"
CMDLINE_TOOL_ROOTS="$LOADER_ROOTS" python3 - <<'PY'
import os
import re

patched = False
candidates = []
roots = [p for p in os.environ.get('CMDLINE_TOOL_ROOTS', '').splitlines() if p]

def iter_loader_files(root):
  for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    dirnames[:] = [
      name for name in dirnames
      if not os.path.islink(os.path.join(dirpath, name))
    ]
    if 'hmos-sdk-loader.js' in filenames:
      yield os.path.join(dirpath, 'hmos-sdk-loader.js')

for root in roots:
  for loader in iter_loader_files(root):
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
    if not candidates:
        print('  No hmos-sdk-loader.js found; skipped')
    else:
        raise SystemExit('Could not patch hmos-sdk-loader.js; candidates=' + ','.join(candidates))
PY

# ─── aubio config.h ───
AUBIO_CONFIG="nativelib/src/main/cpp/aubio/src/config.h"
if [ ! -f "$AUBIO_CONFIG" ]; then
  cp "$STUBS_DIR/aubio-config.h" "$AUBIO_CONFIG"
  echo "  Created aubio config.h"
fi

# ─── libimage_transcoder_shared stub ───
case "$(uname -s)" in
  Darwin) IMAGE_TRANSCODER_LIB="libimage_transcoder_shared.dylib" ;;
  *) IMAGE_TRANSCODER_LIB="libimage_transcoder_shared.so" ;;
esac
if ! find "$SDK_HOME" -name "$IMAGE_TRANSCODER_LIB" -print -quit | grep -q .; then
  mkdir -p "$TOOLCHAINS/lib"
  if [ "$(uname -s)" = "Darwin" ]; then
    echo 'void __stub_placeholder(void) {}' | cc -dynamiclib -arch x86_64 -arch arm64 -x c - -o "$TOOLCHAINS/lib/$IMAGE_TRANSCODER_LIB"
  else
    echo 'void __stub_placeholder(void) {}' | cc -shared -x c - -o "$TOOLCHAINS/lib/$IMAGE_TRANSCODER_LIB"
  fi
  echo "  Created stub $IMAGE_TRANSCODER_LIB"
fi

# ─── Deduplicate id_defined.json ───
for ID_FILE in "$OH_TOOLCHAINS/id_defined.json" "$HMS_TOOLCHAINS/id_defined.json"; do
[ -f "$ID_FILE" ] || continue
  ID_FILE="$ID_FILE" python3 -c "
import json, os
p = os.path.expanduser(os.environ['ID_FILE'])
with open(p) as f:
    data = json.load(f)
def dedup_records(records):
    seen, deduped = set(), []
    for item in records:
        if isinstance(item, dict) and 'name' in item:
            key = (item.get('type'), item.get('name'))
        else:
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
    print('  No duplicates in ' + p)
"
done

# ─── ets-loader externalconfig.json ───
if [ "$DEVECO_LAYOUT" -eq 0 ]; then
for COMPONENTS_DIR in "$OH_ETS_LOADER/components" "$HMS_ETS_LOADER/components"; do
  [ -d "$COMPONENTS_DIR" ] || continue
  if [ ! -f "$COMPONENTS_DIR/externalconfig.json" ]; then
    cp "$STUBS_DIR/externalconfig.json" "$COMPONENTS_DIR/externalconfig.json"
    echo "  Created externalconfig.json in $COMPONENTS_DIR"
  fi
done
fi

# ─── @kit.RemoteCommunicationKit ───
if ! kit_decl_exists "@kit.RemoteCommunicationKit"; then
  [ ! -f "$HMS_KIT_CONFIGS/@kit.RemoteCommunicationKit.json" ] && \
    cp "$STUBS_DIR/kit.RemoteCommunicationKit.json" "$HMS_KIT_CONFIGS/@kit.RemoteCommunicationKit.json"
  [ ! -f "$HMS_ETS_API/@ohos.net.rcp.d.ts" ] && \
    cp "$STUBS_DIR/ohos.net.rcp.d.ts" "$HMS_ETS_API/@ohos.net.rcp.d.ts"
  cp "$STUBS_DIR/kit.RemoteCommunicationKit.d.ts" "$HMS_ETS_API/@kit.RemoteCommunicationKit.d.ts"
  echo "  Applied RemoteCommunicationKit stubs"
else
  echo "  Using SDK RemoteCommunicationKit declarations"
fi

# ─── @kit.NetworkKit declare module ───
if ! kit_decl_exists "@kit.NetworkKit"; then
  cp "$STUBS_DIR/kit.NetworkKit.d.ts" "$ETS_API/@kit.NetworkKit.d.ts"
  echo "  Applied NetworkKit declare module"
else
  echo "  Using SDK NetworkKit declarations"
fi

# ─── @kit.NetworkBoostKit ───
if ! kit_decl_exists "@kit.NetworkBoostKit"; then
  cp "$STUBS_DIR/kit.NetworkBoostKit.json" "$HMS_KIT_CONFIGS/@kit.NetworkBoostKit.json"
  [ ! -f "$HMS_ETS_API/@ohos.networkBoost.netQuality.d.ts" ] && \
    cp "$STUBS_DIR/ohos.networkBoost.netQuality.d.ts" "$HMS_ETS_API/@ohos.networkBoost.netQuality.d.ts"
  [ ! -f "$HMS_ETS_API/@ohos.networkBoost.netBoost.d.ts" ] && \
    cp "$STUBS_DIR/ohos.networkBoost.netBoost.d.ts" "$HMS_ETS_API/@ohos.networkBoost.netBoost.d.ts"
  cp "$STUBS_DIR/kit.NetworkBoostKit.d.ts" "$HMS_ETS_API/@kit.NetworkBoostKit.d.ts"
  cp "$STUBS_DIR/kit.NetworkBoostKit.d.ts" "$HMS_ETS_KITS/@kit.NetworkBoostKit.d.ts"
  echo "  Applied NetworkBoostKit stubs"
else
  echo "  Using SDK NetworkBoostKit declarations"
  KIT_NETWORKBOOST_DTS="$HMS_ETS_KITS/@kit.NetworkBoostKit.d.ts"
  KIT_NETWORKBOOST_CONFIG="$HMS_KIT_CONFIGS/@kit.NetworkBoostKit.json"
  if [ -f "$KIT_NETWORKBOOST_DTS" ] && ! grep -q "netBoost" "$KIT_NETWORKBOOST_DTS"; then
    cp "$STUBS_DIR/kit.NetworkBoostKit.d.ts" "$KIT_NETWORKBOOST_DTS"
    echo "  Patched NetworkBoostKit netBoost export"
  fi
  if [ -f "$HMS_ETS_API/@kit.NetworkBoostKit.d.ts" ] && ! grep -q "netBoost" "$HMS_ETS_API/@kit.NetworkBoostKit.d.ts"; then
    cp "$STUBS_DIR/kit.NetworkBoostKit.d.ts" "$HMS_ETS_API/@kit.NetworkBoostKit.d.ts"
  fi
  if [ -f "$KIT_NETWORKBOOST_CONFIG" ] && ! grep -q '"netBoost"' "$KIT_NETWORKBOOST_CONFIG"; then
    cp "$STUBS_DIR/kit.NetworkBoostKit.json" "$KIT_NETWORKBOOST_CONFIG"
    echo "  Patched NetworkBoostKit netBoost kit config"
  fi
  [ ! -f "$HMS_ETS_API/@ohos.networkBoost.netBoost.d.ts" ] && \
    cp "$STUBS_DIR/ohos.networkBoost.netBoost.d.ts" "$HMS_ETS_API/@ohos.networkBoost.netBoost.d.ts"
  NETBOOST_DTS=""
  for candidate in "$HMS_ETS_API/@hms.networkboost.netBoost.d.ts" "$HMS_ETS_API/@ohos.networkBoost.netBoost.d.ts"; do
    [ -f "$candidate" ] && NETBOOST_DTS="$candidate" && break
  done
  if [ -n "$NETBOOST_DTS" ] && ! grep -q "setDataFlowDesc" "$NETBOOST_DTS"; then
    cat "$STUBS_DIR/networkboost-dataflow-patch.d.ts" >> "$NETBOOST_DTS"
    echo "  Patched NetworkBoost data-flow declarations"
  fi
fi

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
if ! kit_decl_exists "@kit.ScanKit"; then
  [ ! -f "$HMS_KIT_CONFIGS/@kit.ScanKit.json" ] && \
    cp "$STUBS_DIR/kit.ScanKit.json" "$HMS_KIT_CONFIGS/@kit.ScanKit.json"
  cp "$STUBS_DIR/kit.ScanKit.d.ts" "$HMS_ETS_API/@kit.ScanKit.d.ts"
  cp "$STUBS_DIR/ohos.scan.scanCore.d.ts" "$HMS_ETS_API/@ohos.scan.scanCore.d.ts"
  cp "$STUBS_DIR/ohos.scan.scanBarcode.d.ts" "$HMS_ETS_API/@ohos.scan.scanBarcode.d.ts"
  cp "$STUBS_DIR/ohos.scan.generateBarcode.d.ts" "$HMS_ETS_API/@ohos.scan.generateBarcode.d.ts"
  echo "  Applied ScanKit stubs"
else
  echo "  Using SDK ScanKit declarations"
fi

SCAN_KIT_CONFIG_FOUND=0
for SCAN_KIT_CONFIG in "$OH_KIT_CONFIGS/@kit.ScanKit.json" "$HMS_KIT_CONFIGS/@kit.ScanKit.json"; do
  [ -f "$SCAN_KIT_CONFIG" ] || continue
  SCAN_KIT_CONFIG_FOUND=1
  SCAN_KIT_CONFIG="$SCAN_KIT_CONFIG" python3 - <<'PY'
import json
import os

p = os.environ['SCAN_KIT_CONFIG']
with open(p) as f:
    data = json.load(f)
symbols = data.setdefault('symbols', {})
if 'generateBarcode' in symbols:
    print('  ScanKit generateBarcode export already present: ' + p)
else:
    symbols['generateBarcode'] = {
        'source': '@ohos.scan.generateBarcode.d.ts',
        'bindings': 'default',
    }
    with open(p, 'w') as f:
        json.dump(data, f, indent=2)
    print('  Patched ScanKit generateBarcode export: ' + p)
PY
done
if [ "$SCAN_KIT_CONFIG_FOUND" -eq 0 ]; then
  mkdir -p "$HMS_KIT_CONFIGS"
  cp "$STUBS_DIR/kit.ScanKit.json" "$HMS_KIT_CONFIGS/@kit.ScanKit.json"
  echo "  Created ScanKit kit config"
fi
for SCAN_KIT_API in "$OH_ETS_API" "$HMS_ETS_API"; do
  [ -d "$SCAN_KIT_API" ] || continue
  [ ! -f "$SCAN_KIT_API/@ohos.scan.generateBarcode.d.ts" ] && \
    cp "$STUBS_DIR/ohos.scan.generateBarcode.d.ts" "$SCAN_KIT_API/@ohos.scan.generateBarcode.d.ts"
done

# ─── @kit.ShareKit ───
if ! kit_decl_exists "@kit.ShareKit"; then
  [ ! -f "$HMS_KIT_CONFIGS/@kit.ShareKit.json" ] && \
    cp "$STUBS_DIR/kit.ShareKit.json" "$HMS_KIT_CONFIGS/@kit.ShareKit.json"
  cp "$STUBS_DIR/kit.ShareKit.d.ts" "$HMS_ETS_API/@kit.ShareKit.d.ts"
  cp "$STUBS_DIR/ohos.share.systemShare.d.ts" "$HMS_ETS_API/@ohos.share.systemShare.d.ts"
  echo "  Applied ShareKit stubs"
else
  echo "  Using SDK ShareKit declarations"
fi

# ─── DevKeySecret (CI-only placeholder) ───
DEV_KEY_SECRET="entry/src/main/ets/config/DevKeySecret.ets"
if [ ! -f "$DEV_KEY_SECRET" ]; then
  mkdir -p "$(dirname "$DEV_KEY_SECRET")"
  cp "${DEV_KEY_SECRET}.example" "$DEV_KEY_SECRET"
  echo "  Created DevKeySecret from example"
fi

# ─── GitHubOAuthConfig (CI/local placeholder) ───
GITHUB_OAUTH_CONFIG="entry/src/main/ets/config/GitHubOAuthConfig.ets"
if [ ! -f "$GITHUB_OAUTH_CONFIG" ]; then
  mkdir -p "$(dirname "$GITHUB_OAUTH_CONFIG")"
  cp "${GITHUB_OAUTH_CONFIG}.example" "$GITHUB_OAUTH_CONFIG"
  echo "  Created GitHubOAuthConfig from example"
fi

echo "✅ SDK patches applied"
