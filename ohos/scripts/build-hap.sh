#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
HVIGOR="$DEVECO_HOME/tools/hvigor/bin/hvigorw"
NODE_HOME="${NODE_HOME:-$DEVECO_HOME/tools/node}"

if [[ ! -x "$HVIGOR" ]]; then
  echo "hvigorw not found at $HVIGOR" >&2
  exit 1
fi

if [[ ! -f "$ROOT/harmony/wasmer/libs/arm64-v8a/libwasmer_sdk_ohos.so" ]]; then
  echo "Missing libwasmer_sdk_ohos.so; run scripts/build-native.sh first." >&2
  exit 1
fi

export DEVECO_SDK_HOME
export NODE_HOME
cd "$ROOT/harmony"
"$HVIGOR" --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
