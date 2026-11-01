#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/examples/hello-wasi"
cargo build --target wasm32-wasip1 --release
cp target/wasm32-wasip1/release/hello-wasi.wasm \
  "$ROOT/harmony/entry/src/main/resources/rawfile/demo.wasm"
echo "Installed demo.wasm"
