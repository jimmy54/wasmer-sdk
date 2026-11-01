#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
NATIVE_SDK="${NATIVE_SDK:-$DEVECO_SDK_HOME/default/openharmony/native}"
TOOLCHAIN="$NATIVE_SDK/llvm/bin"
TARGET="aarch64-unknown-linux-ohos"
PROFILE="${PROFILE:-release}"

if [[ ! -x "$TOOLCHAIN/aarch64-unknown-linux-ohos-clang" ]]; then
  echo "OHOS clang not found under $TOOLCHAIN" >&2
  echo "Set DEVECO_SDK_HOME to the HarmonyOS SDK root." >&2
  exit 1
fi

export CC_aarch64_unknown_linux_ohos="$TOOLCHAIN/aarch64-unknown-linux-ohos-clang"
export CXX_aarch64_unknown_linux_ohos="$TOOLCHAIN/aarch64-unknown-linux-ohos-clang++"
export AR_aarch64_unknown_linux_ohos="$TOOLCHAIN/llvm-ar"
export RANLIB_aarch64_unknown_linux_ohos="$TOOLCHAIN/llvm-ranlib"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$TOOLCHAIN/aarch64-unknown-linux-ohos-clang"
export OHOS_NDK_HOME="$DEVECO_SDK_HOME/default/openharmony"
export OHOS_SDK_NATIVE="$NATIVE_SDK"

cd "$ROOT"
PROFILE_FLAG=""
if [[ "$PROFILE" == "release" ]]; then
  PROFILE_FLAG="--release"
fi

cargo build -p wasmer_sdk_ohos --target "$TARGET" $PROFILE_FLAG

OUT="$ROOT/target/$TARGET/$PROFILE/libwasmer_sdk_ohos.so"
LIBS="$ROOT/harmony/wasmer/libs/arm64-v8a"
mkdir -p "$LIBS"
cp "$OUT" "$LIBS/libwasmer_sdk_ohos.so"

# The library links against the OHOS C++ runtime by soname; without a copy in
# the HAP the module loader fails to resolve libc++_shared.so at startup.
LIBCXX="$NATIVE_SDK/llvm/lib/aarch64-linux-ohos/libc++_shared.so"
if [[ -f "$LIBCXX" ]]; then
  cp "$LIBCXX" "$LIBS/libc++_shared.so"
else
  echo "warning: libc++_shared.so not found under $LIBCXX" >&2
fi

echo "Installed $OUT"
echo "Size: $(du -h "$OUT" | cut -f1)"
