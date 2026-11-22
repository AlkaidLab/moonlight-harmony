#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/home"
unset CMDLINE_TOOLS_HOME COMMANDLINE_TOOLS_HOME
mkdir -p "$TEST_ROOT/entry/src/main/ets/config"
touch "$TEST_ROOT/entry/src/main/ets/config/DevKeySecret.ets" \
  "$TEST_ROOT/entry/src/main/ets/config/GitHubOAuthConfig.ets"

make_sdk() {
  local sdk="$1"
  mkdir -p "$sdk/openharmony/ets/api" "$sdk/openharmony/ets/kits" \
    "$sdk/openharmony/ets/build-tools/ets-loader/kit_configs" \
    "$sdk/hms/ets/api" "$sdk/hms/ets/kits" \
    "$sdk/hms/ets/build-tools/ets-loader/kit_configs"
  touch "$sdk/libimage_transcoder_shared.so"
}

make_flat_loader() {
  local sdk="$1"
  mkdir -p "$sdk/ets/api" "$sdk/ets/kits" "$sdk/ets/build-tools/ets-loader/kit_configs"
  printf '%s\n' '  sdkConfigs = [...defaultSdkConfigs, ...extendSdkConfigs];' > "$sdk/ets/build-tools/ets-loader/main.js"
  touch "$sdk/libimage_transcoder_shared.so"
}

sdk="$TEST_ROOT/stub-sdk"
make_sdk "$sdk"
config="$sdk/hms/ets/build-tools/ets-loader/kit_configs/@kit.RemoteCommunicationKit.json"
printf '%s\n' '{"symbols":{"rcp":{"source":"@ohos.net.rcp.d.ts","bindings":"default"}}}' > "$config"
(cd "$TEST_ROOT" && HOME="$TEST_ROOT/home" bash "$SCRIPT_DIR/patch-sdk.sh" "$sdk")
node -e 'const c = require(process.argv[1]); if (c.symbols.rcp.source !== "@hms.collaboration.rcp.d.ts") process.exit(1)' "$config"
test -f "$sdk/hms/ets/api/@hms.collaboration.rcp.d.ts"
test ! -e "$sdk/hms/ets/api/@ohos.net.rcp.d.ts"

sdk="$TEST_ROOT/official-sdk"
make_sdk "$sdk"
config="$sdk/hms/ets/build-tools/ets-loader/kit_configs/@kit.RemoteCommunicationKit.json"
printf '%s\n' '{"official":true}' > "$config"
printf '%s\n' 'official declaration' > "$sdk/hms/ets/kits/@kit.RemoteCommunicationKit.d.ts"
(cd "$TEST_ROOT" && HOME="$TEST_ROOT/home" bash "$SCRIPT_DIR/patch-sdk.sh" "$sdk")
node -e 'if (require(process.argv[1]).official !== true) process.exit(1)' "$config"
test ! -e "$sdk/hms/ets/api/@hms.collaboration.rcp.d.ts"

sdk="$TEST_ROOT/flat-sdk"
make_flat_loader "$sdk"
(cd "$TEST_ROOT" && HOME="$TEST_ROOT/home" bash "$SCRIPT_DIR/patch-sdk.sh" "$sdk")
grep -Fq "sdkConfigPrefix += '|hms'" "$sdk/ets/build-tools/ets-loader/main.js"
(cd "$TEST_ROOT" && HOME="$TEST_ROOT/home" bash "$SCRIPT_DIR/patch-sdk.sh" "$sdk")
test "$(grep -Fc '// CI HMS module prefix registration' "$sdk/ets/build-tools/ets-loader/main.js")" -eq 1
echo 'RemoteCommunicationKit SDK patch checks passed'
