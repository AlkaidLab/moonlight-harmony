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
  API_VER=$(python3 -c "import json; print(json.load(open('$PKG_FILE'))['apiVersion'])")
else
  API_VER=$(find "$SDK_HOME/openharmony" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | head -1)
fi
echo "SDK API version: $API_VER"
[ -z "$API_VER" ] && { echo "ERROR: Could not determine API version"; exit 1; }

# ─── Step 1: Flatten nested openharmony/<ver> layout to root ───
for comp in ets js native toolchains previewer; do
  ROOT_DIR="$SDK_HOME/$comp"
  OH_NESTED_DIR="$SDK_HOME/openharmony/$API_VER/$comp"
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
{"apiVersion":"$API_VER","displayName":"${comp^}","meta":{"metaVersion":"3.0.0"},"path":"$comp","releaseType":"Beta1","version":"6.0.0.47"}
EOF
  fi

  if [ ! -f "$COMP_DIR/sdk-pkg.json" ]; then
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
{"apiVersion":"$API_VER","displayName":"${comp^}","meta":{"metaVersion":"3.0.0"},"path":"$comp","releaseType":"Beta1","version":"6.0.0.47"}
EOF
  fi
done
# HMS toolchains: skip id_defined.json to avoid duplicate ID errors
mkdir -p "$SDK_HOME/toolchains/hms/toolchains"
for item in "$SDK_HOME/toolchains/"*; do
  bname=$(basename "$item")
  case "$bname" in openharmony|hms|id_defined.json) continue ;; esac
  ln -sf "$item" "$SDK_HOME/toolchains/hms/toolchains/$bname"
done
cat > "$SDK_HOME/toolchains/hms/toolchains/uni-package.json" << EOF
{"apiVersion":"$API_VER","displayName":"Toolchains","meta":{"metaVersion":"3.0.0"},"path":"toolchains","releaseType":"Beta1","version":"6.0.0.47"}
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
# HMS sdk-pkg.json for parseSdks scanning
for comp in ets native previewer toolchains; do
  HMS_DIR="$SDK_HOME/toolchains/hms/$comp"
  REAL_DIR=$(readlink -f "$HMS_DIR" 2>/dev/null || echo "$HMS_DIR")
  [ ! -f "$REAL_DIR/sdk-pkg.json" ] && [ ! -f "$HMS_DIR/sdk-pkg.json" ] && \
    python3 -c "
import json
data = {'apiVersion': '$API_VER', 'displayName': '${comp^}', 'path': '$comp', 'releaseType': 'Beta1', 'version': '6.0.0.47'}
with open('$REAL_DIR/sdk-pkg.json', 'w') as f:
    json.dump({'data': data, 'meta': {'version': '3.0.0'}}, f)
"
done

echo "SDK_API_VERSION=$API_VER"
echo "✅ SDK layout normalized"
