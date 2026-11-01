# API parity with `@wasmer/sdk` 0.19.1

This document tracks the HarmonyOS port against the upstream TypeScript surface
in `wasmerio/wasmer-sdk` (`js/src/index.ts`, version 0.19.1). The goal is
source-level parity: the same classes, methods, option shapes, error codes, and
runtime semantics, except where HarmonyOS has no equivalent capability.

Legend: **Yes** = present with upstream semantics; **Adapted** = present, with a
platform-specific mechanism documented below; **N/A** = capability does not
exist on HarmonyOS and fails explicitly.

## Errors and primitives

| Upstream export | HarmonyOS | Notes |
| --- | --- | --- |
| `WasmerError` | Yes | `message`, `code`, `cause`; `WasmerError.is(error, code?)` |
| `ProcessExitError` | Yes | `output` and derived `code` (`PROCESS_EXITED` / `PROCESS_TERMINATED` / `TIMEOUT`) |
| `WasmerErrorCode` | Yes | All 24 codes, identical strings |
| `AbortController` / `AbortSignal` | Adapted | ArkTS has no DOM abort primitives; provided by `errors.ets` with `aborted`, `reason`, `throwIfAborted()`, listeners, `onabort` |

## Package loading

| Upstream API | HarmonyOS | Notes |
| --- | --- | --- |
| `new Wasmer(options)` | Yes | Synchronous; native runtime starts lazily |
| `Wasmer.create(options)` | Yes | Awaits initialization |
| `wasmer.ready()` | Yes | |
| `Wasmer.packages.create(definition)` | Yes | Copies module and file bytes |
| `Wasmer.packages.load(source)` | Yes | Registry specifier, WEBC bytes, raw WASI/WASIX bytes, or `Package` |
| `Wasmer.packages.loadMany(sources)` | Yes | Order preserved; shared downloads |
| `loadPackage(source)` | Yes | Deprecated alias, same as upstream |
| `wasmer.sandboxes.create(options)` | Yes | Package loading, files, env, network, shell |
| `createSandbox(options)` | Yes | Deprecated alias, same as upstream |
| `wasmer.close()` / `wasmer.shutdown()` | Yes | |
| `WasmerOptions.outputBytes` | Yes | |
| `WasmerOptions.parallelism` | Adapted | Accepted and validated; the native Tokio runtime schedules on the device's CPU parallelism, so this value does not resize the pool |
| `WasmerOptions.cache` | Adapted | Defaults to app cache `wasmer/`; `false` and `"memory"` are ephemeral; `namespace` is a subdirectory; `readOnly` is accepted but the cache remains writable |
| `WasmerOptions.wasm` | N/A | Runtime is a native `.so`, not a loadable Wasm module |
| `PackageLoadOptions.onProgress` | Yes | Polled native snapshots delivered through a 50 ms bounded observer; observer errors detach only that observer |
| `PackageLoadOptions.signal` | Yes | Cancellation token cancels the pending native load |
| `Package.id` / `.commands` / `.entrypoint` / `.command(name)` | Yes | `command()` throws `COMMAND_NOT_FOUND` for unknown names |
| `CommandRef` | Yes | `pkg`, `name` |
| Progress phases and snapshot semantics | Yes | `resolving`, `downloading`, `loading`, `ready`; reused packages reported as cached/ready with 0 bytes |

## Sandbox and commands

| Upstream API | HarmonyOS | Notes |
| --- | --- | --- |
| `Sandbox.command(selector, args?, options?)` | Yes | Selector may be a string, `Package`, or `CommandRef`; `cwd` and `env` supported |
| `Sandbox.shell(script)` | Yes | Requires a configured shell (`options.shell` or `installPackage(..., { asShell })`) |
| `Sandbox.sh` tagged template | Adapted | ArkTS supports tagged templates; `ShellValue` is `string \| number \| object \| array` (covers `URL`) |
| `Sandbox.installPackage(source, options)` | Yes | Returns the installed `Package`; `asShell` selects the shell command |
| `Sandbox.fs` | Adapted | Full read/write/mkdir/readDir/stat/remove/rename API; see the filesystem note below |
| `Sandbox.ports` | Adapted | `wait`, `expose`, `onListen`, `close`; see ports below |
| `Sandbox.network.setWispUrl` | N/A | Throws `CAPABILITY_UNAVAILABLE` (no browser WISP transport) |
| `Sandbox.close()` | Yes | Closes ports and the native sandbox |
| `Symbol.asyncDispose` | N/A | ArkTS has no `using`/async-dispose protocol; call `close()` |
| `Command.run(options)` | Yes | Checked by default; `stdin`, `timeoutMs`, `outputBytes`, `check` |
| `Command.spawn(options)` | Yes | Pipes/capture/discard, `stdin: "pipe" \| "closed"`, timeout, output cap, process-tree terminal |
| `Output` | Yes | `exitCode`, `reason`, `stdout`, `stderr`, `ok`, `text()`, `check()` |
| `CapturedOutput` | Yes | `bytes`, `truncated`, `text()` |
| `Process` | Yes | `id`, `stdin`/`stdout`/`stderr`, `wait({ check })`, `terminate({ gracePeriodMs })`, `kill()`, `resizeTerminal(cols, rows)` |
| `WritableBytes` | Adapted | `write()`, `close()`, plus a WHATWG-shaped `toWritableStream()` (no `Symbol.asyncIterator` needed) |
| `ReadableBytes` | Adapted | ArkTS cannot implement `AsyncIterable`; `next()`, `iterator()`, `readAll()`, `lines()`, and `toReadableStream()` are provided |
| `ReadableBytes.lines()` | Adapted | Returns a pull-based `Lines` object with `next()` and `readAll()`; same incremental/delimiter semantics as upstream's async generator |
| `SandboxFileSystem` | Yes | `writeFile`, `writeText`, `readFile`, `readText`, `mkdir`, `readDir`, `stat`, `remove`, `rename` |

## Ports and browser host

| Upstream API | HarmonyOS | Notes |
| --- | --- | --- |
| `Ports.wait(port, { timeoutMs })` | Adapted | Opens and closes one real TCP connection against the guest listener; guest networking must be enabled |
| `Ports.expose(port, options)` | Adapted | Returns a `BrowserServer` for `http://127.0.0.1:<port>/`; `serviceWorker` is ignored; display it with the ArkUI `Web` component |
| `Ports.onListen(listener, { intervalMs, onClose })` | Adapted | Polls `/proc/net/tcp{,6}` for LISTEN sockets; emits existing and rebound ports, calls `onClose` when a listener disappears |
| `Ports.close()` | Yes | Stops watchers and closes exposed servers |
| `BrowserServer.url` | Adapted | ArkTS `url.URL` instead of the WHATWG `URL`; same `href`/`origin` shape |
| `BrowserServer.createIframe(options)` | N/A | Throws `CAPABILITY_UNAVAILABLE`; use an ArkUI `Web` component |
| `BrowserServer.close()` | Yes | |
| `DEFAULT_SERVICE_WORKER_ORIGIN` | Yes | Present for source compatibility; not used |

## Network policy

| Upstream mode | HarmonyOS |
| --- | --- |
| `{ mode: "disabled" }` | `NetworkPolicy::Disabled` |
| `{ mode: "host" }` | Real host networking (TCP/UDP/DNS) |
| `{ mode: "http" }` | Maps to host networking (no browser HTTP ingress) |
| `{ mode: "wisp" }` | Maps to host networking (no WISP transport) |
| `peers` | Rejected with `CAPABILITY_UNAVAILABLE`; host networking already shares localhost within the app |

The `url`, `dnsUrl`, and `requestUrl` WISP options are accepted but unused.

## Deliberate semantic notes

- **Checked vs unchecked execution.** `Command.run()` throws `ProcessExitError`
  unless `{ check: false }`; `Process.wait()` never throws unless
  `{ check: true }`, matching upstream.
- **Timeout status.** A timed-out guest reports exit code 137 on HarmonyOS.
  `Output.reason` is `"timeout"` and `ProcessExitError.code` is `"TIMEOUT"`.
- **Shell escaping.** Tagged-template interpolations are single-quoted with
  embedded quotes escaped (`'\''`), and arrays expand to separate words,
  matching upstream `escapeShellWord`.
- **Progress.** Native events are snapshots, not deltas. Cached/local packages
  contribute zero download bytes. Callbacks are not invoked after settlement.
- **Abort reasons.** `AbortSignal.throwIfAborted()` rethrows the supplied
  `Error` reason, or `AbortError` when none was supplied.
- **Package definition paths.** `PackageDefinition.files` uses canonical guest
  paths (for example `/data/config.json`), same as upstream.
- **Sandbox filesystem paths.** The native sandbox mounts persistent data under
  `/workspace`; use relative paths or `/workspace/...` with `sandbox.fs` and
  `SandboxOptions.files`. Guest images may keep their own additional mounts.
- **Error transport.** Native failures cross the Node-API boundary as
  `WASMER_ERROR::<CODE>::<message>` and are rehydrated into `WasmerError`
  instances with the original code.
- **Type guards.** ArkTS does not support user-defined type predicates in the
  same way as TypeScript, so `WasmerError.is(error, code?)` returns a `boolean`
  instead of narrowing the type.
- **Abort primitives.** `AbortController`/`AbortSignal` are implementations
  from this package, not DOM classes. Code that constructs its own signal must
  import them from `@wasmer/harmony`.
- **WHATWG stream adapters.** `ReadableStream` and `WritableStream` are minimal
  compatibility wrappers with `getReader()`/`getWriter()`, `read()`, `write()`,
  and `close()`. They do not implement `pipeTo`, `tee`, or `TransformStream`.
- **Async disposal.** `Symbol.asyncDispose` is absent from ArkTS; close clients,
  sandboxes, servers, and processes explicitly.

## Native bridge surface

The ArkTS API is a thin layer over `libwasmer_sdk_ohos.so`. The bridge exposes
`WasmerCore`, `PackageCore`, `SandboxBuilderCore`, `SandboxCore`, `CommandCore`,
`OutputCore`, `ProcessCore`, `ProgressSink`, and
`PackageLoadCancellationCore`. Every public bridge method used by ArkTS is
annotated with `#[napi]` and covered by `tests/native-smoke.cjs` where it can run
without a device.

## Out of scope for this target

- Browser service-worker HTTP hosting and iframes
- WISP tunneling, WISP endpoint switching, browser peer isolation
- WebAssembly component execution (not part of upstream `@wasmer/sdk` either)
- Browser storage and `WasmerOptions.wasm` initialization override
