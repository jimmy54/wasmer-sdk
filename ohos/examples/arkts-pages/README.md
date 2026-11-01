# ArkTS examples

Upstream `@wasmer/sdk` examples ported to HarmonyOS. Each file is a complete
ArkUI page that can be copied into `harmony/entry/src/main/ets/pages/` and
registered in `main_pages.json`.

| Page | Upstream equivalent | Demonstrates |
| --- | --- | --- |
| [`PythonPage.ets`](PythonPage.ets) | `js/examples/python.mjs` | Registry package, bundled files, checked `run()` |
| [`BashPage.ets`](BashPage.ets) | shell-tools examples | `installPackage({ asShell })`, tagged-template `sh`, stdin |
| [`MultipleRuntimesPage.ets`](MultipleRuntimesPage.ets) | `js/examples/multiple_runtimes.mjs` | Several packages in one sandbox |
| [`EdgeHttpPage.ets`](EdgeHttpPage.ets) | `js/examples/edgejs_http.mjs` | Long-running HTTP server, `ports.expose`, ArkUI `Web` |
| [`TerminalPage.ets`](TerminalPage.ets) | README terminal example | Process-tree terminal, stdin, resize, pull-based stdout |

All pages that download registry packages need `ohos.permission.INTERNET` (the
demo entry module already declares it). Registry packages are fetched on first
use and cached in the application cache directory.

These pages are examples, not part of the demo build. They compile against the
same public API documented in [docs/parity.md](../../docs/parity.md).
