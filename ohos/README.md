# Wasmer SDK for HarmonyOS

A 1:1 port of [`@wasmer/sdk`](https://github.com/wasmerio/wasmer-sdk) 0.19.1 to
HarmonyOS NEXT. The upstream Rust core (Wasmer 7.4 + WASIX) is compiled for
`aarch64-unknown-linux-ohos` and exposed to ArkTS through a Node-API bridge, so
WASI/WASIX packages run natively on device instead of inside a WebAssembly
runtime.

```text
ArkTS application
  └── @wasmer/harmony        harmony/wasmer  (HAR, ArkTS API)
        └── libwasmer_sdk_ohos.so           native/src  (napi-rs bridge)
              └── wasmer-sdk / wasmer-wasix  vendor/wasmer-sdk-rust  (Rust core)
                    └── WASI / WASIX guest
```

## Status

| Area | Result |
| --- | --- |
| Public ArkTS API surface | Complete: every upstream class, interface, and all 24 error codes |
| Native core cross-build | `aarch64-unknown-linux-ohos`, 43 MB shared library |
| HAP packaging | Builds unsigned; contains the native library, `libc++_shared.so`, and demo guest |
| Native functional tests | 16/16 passing on the host (macOS cdylib via Node-API) |
| ArkTS compilation | Clean under the HarmonyOS 6.0 (API 20) strict compiler |
| Emulator run | **Verified** on an API 23 arm64 emulator: WASI demo, Node.js (`wasmer/edgejs-quickjs@0.1.0`), all five upstream-style examples, and the official `wasmer/pi@0.87.1` CLI (boots through `edgejs-quickjs@0.2.5`); see [docs/verification.md](docs/verification.md) |

API parity details and intentional platform differences are documented in
[docs/parity.md](docs/parity.md). Build, signing, and run instructions are in
[docs/build.md](docs/build.md).

## Repository layout

| Path | Purpose |
| --- | --- |
| [`native/`](native) | Rust Node-API bridge (`wasmer_sdk_ohos`) |
| [`vendor/wasmer-sdk-rust/`](vendor/wasmer-sdk-rust) | Vendored upstream `wasmer-sdk` core crate |
| [`vendor/wasmer-napi/`](vendor/wasmer-napi) | Vendored N-API integration; builds its bundled QuickJS engine on OHOS instead of V8 |
| [`vendor/perf-event-open-sys/`](vendor/perf-event-open-sys) | OHOS ioctl patch needed by the core |
| [`harmony/wasmer/`](harmony/wasmer) | HarmonyOS HAR: ArkTS API, native `.so`, type declarations |
| [`harmony/entry/`](harmony/entry) | Demo HAP: runs `demo.wasm` and a Node.js script through Edge.js |
| [`examples/hello-wasi/`](examples/hello-wasi) | WASI demo guest written in Rust |
| [`examples/arkts-pages/`](examples/arkts-pages) | Upstream-style examples ported to ArkTS |
| [`tests/native-smoke.cjs`](tests/native-smoke.cjs) | Node-API functional test suite |
| [`scripts/`](scripts) | Native, HAP, and demo-guest build scripts |

## Using the SDK

Add the HAR as a local dependency in your HarmonyOS app:

```json5
// oh-package.json5
{
  "dependencies": {
    "@wasmer/harmony": "file:../wasmer-sdk-harmony/harmony/wasmer"
  }
}
```

Create a package from raw WASI bytes and run it:

```ts
import { Wasmer, PackageDefinition, PackageCommandDefinition, SandboxOptions } from "@wasmer/harmony";

const wasmer = await Wasmer.create();
const modules: Record<string, Uint8Array> = {};
modules["app.wasm"] = wasmBytes;
const commands: Record<string, PackageCommandDefinition> = {};
commands["main"] = { module: "app.wasm" };
const definition: PackageDefinition = {
  modules: modules,
  commands: commands,
  entrypoint: "main",
};
const pkg = await wasmer.packages.create(definition);
const options: SandboxOptions = { packages: [pkg], network: { mode: "disabled" } };
const sandbox = await wasmer.sandboxes.create(options);
const output = await sandbox.command(pkg, ["--help"]).run();
console.log(output.text());
await sandbox.close();
await wasmer.close();
```

Registry packages work the same way when the app has `ohos.permission.INTERNET`
(the demo module already declares it):

```ts
const sandbox = await wasmer.sandboxes.create({
  packages: ["python/python@=3.13.20"],
  files: { "main.py": "print(sum(n * n for n in range(10)))" },
});
const output = await sandbox.command("python", ["/workspace/main.py"]).run();
```

The package cache defaults to the application cache directory under
`wasmer/`; pass `cache: { directory }`, `cache: "memory"`, or `cache: false` to
override it.

Node.js works through Edge.js. Use `wasmer/edgejs-quickjs`, which embeds its own
QuickJS N-API engine and therefore runs on the OHOS host engine:

```ts
const edgejs = await wasmer.packages.load("wasmer/edgejs-quickjs@0.1.0");
const sandbox = await wasmer.sandboxes.create({
  packages: [edgejs],
  files: { "index.js": "console.log('hello from node', process.platform);" },
  network: { mode: "disabled" },
});
const output = await sandbox.command("edge", ["/workspace/index.js"]).run();
console.log(output.text());
```

## Build

Prerequisites:

- DevEco Studio with the HarmonyOS 6.0.0 (API 20) SDK
- Rust stable with the `aarch64-unknown-linux-ohos` and `wasm32-wasip1` targets
- macOS or Linux; the scripts default to the DevEco installation at
  `/Applications/DevEco-Studio.app`

```bash
rustup target add aarch64-unknown-linux-ohos wasm32-wasip1

scripts/build-native.sh     # cross-build the N-API library into harmony/wasmer/libs/arm64-v8a/
scripts/build-demo-wasm.sh  # rebuild the demo guest into entry rawfile
scripts/build-hap.sh        # compile ArkTS and assemble the debug HAP
```

Output: `harmony/entry/build/default/outputs/default/entry-default-unsigned.hap`.
An emulator accepts this unsigned HAP directly with `hdc install -r`. Physical
devices require a signing profile configured in DevEco Studio (or in
`harmony/build-profile.json5`).

## Tests

The Node-API bridge can be exercised on the host without a HarmonyOS device.
The test builds a macOS `.dylib`, renames it to `.node`, and drives the same
native surface the ArkTS layer uses:

```bash
cargo build -p wasmer_sdk_ohos
node tests/native-smoke.cjs

tests/api-surface.sh   # every upstream export and error code is present
```

Coverage: package creation/metadata, registry-ref installation, raw WASI byte
loading with progress events, cancellation tokens, run with args/env/stdin and
seeded files, non-zero exits, timeouts, output truncation, spawn pipes,
termination, sandbox filesystem operations, terminal spawn/resize, port
observation, invalid package rejection, and clean sandbox/client shutdown. The
API surface check compares the ArkTS exports and all 24 error codes against a
pinned upstream baseline.

## Platform differences

HarmonyOS is not a browser and does not ship a service-worker host. The API is
kept source-compatible, with a small number of capabilities mapped to their
native equivalents:

| Upstream capability | HarmonyOS behavior |
| --- | --- |
| `ReadableBytes` async iteration | ArkTS has no `Symbol.asyncIterator`; use `next()`, `readAll()`, `iterator()`, `lines().next()`, or WHATWG-style `toReadableStream()` |
| `WritableBytes` streams | `toWritableStream()` for API compatibility; `write()`/`close()` are the primary API |
| `ports.expose()` | Returns a `BrowserServer` pointing at `http://127.0.0.1:<port>/`; embed it with the ArkUI `Web` component instead of an iframe |
| `BrowserServer.createIframe()` | Throws `CAPABILITY_UNAVAILABLE`; use the `Web` component |
| `network.mode = "http"` / `"wisp"` | Both map to real host networking; `setWispUrl()` throws |
| `network.peers` | Rejected; host networking already shares localhost across sandboxes in the app |
| `Sandbox.network.setWispUrl()` | Throws `CAPABILITY_UNAVAILABLE` |
| `WasmerOptions.wasm` | Omitted; the runtime is a native shared library, not a loadable Wasm module |
| `WasmerOptions.parallelism` | Accepted and validated; the native runtime uses device CPU parallelism |
| `cache.readOnly` | Accepted for compatibility; the cache is writable |
| `Symbol.asyncDispose` | Not available in ArkTS; call `close()` explicitly |

Everything else preserves upstream semantics, including `run()` being checked
by default, `wait()` being unchecked, process-tree terminals, progress
snapshots, abort reasons, and the `ProcessExitError.code` mapping.

## Signing

No signing material is committed to this repository. Create a debug profile in
DevEco Studio:

1. Open `harmony/` in DevEco Studio.
2. **File → Project Structure → Project → Signing Configs**.
3. Enable **Automatically generate signature** (Huawei account required) and
   select the `default` product.
4. Rebuild; the signed HAP is written next to the unsigned one.

For manual signing, see [docs/build.md](docs/build.md#signing).

## License

MIT. The vendored Wasmer core and WASIX components retain their upstream
licenses; see [`LICENSE`](LICENSE).
