#!/usr/bin/env bash
# Normalize the downloaded OpenHarmony SDK layout for hvigor.
#
# hvigor's parseSdks scans $SDK_HOME for sdk-pkg.json (flat layout).
# OhosBaseSdkInfoHandler.getLocalSdks() remaps component locations:
#   OPENHARMONY → $SDK_HOME/toolchains/openharmony/<component>/
#   HARMONYOS   → $SDK_HOME/toolchains/hms/<component>/
# checkComponentExistence verifies oh-uni-package.json / uni-package.json
# at the REMAPPED locations. We keep flat layout for scanning and create
# symlinks at the remapped locations for the existence check.
set -euo pipefail

SDK_HOME="${1:-$HOME/ohos-sdk}"

echo "=== Normalizing SDK layout ==="

# ─── Determine API version ───
PKG_FILE=$(find "$SDK_HOME" -maxdepth 4 -name "oh-uni-package.json" -type f | head -1)
if [ -n "$PKG_FILE" ]; then
  SOURCE_API_VER=$(python3 -c "import json; print(json.load(open('$PKG_FILE'))['apiVersion'])")
  SDK_PKG_VERSION=$(python3 -c "import json; print(json.load(open('$PKG_FILE')).get('version', '6.1.0.47'))")
else
  SOURCE_API_VER=$(find "$SDK_HOME/openharmony" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | head -1)
  SDK_PKG_VERSION="6.1.0.47"
fi
API_VER="${CI_TARGET_API_VERSION:-24}"
echo "Source SDK API version: $SOURCE_API_VER"
echo "Target SDK API version: $API_VER"
[ -z "$SOURCE_API_VER" ] && { echo "ERROR: Could not determine SDK source API version"; exit 1; }
[ -z "$API_VER" ] && { echo "ERROR: Could not determine SDK target API version"; exit 1; }
echo "SDK package version: $SDK_PKG_VERSION"

case "$API_VER" in
  24) HOS_PLATFORM_VERSION="6.1.1"; HOS_TARGET_SDK_VERSION="6.1.1(24)" ;;
  23) HOS_PLATFORM_VERSION="6.1.0"; HOS_TARGET_SDK_VERSION="6.1.0(23)" ;;
  22) HOS_PLATFORM_VERSION="6.0.2"; HOS_TARGET_SDK_VERSION="6.0.2(22)" ;;
  20) HOS_PLATFORM_VERSION="6.0.0"; HOS_TARGET_SDK_VERSION="6.0.0(20)" ;;
  *) echo "ERROR: Unsupported SDK API version: $API_VER"; exit 1 ;;
esac

# ─── Step 1: Flatten nested openharmony/<ver> layout to root ───
# hvigor 6.24 treats a sdk-pkg.json with apiVersion as a platform container and
# expands it into <container>/{openharmony,hms}/<component>. Keep only
# toolchains/sdk-pkg.json so the loader probes the remapped locations created
# below instead of wrong paths like ets/openharmony/native.
for comp in ets js native toolchains previewer; do
  ROOT_DIR="$SDK_HOME/$comp"
  OH_NESTED_DIR="$SDK_HOME/openharmony/$SOURCE_API_VER/$comp"
  if [ ! -d "$ROOT_DIR" ] && [ -d "$OH_NESTED_DIR" ]; then
    mv "$OH_NESTED_DIR" "$ROOT_DIR"
    echo "  Flattened $comp"
  fi
done
rm -rf "$SDK_HOME/openharmony" "$SDK_HOME/HarmonyOS"

# ─── Step 2: Ensure oh-uni-package.json and sdk-pkg.json in each component ───
for comp in ets js native toolchains previewer; do
  COMP_DIR="$SDK_HOME/$comp"
  [ ! -d "$COMP_DIR" ] && mkdir -p "$COMP_DIR"

  if [ ! -f "$COMP_DIR/oh-uni-package.json" ]; then
    cat > "$COMP_DIR/oh-uni-package.json" << EOF
{"apiVersion":"$API_VER","fullApiVersion":"$API_VER","platformVersion":"$HOS_PLATFORM_VERSION","displayName":"${comp^}","meta":{"metaVersion":"3.0.0"},"path":"$comp","releaseType":"Beta1","version":"$SDK_PKG_VERSION"}
EOF
  fi
  COMPONENT_FILE="$COMP_DIR/oh-uni-package.json" API_VER="$API_VER" HOS_PLATFORM_VERSION="$HOS_PLATFORM_VERSION" python3 -c "
import json, os
p = os.environ['COMPONENT_FILE']
with open(p) as f:
    pkg = json.load(f)
pkg['apiVersion'] = os.environ['API_VER']
pkg['fullApiVersion'] = os.environ['API_VER']
pkg['platformVersion'] = os.environ['HOS_PLATFORM_VERSION']
with open(p, 'w') as f:
    json.dump(pkg, f)
"

  if [ "$comp" != "toolchains" ]; then
    rm -f "$COMP_DIR/sdk-pkg.json"
  else
    python3 -c "
import json
with open('$COMP_DIR/oh-uni-package.json') as f:
    pkg = json.load(f)
meta_ver = pkg.get('meta', {}).get('metaVersion', '3.0.0')
data = {k: v for k, v in pkg.items() if k != 'meta'}
with open('$COMP_DIR/sdk-pkg.json', 'w') as f:
    json.dump({'data': data, 'meta': {'version': meta_ver}}, f)
"
  fi
done

# ─── Step 3: Create OPENHARMONY remapped locations ───
rm -rf "$SDK_HOME/toolchains/openharmony"
mkdir -p "$SDK_HOME/toolchains/openharmony"
for comp in ets js native previewer; do
  [ -d "$SDK_HOME/$comp" ] && ln -sf "$SDK_HOME/$comp" "$SDK_HOME/toolchains/openharmony/$comp"
done
mkdir -p "$SDK_HOME/toolchains/openharmony/toolchains"
for item in "$SDK_HOME/toolchains/"*; do
  bname=$(basename "$item")
  case "$bname" in openharmony|hms) continue ;; esac
  ln -sf "$item" "$SDK_HOME/toolchains/openharmony/toolchains/$bname"
done
echo "  Created toolchains/openharmony/"

# ─── Step 4: Create HARMONYOS (HMS) remapped locations ───
rm -rf "$SDK_HOME/toolchains/hms"
mkdir -p "$SDK_HOME/toolchains/hms"
for comp in ets native previewer; do
  [ -d "$SDK_HOME/$comp" ] && ln -sf "$SDK_HOME/$comp" "$SDK_HOME/toolchains/hms/$comp"
  if [ ! -f "$SDK_HOME/$comp/uni-package.json" ]; then
    cat > "$SDK_HOME/$comp/uni-package.json" << EOF
{"apiVersion":"$API_VER","fullApiVersion":"$API_VER","platformVersion":"$HOS_PLATFORM_VERSION","displayName":"${comp^}","meta":{"metaVersion":"3.0.0"},"path":"$comp","releaseType":"Beta1","version":"$SDK_PKG_VERSION"}
EOF
  fi
  COMPONENT_FILE="$SDK_HOME/$comp/uni-package.json" API_VER="$API_VER" HOS_PLATFORM_VERSION="$HOS_PLATFORM_VERSION" python3 -c "
import json, os
p = os.environ['COMPONENT_FILE']
with open(p) as f:
    pkg = json.load(f)
pkg['apiVersion'] = os.environ['API_VER']
pkg['fullApiVersion'] = os.environ['API_VER']
pkg['platformVersion'] = os.environ['HOS_PLATFORM_VERSION']
with open(p, 'w') as f:
    json.dump(pkg, f)
"
done
# HMS toolchains: skip id_defined.json to avoid duplicate ID errors
mkdir -p "$SDK_HOME/toolchains/hms/toolchains"
for item in "$SDK_HOME/toolchains/"*; do
  bname=$(basename "$item")
  case "$bname" in openharmony|hms|id_defined.json) continue ;; esac
  ln -sf "$item" "$SDK_HOME/toolchains/hms/toolchains/$bname"
done
cat > "$SDK_HOME/toolchains/hms/toolchains/uni-package.json" << EOF
{"apiVersion":"$API_VER","fullApiVersion":"$API_VER","platformVersion":"$HOS_PLATFORM_VERSION","displayName":"Toolchains","meta":{"metaVersion":"3.0.0"},"path":"toolchains","releaseType":"Beta1","version":"$SDK_PKG_VERSION"}
EOF
echo "  Created toolchains/hms/"

# ─── Step 5: Schema stubs for HarmonyOS validation ───
for check_dir in modulecheck configcheck syscapcheck; do
  CHECK_PATH="$SDK_HOME/toolchains/$check_dir"
  [ ! -d "$CHECK_PATH" ] && continue
  for schema in app.json module.json; do
    [ ! -f "$CHECK_PATH/$schema" ] && echo '{}' > "$CHECK_PATH/$schema"
  done
done
# Remove stale per-component sdk-pkg.json files from older cached CI layouts.
for comp in ets native previewer toolchains; do
  HMS_DIR="$SDK_HOME/toolchains/hms/$comp"
  REAL_DIR=$(readlink -f "$HMS_DIR" 2>/dev/null || echo "$HMS_DIR")
  rm -f "$REAL_DIR/sdk-pkg.json" "$HMS_DIR/sdk-pkg.json"
done

echo "SDK_API_VERSION=$API_VER"
echo "SDK_SOURCE_API_VERSION=$SOURCE_API_VER"
echo "HOS_PLATFORM_VERSION=$HOS_PLATFORM_VERSION"
echo "HOS_TARGET_SDK_VERSION=$HOS_TARGET_SDK_VERSION"
echo "✅ SDK layout normalized"
