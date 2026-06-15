#!/usr/bin/env bash
# Normalize the downloaded OpenHarmony SDK layout for hvigor.
#
# Different Hvigor/sdkmanager releases expect different local SDK layouts:
#   - older CI helpers scan flat $SDK_HOME/<component>
#   - OpenHarmony sdkmanager scans $SDK_HOME/<api>/<component>
#   - HarmonyOS sdkmanager scans platform containers such as
#     $SDK_HOME/toolchains and then expands them to toolchains/hms/<component>
# Keep the real component directories flat and create symlink views for the
# SDK managers instead of copying the SDK.
set -euo pipefail

SDK_HOME="${1:-$HOME/ohos-sdk}"

echo "=== Normalizing SDK layout ==="

display_name_for() {
  case "$1" in
    ets) echo "Ets" ;;
    js) echo "Js" ;;
    native) echo "Native" ;;
    toolchains) echo "Toolchains" ;;
    previewer) echo "Previewer" ;;
    *) echo "$1" ;;
  esac
}

component_json() {
  local comp="$1"
  local meta_key="$2"
  local include_stage="${3:-0}"
  local display_name
  display_name="$(display_name_for "$comp")"
  COMP="$comp" DISPLAY_NAME="$display_name" META_KEY="$meta_key" INCLUDE_STAGE="$include_stage" \
    API_VER="$API_VER" HOS_PLATFORM_VERSION="$HOS_PLATFORM_VERSION" SDK_PKG_VERSION="$SDK_PKG_VERSION" \
    python3 - <<'PY'
import json
import os

data = {
    "apiVersion": os.environ["API_VER"],
    "fullApiVersion": os.environ["API_VER"],
    "platformVersion": os.environ["HOS_PLATFORM_VERSION"],
    "displayName": os.environ["DISPLAY_NAME"],
    "path": os.environ["COMP"],
    "releaseType": "Release",
    "version": os.environ["SDK_PKG_VERSION"],
}
if os.environ.get("INCLUDE_STAGE") == "1":
    data["stage"] = "Release"
meta_key = os.environ["META_KEY"]
if meta_key == "metaVersion":
    data["meta"] = {"metaVersion": "3.0.0"}
elif meta_key == "version":
    data = {"data": data, "meta": {"version": "1.0.0"}}
print(json.dumps(data, separators=(",", ":")))
PY
}

write_oh_package() {
  local comp="$1"
  local dir="$2"
  mkdir -p "$dir"
  component_json "$comp" metaVersion > "$dir/oh-uni-package.json"
}

write_hos_package() {
  local comp="$1"
  local dir="$2"
  mkdir -p "$dir"
  component_json "$comp" version 1 > "$dir/sdk-pkg.json"
}

write_hms_check_package() {
  local comp="$1"
  local dir="$2"
  mkdir -p "$dir"
  component_json "$comp" metaVersion > "$dir/uni-package.json"
}

link_component_contents() {
  local src="$1"
  local dst="$2"
  shift 2
  mkdir -p "$dst"
  for item in "$src"/*; do
    [ -e "$item" ] || continue
    local bname
    bname="$(basename "$item")"
    case "$bname" in
      openharmony|hms) continue ;;
    esac
    local skip=0
    for excluded in "$@"; do
      [ "$bname" = "$excluded" ] && skip=1 && break
    done
    [ "$skip" -eq 1 ] && continue
    ln -sfn "$item" "$dst/$bname"
  done
}

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
  26) HOS_PLATFORM_VERSION="26.0.0"; HOS_COMPILE_SDK_VERSION="26.0.0"; HOS_TARGET_SDK_VERSION="26.0.0" ;;
  24) HOS_PLATFORM_VERSION="6.1.1"; HOS_COMPILE_SDK_VERSION="6.1.1"; HOS_TARGET_SDK_VERSION="6.1.1(24)" ;;
  23) HOS_PLATFORM_VERSION="6.1.0"; HOS_COMPILE_SDK_VERSION="6.1.0"; HOS_TARGET_SDK_VERSION="6.1.0(23)" ;;
  22) HOS_PLATFORM_VERSION="6.0.2"; HOS_COMPILE_SDK_VERSION="6.0.2"; HOS_TARGET_SDK_VERSION="6.0.2(22)" ;;
  20) HOS_PLATFORM_VERSION="6.0.0"; HOS_COMPILE_SDK_VERSION="6.0.0"; HOS_TARGET_SDK_VERSION="6.0.0(20)" ;;
  *) echo "ERROR: Unsupported SDK API version: $API_VER"; exit 1 ;;
esac

# GitHub Actions writes this value into both compileSdkVersion and targetSdkVersion.
# Older command-line tools reject decorated values such as 6.1.1(24) for compileSdkVersion.
[ "${GITHUB_ACTIONS:-}" = "true" ] && HOS_TARGET_SDK_VERSION="$HOS_COMPILE_SDK_VERSION"

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

# ─── Step 2: Ensure component metadata in each flat component ───
for comp in ets js native toolchains previewer; do
  COMP_DIR="$SDK_HOME/$comp"
  [ ! -d "$COMP_DIR" ] && mkdir -p "$COMP_DIR"
  write_oh_package "$comp" "$COMP_DIR"
  rm -f "$COMP_DIR/sdk-pkg.json"
done

# ─── Step 3: Create OpenHarmony sdkmanager view ($SDK_HOME/<api>/<component>) ───
rm -rf "$SDK_HOME/$API_VER"
mkdir -p "$SDK_HOME/$API_VER"
for comp in ets js native toolchains previewer; do
  [ -d "$SDK_HOME/$comp" ] && ln -sfn "$SDK_HOME/$comp" "$SDK_HOME/$API_VER/$comp"
done
echo "  Created $API_VER/ component view"

# ─── Step 4: Create legacy OPENHARMONY remapped locations ───
rm -rf "$SDK_HOME/toolchains/openharmony"
mkdir -p "$SDK_HOME/toolchains/openharmony"
for comp in ets js native previewer; do
  [ -d "$SDK_HOME/$comp" ] && ln -sf "$SDK_HOME/$comp" "$SDK_HOME/toolchains/openharmony/$comp"
done
mkdir -p "$SDK_HOME/toolchains/openharmony/toolchains"
link_component_contents "$SDK_HOME/toolchains" "$SDK_HOME/toolchains/openharmony/toolchains" id_defined.json
echo "  Created toolchains/openharmony/"

# ─── Step 5: Create HarmonyOS sdkmanager platform views ───
rm -rf "$SDK_HOME/toolchains/hms"
mkdir -p "$SDK_HOME/toolchains/hms"
write_hos_package "toolchains" "$SDK_HOME/toolchains"
for comp in ets native previewer; do
  [ -d "$SDK_HOME/$comp" ] && ln -sf "$SDK_HOME/$comp" "$SDK_HOME/toolchains/hms/$comp"
  write_hms_check_package "$comp" "$SDK_HOME/$comp"
done
# HMS toolchains: skip id_defined.json to avoid duplicate ID errors
mkdir -p "$SDK_HOME/toolchains/hms/toolchains"
link_component_contents "$SDK_HOME/toolchains" "$SDK_HOME/toolchains/hms/toolchains"
write_hms_check_package "toolchains" "$SDK_HOME/toolchains/hms/toolchains"

# Some command-line-tools only know HarmonyOS <= 5.1.0 until patched. The real
# platform version stays 6.1.1 in sdk-pkg.json, while this alias lets those
# tools discover the same local platform container before ci/patch-sdk.sh runs.
for platform_alias in "hmscore/$API_VER" "hmscore/$HOS_PLATFORM_VERSION" "HarmonyOS-$HOS_PLATFORM_VERSION" "HarmonyOS $HOS_PLATFORM_VERSION" "HarmonyOS-NEXT2" "HarmonyOS NEXT2"; do
  rm -rf "$SDK_HOME/$platform_alias"
  mkdir -p "$(dirname "$SDK_HOME/$platform_alias")"
  ln -sfn "$SDK_HOME/toolchains" "$SDK_HOME/$platform_alias"
done
echo "  Created toolchains/hms/"

# ─── Step 6: Schema stubs for HarmonyOS validation ───
for check_dir in modulecheck configcheck syscapcheck; do
  CHECK_PATH="$SDK_HOME/toolchains/$check_dir"
  [ ! -d "$CHECK_PATH" ] && continue
  for schema in app.json module.json; do
    [ ! -f "$CHECK_PATH/$schema" ] && echo '{}' > "$CHECK_PATH/$schema"
  done
done

echo "SDK_API_VERSION=$API_VER"
echo "SDK_SOURCE_API_VERSION=$SOURCE_API_VER"
echo "HOS_PLATFORM_VERSION=$HOS_PLATFORM_VERSION"
echo "HOS_COMPILE_SDK_VERSION=$HOS_COMPILE_SDK_VERSION"
echo "HOS_TARGET_SDK_VERSION=$HOS_TARGET_SDK_VERSION"
echo "✅ SDK layout normalized"
