# Verification status

This page records what has been verified for the HarmonyOS port, with the exact
commands and captured output: host builds and tests, plus install, launch, and
guest execution on the HarmonyOS emulator. No signing material is stored in the
repository.

## Verified

| Check | Evidence |
| --- | --- |
| Upstream API surface | `tests/api-surface.sh` reports **49/49 upstream exports and 24/24 error codes present**, with no missing names. Compared against `js/src/index.ts` of `@wasmer/sdk` 0.19.1. Deviations are documented in [parity.md](parity.md). |
| OHOS core cross-build | `file harmony/wasmer/libs/arm64-v8a/libwasmer_sdk_ohos.so` reports `ELF 64-bit LSB shared object, ARM aarch64`. The library is 43 MB (45,121,784 bytes) and exports `napi_register_module_v1`. |
| ArkTS compilation | `scripts/build-hap.sh` runs `CompileArkTS` for both the `wasmer` HAR and `entry` HAP with no errors under the HarmonyOS 6.0 (API 20) strict compiler. |
| HAP packaging | The 33 MB HAP contains `libs/arm64-v8a/libwasmer_sdk_ohos.so`, `libs/arm64-v8a/libc++_shared.so`, and `resources/rawfile/demo.wasm` (67,610 bytes). |
| Native functional tests | `tests/native-smoke.cjs` passes **16/16** against a release build of the current bridge (re-run 2026-11-02). |
| Emulator install and launch | The unsigned HAP installs with `hdc install -r` and `EntryAbility` starts on the API 23 arm64 emulator. |
| WASI guest on emulator | **Run hello.wasm** prints the greeting, arguments, environment, stdin echo, and the `/tmp` file round-trip, then reports exit status 0. |
| Node.js guest on emulator | **Run Node.js example** loads `wasmer/edgejs-quickjs@0.1.0`, executes `/workspace/index.js`, and reports `Node exited with status 0`. |

Commands:

```bash
# Native cross-build (also copies libc++_shared.so into the HAP library dir)
scripts/build-native.sh

# Host build of the same bridge, then the functional suite
cargo build -p wasmer_sdk_ohos --release
WASMER_NATIVE_LIB=target/release/libwasmer_sdk_ohos.dylib \
  node tests/native-smoke.cjs

# Static API parity audit
tests/api-surface.sh

# ArkTS + HAP
scripts/build-hap.sh

# Emulator install and launch
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
"$HDC" -t 127.0.0.1:5555 install -r \
  harmony/entry/build/default/outputs/default/entry-default-unsigned.hap
"$HDC" -t 127.0.0.1:5555 shell aa start -a EntryAbility -b com.wasmer.sdk.harmony

# Artifact inspection
file harmony/wasmer/libs/arm64-v8a/libwasmer_sdk_ohos.so
unzip -l harmony/entry/build/default/outputs/default/entry-default-unsigned.hap \
  | grep -E 'libwasmer|libc\+\+|demo.wasm'
```

### Covered by the native suite

1. Package metadata (`id`, commands, entrypoint, `hasCommand`)
2. `run()` with arguments, environment, stdin, and seeded files
3. Non-zero exit status and stderr capture
4. Timeout handling (exit code 137, reason `timeout`)
5. Output truncation with `outputBytes`
6. `spawn()` pipes with stdin/stdout
7. Process termination
8. Sandbox filesystem operations under `/workspace`
9. `installPackageRef` on an already-loaded package
10. Raw WASI bytes loading with `ProgressSink` snapshots
11. Invalid progress and cancellation tokens
12. `installPackageBytes`
13. Terminal spawn and resize
14. Port observation surface (`listeningPorts` / `isPortListening`)
15. Invalid package definition rejection
16. Clean `SandboxCore.close()` and `WasmerCore.shutdown()`

These exercise the same `WasmerCore`/`SandboxCore`/`CommandCore` methods that
`harmony/wasmer/src/main/ets/index.ets` calls, so they validate the bridge and
the Wasmer/WASIX core, not only the Rust wrappers.

## Emulator results

Environment: HarmonyOS emulator, API 23, `arm64-v8a`, reached through
`hdc -t 127.0.0.1:5555`. The HAP installs unsigned; the emulator accepts it
without a developer certificate, so no signing profile or private key is needed
or committed.

### Node.js example

The demo page's `runNode()` loads `wasmer/edgejs-quickjs@0.1.0` from the Wasmer
registry into the app cache, creates a sandbox with `/workspace/index.js`, and
runs `edge /workspace/index.js`. Captured UI output:

```text
Node exited with status 0

Hello from Node.js on HarmonyOS!
argv: ["/workspace/index.js"]
platform: wasi arch: unknown
squares: 1, 4, 9, 16, 25
sum: 55
```

`edgejs-quickjs` embeds its own QuickJS N-API engine, so the guest Node runtime
and the host ArkTS bridge do not share an engine. This is the same package used
by the upstream SDK's `examples/edgejs_http.rs`.

### WASI example

**Run hello.wasm** executes the bundled `demo.wasm` guest with seeded files,
arguments, environment, and stdin, and reports exit status 0 after the `/tmp`
file round-trip.

## Platform findings

These were discovered while bringing the port up on the emulator and shape the
build:

- **Module registration.** The HarmonyOS Node-API loader does not call the
  napi-rs entry point unless the shared object registers itself from an ELF
  constructor by calling `napi_module_register`, and the library must list
  `libace_napi.z.so` in `DT_NEEDED`. Both are handled in the native crate.
- **External ArrayBuffers.** ArkVM rejects
  `napi_create_external_arraybuffer`; the bridge copies bytes into an
  engine-owned buffer (`napi_create_arraybuffer` plus
  `napi_create_typedarray`) instead.
- **C++ runtime.** `libwasmer_sdk_ohos.so` links `libc++_shared.so` by soname.
  The HAP must ship that file under `libs/arm64-v8a/`, otherwise the module
  loader fails with `Error loading shared library libc++_shared.so`.
  `scripts/build-native.sh` copies it from
  `$NATIVE_SDK/llvm/lib/aarch64-linux-ohos/` on every build.
- **JavaScript engine.** V8 publishes no HarmonyOS prebuilt and cannot be
  relocated from a glibc build (`failed to resolve V8 ... env=ohos`). The
  vendored `vendor/wasmer-napi` therefore compiles its bundled QuickJS N-API
  engine when `target_env = "ohos"`.
- **Two N-API worlds in one `.so`.** The host module's `napi_*` imports must
  bind to ArkVM's `libace_napi.z.so` (or Node's `libnode` in a host build),
  while the guest engine's `napi_*` implementations must stay private. The
  build generates a prefix header that renames every engine-side `napi_*`
  symbol with a `snapi_qjs_` (QuickJS) or `snapi_engine_` (V8) prefix and
  compiles both the engine and the bridge with hidden visibility. Without this,
  the module's own `napi_register_module_v1` calls bind to the embedded engine
  and the loader crashes while registering the module.
- **Host-NAPI Edge.js is not usable on this engine.** The registry variant
  `wasmer/edgejs@0.2.0` expects a V8-compatible host N-API and fails while
  bootstrapping Node (`Failed to execute builtin 'internal/bootstrap/realm'`)
  under the QuickJS host engine. The embedded variant
  `wasmer/edgejs-quickjs@0.1.0` works and is what the demo and upstream
  `examples/edgejs_http.rs` use.

## Not yet verified

- Host networking (DNS/TCP) from WASIX guests on device, including registry
  downloads with `network: { mode: "host" }`.
- `ports.onListen` / `ports.expose` with a guest HTTP server rendered in the
  ArkUI `Web` component.
- Long-running process/terminal behavior under HarmonyOS scheduling, and
  repeated start/stop cycles for handle cleanup.
- Physical HarmonyOS hardware; all results above are from the emulator.
