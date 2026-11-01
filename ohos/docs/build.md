# Building and running

## Tested toolchain

| Component | Version |
| --- | --- |
| DevEco Studio SDK | HarmonyOS 6.0.0 (API 20), SDK under `/Applications/DevEco-Studio.app/Contents/sdk` |
| hvigor | 6.23.6 (bundled with DevEco Studio) |
| OHOS NDK clang | `sdk/default/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang` |
| Rust | stable 1.99.1 |
| Rust targets | `aarch64-unknown-linux-ohos`, `wasm32-wasip1` |
| Node (for native tests) | 24.x (host), bundled 18.20.1 for hvigor |

The build scripts read `DEVECO_SDK_HOME`, `DEVECO_HOME`, and `NODE_HOME` with
defaults for a standard macOS DevEco Studio installation. Override them for a
different installation:

```bash
export DEVECO_SDK_HOME=/path/to/DevEco-Studio/Contents/sdk
export NODE_HOME=/path/to/DevEco-Studio/Contents/tools/node
```

## 1. Native library

```bash
rustup target add aarch64-unknown-linux-ohos
scripts/build-native.sh
```

The script exports the OHOS clang toolchain and cross-builds the
`wasmer_sdk_ohos` cdylib:

- `CC_aarch64_unknown_linux_ohos`, `CXX_...`, `AR_...`, `RANLIB_...`
- `CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER`

The resulting `target/aarch64-unknown-linux-ohos/release/libwasmer_sdk_ohos.so`
is copied to `harmony/wasmer/libs/arm64-v8a/libwasmer_sdk_ohos.so` (~43 MB),
together with the OHOS `libc++_shared.so` runtime it links by soname.

Build a debug library with `PROFILE=debug scripts/build-native.sh`.

### OHOS-specific patch

`vendor/perf-event-open-sys` fixes an ioctl request-width mismatch: HarmonyOS
reports `target_os = "linux"` with `target_env = "ohos"`, and the upstream crate
selects a 64-bit ioctl type that does not match the OHOS ABI. The workspace
`[patch.crates-io]` entry applies the fix to the entire Wasmer dependency graph.

## 2. Demo guest (optional)

```bash
rustup target add wasm32-wasip1
scripts/build-demo-wasm.sh
```

This builds `examples/hello-wasi` and copies the module to
`harmony/entry/src/main/resources/rawfile/demo.wasm`. The guest prints args,
the `GREETING` environment variable, stdin, performs a file round-trip in
`/tmp`, and supports `--exit <code>` and `--sleep <milliseconds>` for manual
error/timeout testing.

## 3. HAP

```bash
scripts/build-hap.sh
```

This runs hvigor's `assembleHap` for the `default` product in debug mode and
produces:

```text
harmony/entry/build/default/outputs/default/entry-default-unsigned.hap
```

The warning `No signingConfig found for product default` means the HAP is
unsigned; see [Signing](#signing).

To compile only the HAR:

```bash
cd harmony
"$DEVECO_HOME/tools/hvigor/bin/hvigorw" \
  --mode module -p module=wasmer@default -p product=default assembleHar --no-daemon
```

## Signing

No keys, certificates, or profiles are stored in this repository.

### DevEco Studio automatic signing

1. Open `harmony/` in DevEco Studio.
2. Sign in with a Huawei developer account.
3. **File → Project Structure → Project → Signing Configs**.
4. Enable **Automatically generate signature**, choose the `default` product,
   and let DevEco create the debug certificate and profile.
5. Build again; the signed HAP is emitted beside the unsigned one.

DevEco writes the generated `signingConfigs` block into
`harmony/build-profile.json5` and material into `~/.ohos/config/`. Do not commit
either the generated profile or the `.p12`/`.cer` files.

### Manual signing

Use the `hap-sign-tool.jar` bundled with the SDK and an AppGallery Connect
release/debug profile. The general shape of the command is:

```bash
java -jar hap-sign-tool.jar sign-app \
  -keyAlias "<alias>" \
  -signAlg SHA256withECDSA \
  -mode localSign \
  -appCertFile "<certificate>.cer" \
  -profileFile "<profile>.p7b" \
  -inFile entry-default-unsigned.hap \
  -outFile entry-default-signed.hap \
  -keystoreFile "<keystore>.p12" \
  -keystorePwd "<password>" \
  -keyPwd "<password>"
```

The profile must list the bundle name `com.wasmer.sdk.harmony`, the matching
debug/release certificate, and an authorized device UDID for debug installs.

## Install and run

```bash
hdc list targets
hdc install -r harmony/entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.wasmer.sdk.harmony
hdc hilog | grep -i wasmer
```

On the demo screen press **Run hello.wasm**. The output pane shows the guest
greeting, arguments, environment, stdin echo, `/tmp` file round-trip, and exit
status.

### Emulator

A HarmonyOS emulator needs a downloaded system image:

1. DevEco Studio → **Tools → Device Manager → Local Emulator**.
2. Download a HarmonyOS 6.0.0 phone image (several GB).
3. Start the emulator and confirm `hdc list targets` shows it.

This workspace has no emulator image installed (the SDK image directory is
empty) and no physical device, so the HAP has not been launched on HarmonyOS.
The ArkTS layer compiles cleanly and the native layer passes its host test
suite; see [verification.md](verification.md).

## Inspecting the artifacts

```bash
$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf \
  -s harmony/wasmer/libs/arm64-v8a/libwasmer_sdk_ohos.so | grep napi_register_module_v1

unzip -l harmony/entry/build/default/outputs/default/entry-default-unsigned.hap \
  | grep -E 'libwasmer|demo.wasm'
```

The shared library must export `napi_register_module_v1`; otherwise the ArkTS
`import ... from "libwasmer_sdk_ohos.so"` fails at load time.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `OHOS clang not found` | Set `DEVECO_SDK_HOME` to the DevEco SDK root containing `default/openharmony/native` |
| `hvigorw not found` | Set `DEVECO_HOME` to the DevEco Studio `Contents` directory |
| `No signingConfig found` | Expected for the unsigned build; configure signing before installing |
| `there is no reactor running` at client creation | The core builds an HTTP client synchronously; creation must stay wrapped in `block_on` on napi's Tokio runtime |
| `HAP not installable` | Check signing, device API level (≥ 6.0.0/API 20), and ABI (`arm64-v8a`) |
| Link errors around `perf_event_open` | Ensure `vendor/perf-event-open-sys` is applied through the workspace patch |
| Guest filesystem writes fail | Use `/workspace` (or relative paths under it) for persistent data |
