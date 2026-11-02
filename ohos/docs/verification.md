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
| Official examples on emulator | All five pages under **Official examples** run to completion: Python, multiple runtimes, Edge.js HTTP server, shell tools, and the interactive terminal (verified 2026-11-02). |
| Pi coding agent on emulator | `wasmer/pi@0.87.1` boots through `wasmer/edgejs-quickjs@0.2.5`: `pi --version` prints `0.87.1` and `pi --help` exits 0 with the full tool list. The default `wasmer/edgejs@0.2.4` path and a complete model-backed agent turn are blocked by engine limitations (see below). |

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

### Official examples

The **Official examples** entry on the home page opens a list whose pages mirror
the upstream `js/examples` scripts and README snippets. Every page was driven
through the emulator UI with `uitest`, and the ArkTS source lives in
[`examples/arkts-pages`](../examples/arkts-pages) and
`harmony/entry/src/main/ets/pages`.

| Example | Upstream source | Captured result |
| --- | --- | --- |
| Python | `js/examples/python.mjs` | Status `Exited with status 0`, output `285` |
| Multiple runtimes | `js/examples/multiple_runtimes.mjs` | Status `All runtimes completed`, output `hello from shell tools`, `hello from Python`, `hello from Edge.js`, `hello from PHP` |
| Edge.js HTTP server | `js/examples/edgejs_http.mjs` | Status `Serving http://127.0.0.1:8080/`; the ArkUI `Web` component renders `hello from Edge.js on HarmonyOS` |
| Shell tools | README shell-tools example | Status `Exited with status 0`, output `hello from 'HarmonyOS'`, `/workspace`, `done` |
| Interactive terminal | README terminal example | `bash -i` starts as pid 1; `Send` echoes `hello from the terminal`; `Resize` reports `Resized to 120x40`; `Stop` reports `Stopped` |

Two adjustments were required relative to the upstream snippets, both captured
in the ArkTS pages:

- **Ambiguous `echo`.** Loading `python/python` and `wasmer/edgejs-quickjs`
  together makes a bare `command("echo")` fail with `COMMAND_AMBIGUOUS`,
  because both packages ship `echo`. The page keeps the upstream sequence but
  qualifies the shell call with `pythonPkg.command("echo")` (a `CommandRef`).
  The vendored Rust `vendor/wasmer-sdk-rust/examples/multiple_runtimes.rs` still
  uses the bare command and would need the same qualification with current
  registry contents.
- **Edge.js variant.** The pages use `wasmer/edgejs-quickjs@0.1.0` rather than
  `wasmer/edgejs@0.2.0`; see the platform finding about host N-API below.

### Pi coding agent

`wasmer/pi@0.87.1` is the official Pi coding agent package. Its `wasmer.toml`
pins `wasmer/edgejs@=0.2.4`, so the natural `pi` command takes the same failing
Edge.js path as the other examples. The **Pi coding agent** page therefore
offers three probes:

| Probe | Result |
| --- | --- |
| `pi` (Edge.js 0.2.4) | Fails before the CLI starts: `Failed to execute builtin 'internal/bootstrap/realm'` (`Node.js v24.13.2`) |
| `pi --version` via `wasmer/edgejs-quickjs@0.2.5` | Exit 0, output `0.87.1` |
| `pi --help` via `wasmer/edgejs-quickjs@0.2.5` | Exit 0; lists the read, bash, edit, write, grep, find, and ls tools plus all provider flags |

Running Pi against a local OpenAI-compatible streaming fixture gets further:
the request reaches `POST /v1/chat/completions` and the fixture streams chunks,
and a standalone `fetch` probe against the same guest server succeeds
(`GET /health` → 200, streamed `POST` returns a readable body). Pi's provider
client then fails with `cannot read property 'headers' of undefined`, so a
complete model-backed tool loop has not been observed on the QuickJS engine.

The Pi page writes `models.json`, `auth.json`, a local model server
(`model-server.mjs`), and test files into `/workspace`, starts the server with
`edge`, exposes port 8787, and runs the CLI with
`--offline --provider wasmer-test --model test --tools read,write,edit,bash,grep,find,ls -p`.
No provider credentials are used.

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
- **Host-NAPI Edge.js is not usable on this engine.** The registry variants
  `wasmer/edgejs@0.2.0` and `@0.2.4` expect a V8-compatible host N-API and fail
  while bootstrapping Node (`Failed to execute builtin
  'internal/bootstrap/realm'`) under the QuickJS host engine. This also blocks
  the default `wasmer/pi` command, which depends on Edge.js 0.2.4. The embedded
  variant `wasmer/edgejs-quickjs` works; examples use `@0.1.0` (resolved as
  0.1.4) and the Pi page uses `@0.2.5`, whose newer QuickJS engine can load the
  Pi bundle. Even there, Pi's provider client fails after the model response,
  so a full agent turn remains unverified.

## Not yet verified

- Outbound internet (DNS/TCP) from WASIX guests on device, including registry
  downloads with `network: { mode: "host" }` (guest-to-guest loopback through
  `ports.expose` is verified).
- A complete Pi agent turn with a model response and tool calls; the CLI boots
  but its provider client fails on the QuickJS runtime.
- Long-running process/terminal behavior under HarmonyOS scheduling beyond the
  first start/stop cycle, and repeated start/stop cycles for handle cleanup.
- Physical HarmonyOS hardware; all results above are from the emulator.
