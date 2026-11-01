//! HarmonyOS Node-API bridge for the Wasmer SDK core.
//!
//! This module intentionally mirrors the wasm-bindgen façade in
//! `upstream-wasmer-sdk/js/bindgen/src/lib.rs`. The ArkTS layer above it
//! reproduces the public `@wasmer/sdk` API.

use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    sync::{
        atomic::{AtomicU32, Ordering},
        Arc, LazyLock, Mutex,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use napi::bindgen_prelude::*;
use napi_derive::napi;
use serde::Deserialize;
use serde_json::json;
use wasmer_sdk::{
    CacheConfig, Command, NetworkPolicy, Output, Package, PackageDefinition,
    PackageLoadCancellation, PackageLoadOptions, PackageSource, Process, ProcessHandle,
    Sandbox, SandboxBuilder, Stdio, TerminalOptions, Wasmer, WasmerConfig,
};

const ERROR_PREFIX: &str = "WASMER_ERROR::";
const MAX_EVENTS_PER_SINK: usize = 4096;
const MAX_TIMEOUT_MS: u64 = 9_007_199_254_740_991;

// HarmonyOS resolves native modules through the `napi_module_register`
// registry, not the exported `napi_register_module_v1` symbol used by Node.
// Without this constructor the loader finds no module and returns unrelated
// exports. `nm_modname` must match the library target name.
#[cfg(target_env = "ohos")]
#[ctor::ctor(unsafe)]
fn register_ohos_module() {
    static MODULE_NAME: &[u8] = b"wasmer_sdk_ohos\0";
    let mut module = napi::sys::napi_module {
        nm_version: 1,
        nm_flags: 0,
        nm_filename: std::ptr::null(),
        nm_register_func: Some(napi::bindgen_prelude::napi_register_module_v1),
        nm_modname: MODULE_NAME.as_ptr().cast(),
        nm_priv: std::ptr::null_mut(),
        reserved: [std::ptr::null_mut(); 4],
    };
    unsafe { napi::sys::napi_module_register(&mut module) };
}

static NEXT_TOKEN: AtomicU32 = AtomicU32::new(1);

/// Bytes marshalled into an engine-owned `Uint8Array`.
///
/// napi-rs' zero-copy path calls `napi_create_external_arraybuffer`, which
/// ArkVM rejects with a generic error rather than the
/// `napi_no_external_buffers_allowed` status that would trigger its copy
/// fallback.
struct JsBytes(Vec<u8>);

impl From<Vec<u8>> for JsBytes {
    fn from(bytes: Vec<u8>) -> Self {
        Self(bytes)
    }
}

impl ToNapiValue for JsBytes {
    unsafe fn to_napi_value(
        env: napi::sys::napi_env,
        val: Self,
    ) -> Result<napi::sys::napi_value> {
        let bytes = val.0;
        let mut array_buffer = std::ptr::null_mut();
        let mut data = std::ptr::null_mut();
        check_status!(
            napi::sys::napi_create_arraybuffer(env, bytes.len(), &mut data, &mut array_buffer),
            "Failed to create arraybuffer"
        )?;
        if !bytes.is_empty() {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), data.cast::<u8>(), bytes.len());
        }
        let mut typed_array = std::ptr::null_mut();
        check_status!(
            napi::sys::napi_create_typedarray(
                env,
                napi::sys::TypedarrayType::uint8_array,
                bytes.len(),
                array_buffer,
                0,
                &mut typed_array,
            ),
            "Failed to create Uint8Array"
        )?;
        Ok(typed_array)
    }
}

static PACKAGES: LazyLock<Mutex<HashMap<u32, Package>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static SINKS: LazyLock<Mutex<HashMap<u32, Arc<Mutex<Vec<String>>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static CANCELLATIONS: LazyLock<Mutex<HashMap<u32, PackageLoadCancellation>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn next_token() -> u32 {
    NEXT_TOKEN.fetch_add(1, Ordering::Relaxed)
}

fn error_with_code(code: &str, message: impl AsRef<str>) -> napi::Error {
    napi::Error::new(
        Status::GenericFailure,
        format!("{ERROR_PREFIX}{code}::{}", message.as_ref()),
    )
}

fn sdk_error(error: wasmer_sdk::Error) -> napi::Error {
    error_with_code(error.code(), error.to_string())
}

fn target_error(error: impl std::fmt::Display) -> napi::Error {
    error_with_code("TARGET_ERROR", error.to_string())
}

fn invalid_argument(message: impl AsRef<str>) -> napi::Error {
    error_with_code("INVALID_ARGUMENT", message)
}

fn register_package(package: Package) -> u32 {
    let token = next_token();
    PACKAGES.lock().unwrap().insert(token, package);
    token
}

fn lookup_package(token: u32) -> napi::Result<Package> {
    PACKAGES
        .lock()
        .unwrap()
        .get(&token)
        .cloned()
        .ok_or_else(|| invalid_argument("the package handle is no longer valid"))
}

fn register_package_core(package: Package) -> PackageCore {
    let token = register_package(package.clone());
    PackageCore { token, inner: package }
}

/// Read TCP listeners from procfs so port observation does not consume a
/// connection from single-client guest servers.
fn listening_tcp_ports() -> Vec<u32> {
    let mut ports = std::collections::BTreeSet::new();
    for path in ["/proc/net/tcp", "/proc/net/tcp6"] {
        let Ok(contents) = std::fs::read_to_string(path) else {
            continue;
        };
        for line in contents.lines().skip(1) {
            let mut fields = line.split_whitespace();
            let Some(local) = fields.nth(1) else {
                continue;
            };
            let Some(state) = fields.nth(1) else {
                continue;
            };
            if state != "0A" {
                continue;
            }
            if let Some((_, port)) = local.rsplit_once(':') {
                if let Ok(port) = u16::from_str_radix(port, 16) {
                    ports.insert(u32::from(port));
                }
            }
        }
    }
    ports.into_iter().collect()
}

fn duration_from_ms(ms: f64) -> napi::Result<Duration> {
    if !ms.is_finite() || ms.fract() != 0.0 || ms < 0.0 || ms > MAX_TIMEOUT_MS as f64 {
        return Err(invalid_argument(format!(
            "`timeoutMs` must be an integer between 0 and {MAX_TIMEOUT_MS}, inclusive"
        )));
    }
    Ok(Duration::from_millis(ms as u64))
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClientOptions {
    cache_root: Option<String>,
    #[serde(default)]
    ephemeral_cache: bool,
    output_bytes: Option<f64>,
}

#[derive(Debug, Default, Deserialize)]
struct PackageCommandDefinitionJson {
    module: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PackageDefinitionJson {
    commands: BTreeMap<String, PackageCommandDefinitionJson>,
    entrypoint: Option<String>,
}

/// A polling progress sink. The ArkTS layer drains it while a load is running
/// and republishes the snapshots through the public `onProgress` callback.
#[napi(js_name = "ProgressSink")]
pub struct ProgressSink {
    token: u32,
}

#[napi]
impl ProgressSink {
    #[napi(constructor)]
    pub fn new() -> Self {
        let token = next_token();
        SINKS
            .lock()
            .unwrap()
            .insert(token, Arc::new(Mutex::new(Vec::new())));
        Self { token }
    }

    #[napi(getter)]
    pub fn token(&self) -> u32 {
        self.token
    }

    #[napi]
    pub fn drain(&self) -> Vec<String> {
        let sink = SINKS.lock().unwrap().get(&self.token).cloned();
        let Some(sink) = sink else {
            return Vec::new();
        };
        let mut events = sink.lock().unwrap();
        std::mem::take(&mut *events)
    }

    #[napi]
    pub fn clear(&self) {
        if let Some(sink) = SINKS.lock().unwrap().get(&self.token).cloned() {
            sink.lock().unwrap().clear();
        }
    }
}

impl Drop for ProgressSink {
    fn drop(&mut self) {
        SINKS.lock().unwrap().remove(&self.token);
    }
}

#[napi(js_name = "PackageLoadCancellationCore")]
pub struct PackageLoadCancellationCore {
    token: u32,
    inner: PackageLoadCancellation,
}

#[napi]
impl PackageLoadCancellationCore {
    #[napi(constructor)]
    pub fn new() -> Self {
        let token = next_token();
        let inner = PackageLoadCancellation::default();
        CANCELLATIONS
            .lock()
            .unwrap()
            .insert(token, inner.clone());
        Self { token, inner }
    }

    #[napi(getter)]
    pub fn token(&self) -> u32 {
        self.token
    }

    #[napi]
    pub fn cancel(&self) {
        self.inner.cancel();
    }
}

impl Drop for PackageLoadCancellationCore {
    fn drop(&mut self) {
        CANCELLATIONS.lock().unwrap().remove(&self.token);
    }
}

#[napi(js_name = "WasmerCore")]
pub struct WasmerCore {
    inner: Wasmer,
    ephemeral_dir: Mutex<Option<PathBuf>>,
}

#[napi]
impl WasmerCore {
    /// Create a client. `options_json` is
    /// `{ cacheRoot?: string, ephemeralCache?: boolean, outputBytes?: number }`.
    #[napi(factory)]
    pub fn create(options_json: String) -> Result<Self> {
        let options: ClientOptions = serde_json::from_str(&options_json)
            .map_err(|error| invalid_argument(format!("invalid client options: {error}")))?;
        let output_bytes = match options.output_bytes {
            None => 16 * 1024 * 1024,
            Some(value) => {
                if !value.is_finite()
                    || value.fract() != 0.0
                    || value < 0.0
                    || value > f64::from(u32::MAX)
                {
                    return Err(invalid_argument(
                        "`outputBytes` must be an integer between 0 and 4294967295, inclusive",
                    ));
                }
                value as usize
            }
        };

        let mut cache_root = PathBuf::from(
            options
                .cache_root
                .unwrap_or_else(|| ".wasmer".to_owned()),
        );
        let mut ephemeral_dir = None;
        if options.ephemeral_cache {
            let stamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or_default();
            cache_root = cache_root.join(format!("ephemeral-{}-{stamp}", std::process::id()));
            ephemeral_dir = Some(cache_root.clone());
        }

        let config = WasmerConfig {
            cache: CacheConfig { root: cache_root },
            output_bytes,
        };
        // wasix builds a reqwest client here, which requires a Tokio reactor even
        // though this N-API factory is synchronous.
        let inner =
            block_on(async { Wasmer::with_config(config).map_err(sdk_error) })?;
        Ok(Self {
            inner,
            ephemeral_dir: Mutex::new(ephemeral_dir),
        })
    }

    #[napi(js_name = "createPackage")]
    pub async fn create_package(
        &self,
        definition_json: String,
        module_names: Vec<String>,
        module_bytes: Vec<Uint8Array>,
        file_names: Vec<String>,
        file_bytes: Vec<Uint8Array>,
    ) -> Result<u32> {
        if module_names.len() != module_bytes.len() {
            return Err(invalid_argument(
                "module names and module bytes must have the same length",
            ));
        }
        if file_names.len() != file_bytes.len() {
            return Err(invalid_argument(
                "file names and file bytes must have the same length",
            ));
        }
        let definition: PackageDefinitionJson = serde_json::from_str(&definition_json)
            .map_err(|error| invalid_argument(format!("invalid package definition: {error}")))?;
        let modules = module_names
            .into_iter()
            .zip(module_bytes)
            .map(|(name, bytes)| (name, bytes.as_ref().to_vec().into()))
            .collect();
        let files = file_names
            .into_iter()
            .zip(file_bytes)
            .map(|(name, bytes)| (name, bytes.as_ref().to_vec().into()))
            .collect();
        let definition = PackageDefinition {
            modules,
            commands: definition
                .commands
                .into_iter()
                .map(|(name, command)| {
                    (
                        name,
                        wasmer_sdk::PackageCommandDefinition {
                            module: command.module,
                        },
                    )
                })
                .collect(),
            entrypoint: definition.entrypoint,
            files,
        };
        let package = self
            .inner
            .packages()
            .create(definition)
            .await
            .map_err(sdk_error)?;
        Ok(register_package(package))
    }

    #[napi(js_name = "loadPackage")]
    pub async fn load_package(&self, specifier: String) -> Result<u32> {
        let package = self
            .inner
            .packages()
            .load(specifier)
            .await
            .map_err(sdk_error)?;
        Ok(register_package(package))
    }

    #[napi(js_name = "loadPackageBytes")]
    pub async fn load_package_bytes(&self, bytes: Uint8Array) -> Result<u32> {
        let package = self
            .inner
            .packages()
            .load(PackageSource::bytes(bytes.as_ref().to_vec()))
            .await
            .map_err(sdk_error)?;
        Ok(register_package(package))
    }

    /// Load several packages concurrently, sharing in-flight downloads.
    /// Strings are registry specifiers; buffers are WEBC or raw module bytes.
    #[napi(js_name = "loadPackages")]
    pub async fn load_packages(
        &self,
        sources: Vec<Either<String, Uint8Array>>,
        sink_token: Option<u32>,
        cancellation_token: Option<u32>,
    ) -> Result<Vec<u32>> {
        let mut options = PackageLoadOptions::default();
        if let Some(token) = sink_token {
            let sink = SINKS
                .lock()
                .unwrap()
                .get(&token)
                .cloned()
                .ok_or_else(|| invalid_argument("the progress sink is no longer valid"))?;
            options = options.on_progress(move |progress| {
                if let Ok(json) = serde_json::to_string(&progress) {
                    let mut events = sink.lock().unwrap();
                    if events.len() >= MAX_EVENTS_PER_SINK {
                        events.remove(0);
                    }
                    events.push(json);
                }
            });
        }
        if let Some(token) = cancellation_token {
            let cancellation = CANCELLATIONS
                .lock()
                .unwrap()
                .get(&token)
                .cloned()
                .ok_or_else(|| invalid_argument("the cancellation handle is no longer valid"))?;
            options = options.cancellation(cancellation);
        }
        let sources = sources
            .into_iter()
            .map(|source| match source {
                Either::A(specifier) => PackageSource::from(specifier),
                Either::B(bytes) => PackageSource::bytes(bytes.as_ref().to_vec()),
            })
            .collect::<Vec<_>>();
        let packages = self
            .inner
            .packages()
            .load_many_with_options(sources, options)
            .await
            .map_err(sdk_error)?;
        Ok(packages
            .into_iter()
            .map(register_package)
            .collect::<Vec<_>>())
    }

    /// Wrap a package token returned by this client in a JS class.
    #[napi(js_name = "wrapPackage")]
    pub fn wrap_package(&self, token: u32) -> Result<PackageCore> {
        let inner = lookup_package(token)?;
        Ok(PackageCore { token, inner })
    }

    #[napi(js_name = "sandbox")]
    pub fn sandbox(&self) -> SandboxBuilderCore {
        SandboxBuilderCore {
            inner: Mutex::new(Some(self.inner.sandboxes().create())),
        }
    }

    #[napi]
    pub async fn shutdown(&self) -> Result<()> {
        self.inner.shutdown().await.map_err(sdk_error)?;
        let ephemeral = self.ephemeral_dir.lock().unwrap().take();
        if let Some(path) = ephemeral {
            let _ = std::fs::remove_dir_all(path);
        }
        Ok(())
    }
}

#[napi(js_name = "PackageCore")]
pub struct PackageCore {
    token: u32,
    inner: Package,
}

#[napi]
impl PackageCore {
    #[napi(getter)]
    pub fn id(&self) -> String {
        self.inner.id()
    }

    #[napi(getter)]
    pub fn commands(&self) -> Vec<String> {
        self.inner.commands()
    }

    #[napi(getter)]
    pub fn entrypoint(&self) -> Option<String> {
        self.inner.entrypoint()
    }

    #[napi(js_name = "hasCommand")]
    pub fn has_command(&self, name: String) -> bool {
        self.inner.command(name).is_ok()
    }

    #[napi(getter)]
    pub fn token(&self) -> u32 {
        self.token
    }
}

impl Drop for PackageCore {
    fn drop(&mut self) {
        PACKAGES.lock().unwrap().remove(&self.token);
    }
}

#[napi(js_name = "SandboxBuilderCore")]
pub struct SandboxBuilderCore {
    inner: Mutex<Option<SandboxBuilder>>,
}

#[napi]
impl SandboxBuilderCore {
    #[napi]
    pub fn package(&self, package_token: u32) -> Result<()> {
        let package = lookup_package(package_token)?;
        self.with_builder(|builder| Ok(builder.package(package)))
    }

    #[napi]
    pub fn file(&self, path: String, bytes: Uint8Array) -> Result<()> {
        self.with_builder(|builder| Ok(builder.file(path, bytes.as_ref().to_vec())))
    }

    #[napi]
    pub fn env(&self, key: String, value: String) -> Result<()> {
        self.with_builder(|builder| Ok(builder.env(key, value)))
    }

    /// Configure guest networking from a stable mode string.
    ///
    /// HarmonyOS exposes real host networking, so the browser `http` and
    /// `wisp` modes are served by the host network stack.
    #[napi]
    pub fn network(&self, mode: String) -> Result<()> {
        let policy = match mode.as_str() {
            "disabled" => NetworkPolicy::Disabled,
            "host" | "http" | "wisp" => NetworkPolicy::Host,
            other => {
                return Err(invalid_argument(format!(
                    "unsupported network mode `{other}`"
                )))
            }
        };
        self.with_builder(|builder| Ok(builder.network(policy)))
    }

    #[napi]
    pub async fn start(&self) -> Result<SandboxCore> {
        let builder = self
            .inner
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| error_with_code("TARGET_ERROR", "sandbox builder was already consumed"))?;
        #[allow(deprecated)]
        let inner = builder.start().await.map_err(sdk_error)?;
        Ok(SandboxCore { inner })
    }
}

impl SandboxBuilderCore {
    fn with_builder(
        &self,
        apply: impl FnOnce(SandboxBuilder) -> Result<SandboxBuilder>,
    ) -> Result<()> {
        let mut slot = self.inner.lock().unwrap();
        let builder = slot
            .take()
            .ok_or_else(|| error_with_code("TARGET_ERROR", "sandbox builder was already consumed"))?;
        *slot = Some(apply(builder)?);
        Ok(())
    }
}

#[napi(js_name = "SandboxCore")]
pub struct SandboxCore {
    inner: Sandbox,
}

#[napi]
impl SandboxCore {
    #[napi]
    pub fn command(&self, name: String) -> CommandCore {
        CommandCore {
            inner: Mutex::new(Some(self.inner.command(name))),
        }
    }

    #[napi(js_name = "commandPackage")]
    pub fn command_package(&self, package_token: u32) -> Result<CommandCore> {
        let package = lookup_package(package_token)?;
        Ok(CommandCore {
            inner: Mutex::new(Some(self.inner.command(package))),
        })
    }

    /// A command explicitly qualified by its package.
    #[napi(js_name = "commandRef")]
    pub fn command_ref(&self, package_token: u32, name: String) -> Result<CommandCore> {
        let package = lookup_package(package_token)?;
        let reference = package.command(name).map_err(sdk_error)?;
        Ok(CommandCore {
            inner: Mutex::new(Some(self.inner.command(reference))),
        })
    }

    #[napi(js_name = "installPackage")]
    pub async fn install_package(&self, specifier: String) -> Result<PackageCore> {
        let package = self
            .inner
            .install_package(specifier)
            .await
            .map_err(sdk_error)?;
        Ok(register_package_core(package))
    }

    #[napi(js_name = "installPackageBytes")]
    pub async fn install_package_bytes(&self, bytes: Uint8Array) -> Result<PackageCore> {
        let package = self
            .inner
            .install_package(PackageSource::bytes(bytes.as_ref().to_vec()))
            .await
            .map_err(sdk_error)?;
        Ok(register_package_core(package))
    }

    #[napi(js_name = "installPackageRef")]
    pub async fn install_package_ref(&self, package_token: u32) -> Result<PackageCore> {
        let package = lookup_package(package_token)?;
        let installed = self
            .inner
            .install_package(package)
            .await
            .map_err(sdk_error)?;
        Ok(register_package_core(installed))
    }

    /// TCP ports in the LISTEN state in this process's network namespace.
    #[napi(js_name = "listeningPorts")]
    pub fn listening_ports(&self) -> Vec<u32> {
        listening_tcp_ports()
    }

    #[napi(js_name = "isPortListening")]
    pub fn is_port_listening(&self, port: u32) -> bool {
        u16::try_from(port)
            .map(|port| listening_tcp_ports().contains(&u32::from(port)))
            .unwrap_or(false)
    }

    #[napi(js_name = "writeFile")]
    pub async fn write_file(&self, path: String, bytes: Uint8Array) -> Result<()> {
        self.inner
            .fs()
            .write(path, bytes.as_ref().to_vec())
            .await
            .map_err(sdk_error)
    }

    #[napi(js_name = "readFile")]
    pub async fn read_file(&self, path: String) -> Result<JsBytes> {
        let bytes = self.inner.fs().read(path).await.map_err(sdk_error)?;
        Ok(bytes.into())
    }

    #[napi]
    pub fn mkdir(&self, path: String, recursive: bool) -> Result<()> {
        if recursive {
            self.inner.fs().create_dir_all(path).map_err(sdk_error)
        } else {
            self.inner.fs().create_dir(path).map_err(sdk_error)
        }
    }

    #[napi(js_name = "readDir")]
    pub fn read_dir(&self, path: String) -> Result<String> {
        let entries = self
            .inner
            .fs()
            .read_dir(path)
            .map_err(sdk_error)?
            .into_iter()
            .map(|entry| {
                let kind = match entry.metadata.file_type {
                    wasmer_sdk::FileType::Directory => "directory",
                    wasmer_sdk::FileType::File => "file",
                };
                json!({
                    "name": entry.name,
                    "kind": kind,
                    "size": entry.metadata.len,
                })
            })
            .collect::<Vec<_>>();
        serde_json::to_string(&entries).map_err(target_error)
    }

    #[napi]
    pub fn stat(&self, path: String) -> Result<String> {
        let metadata = self.inner.fs().stat(path).map_err(sdk_error)?;
        let kind = match metadata.file_type {
            wasmer_sdk::FileType::Directory => "directory",
            wasmer_sdk::FileType::File => "file",
        };
        serde_json::to_string(&json!({ "kind": kind, "size": metadata.len })).map_err(target_error)
    }

    #[napi]
    pub fn remove(&self, path: String, recursive: bool) -> Result<()> {
        self.inner.fs().remove(path, recursive).map_err(sdk_error)
    }

    #[napi]
    pub async fn rename(&self, from: String, to: String) -> Result<()> {
        self.inner.fs().rename(from, to).await.map_err(sdk_error)
    }

    /// Wait until a guest TCP listener accepts connections on `port`.
    #[napi(js_name = "waitForPort")]
    pub async fn wait_for_port(&self, port: u32, timeout_ms: f64) -> Result<()> {
        let port = u16::try_from(port)
            .ok()
            .filter(|port| *port != 0)
            .ok_or_else(|| invalid_argument("`port` must be between 1 and 65535"))?;
        let timeout = duration_from_ms(timeout_ms)?;
        self.inner
            .ports()
            .wait(port, timeout)
            .await
            .map_err(sdk_error)
    }

    #[napi]
    pub async fn close(&self) -> Result<()> {
        self.inner.close().await.map_err(sdk_error)
    }
}

#[napi(js_name = "CommandCore")]
pub struct CommandCore {
    inner: Mutex<Option<Command>>,
}

#[napi]
impl CommandCore {
    #[napi]
    pub fn args(&self, args: Vec<String>) -> Result<()> {
        self.with_command(|command| {
            command.args(args);
            Ok(())
        })
    }

    #[napi]
    pub fn env(&self, key: String, value: String) -> Result<()> {
        self.with_command(|command| {
            command.env(key, value);
            Ok(())
        })
    }

    #[napi(js_name = "currentDir")]
    pub fn current_dir(&self, path: String) -> Result<()> {
        self.with_command(|command| {
            command.current_dir(path);
            Ok(())
        })
    }

    #[napi]
    pub fn input(&self, bytes: Uint8Array) -> Result<()> {
        self.with_command(|command| {
            command.input(bytes.as_ref().to_vec());
            Ok(())
        })
    }

    #[napi(js_name = "outputBytes")]
    pub fn output_bytes(&self, bytes: u32) -> Result<()> {
        self.with_command(|command| {
            command.output_bytes(bytes as usize);
            Ok(())
        })
    }

    #[napi(js_name = "timeoutMs")]
    pub fn timeout_ms(&self, milliseconds: f64) -> Result<()> {
        let timeout = duration_from_ms(milliseconds)?;
        self.with_command(|command| {
            command.timeout(timeout);
            Ok(())
        })
    }

    /// Attach an interactive terminal with the given character dimensions.
    #[napi]
    pub fn terminal(&self, columns: u32, rows: u32) -> Result<()> {
        self.with_command(|command| {
            command.terminal(TerminalOptions::new(columns, rows));
            Ok(())
        })
    }

    #[napi(js_name = "stdinMode")]
    pub fn stdin_mode(&self, mode: String) -> Result<()> {
        let stdio = match mode.as_str() {
            "pipe" => Stdio::Piped,
            "closed" => Stdio::Null,
            other => return Err(unsupported_stdio(other)),
        };
        self.with_command(|command| {
            command.stdin(stdio);
            Ok(())
        })
    }

    #[napi(js_name = "stdoutMode")]
    pub fn stdout_mode(&self, mode: String) -> Result<()> {
        let stdio = parse_output_mode(&mode)?;
        self.with_command(|command| {
            command.stdout(stdio);
            Ok(())
        })
    }

    #[napi(js_name = "stderrMode")]
    pub fn stderr_mode(&self, mode: String) -> Result<()> {
        let stdio = parse_output_mode(&mode)?;
        self.with_command(|command| {
            command.stderr(stdio);
            Ok(())
        })
    }

    #[napi]
    pub async fn run(&self) -> Result<OutputCore> {
        let mut command = self.take()?;
        let output = command.output().await.map_err(sdk_error)?;
        Ok(OutputCore { inner: output })
    }

    #[napi]
    pub async fn spawn(&self) -> Result<ProcessCore> {
        let mut command = self.take()?;
        let mut process = command.spawn().await.map_err(sdk_error)?;
        let id = process.id();
        let handle = process.handle();
        let stdin = process.take_stdin();
        let stdout = process.take_stdout();
        let stderr = process.take_stderr();
        Ok(ProcessCore {
            id,
            handle,
            process: tokio::sync::Mutex::new(process),
            stdin: tokio::sync::Mutex::new(stdin),
            stdout: tokio::sync::Mutex::new(stdout),
            stderr: tokio::sync::Mutex::new(stderr),
        })
    }
}

impl CommandCore {
    fn with_command(&self, apply: impl FnOnce(&mut Command) -> Result<()>) -> Result<()> {
        let mut slot = self.inner.lock().unwrap();
        let command = slot
            .as_mut()
            .ok_or_else(|| error_with_code("TARGET_ERROR", "command was already consumed"))?;
        apply(command)
    }

    fn take(&self) -> Result<Command> {
        self.inner
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| error_with_code("TARGET_ERROR", "command was already consumed"))
    }
}

fn parse_output_mode(mode: &str) -> Result<Stdio> {
    match mode {
        "pipe" => Ok(Stdio::Piped),
        "capture" => Ok(Stdio::Capture),
        "discard" => Ok(Stdio::Null),
        other => Err(unsupported_stdio(other)),
    }
}

fn unsupported_stdio(mode: &str) -> napi::Error {
    error_with_code(
        "TARGET_ERROR",
        format!("unsupported stdio mode `{mode}`"),
    )
}

#[napi(js_name = "OutputCore")]
pub struct OutputCore {
    inner: Output,
}

#[napi]
impl OutputCore {
    #[napi(getter, js_name = "exitCode")]
    pub fn exit_code(&self) -> i32 {
        self.inner.status.code()
    }

    #[napi(getter)]
    pub fn ok(&self) -> bool {
        self.inner.ok()
    }

    /// Why the process stopped: `"exited"`, `"terminated"`, or `"timeout"`.
    #[napi(getter)]
    pub fn reason(&self) -> String {
        self.inner.reason.as_str().to_owned()
    }

    #[napi(getter)]
    pub fn stdout(&self) -> JsBytes {
        self.inner.stdout.bytes().to_vec().into()
    }

    #[napi(getter)]
    pub fn stderr(&self) -> JsBytes {
        self.inner.stderr.bytes().to_vec().into()
    }

    #[napi(getter, js_name = "stdoutTruncated")]
    pub fn stdout_truncated(&self) -> bool {
        self.inner.stdout.truncated()
    }

    #[napi(getter, js_name = "stderrTruncated")]
    pub fn stderr_truncated(&self) -> bool {
        self.inner.stderr.truncated()
    }
}

#[napi(js_name = "ProcessCore")]
pub struct ProcessCore {
    id: u32,
    /// Signals never contend with a concurrent `wait()`: they go through the
    /// lock-free handle, not the mutex that `wait()` holds.
    handle: ProcessHandle,
    process: tokio::sync::Mutex<Process>,
    stdin: tokio::sync::Mutex<Option<wasmer_sdk::ProcessStdin>>,
    stdout: tokio::sync::Mutex<Option<wasmer_sdk::ProcessStdout>>,
    stderr: tokio::sync::Mutex<Option<wasmer_sdk::ProcessStderr>>,
}

#[napi]
impl ProcessCore {
    #[napi(getter)]
    pub fn id(&self) -> u32 {
        self.id
    }

    #[napi(js_name = "writeStdin")]
    pub async fn write_stdin(&self, bytes: Uint8Array) -> Result<()> {
        use tokio::io::AsyncWriteExt;
        let mut stdin = self.stdin.lock().await;
        stdin
            .as_mut()
            .ok_or_else(|| error_with_code("TARGET_ERROR", "stdin is closed"))?
            .write_all(&bytes)
            .await
            .map_err(target_error)
    }

    #[napi(js_name = "closeStdin")]
    pub async fn close_stdin(&self) -> Result<()> {
        let mut stdin = self.stdin.lock().await.take();
        if let Some(stdin) = stdin.as_mut() {
            stdin.close().await.map_err(target_error)?;
        }
        Ok(())
    }

    #[napi(js_name = "readStdout")]
    pub async fn read_stdout(&self, max_bytes: u32) -> Result<Option<JsBytes>> {
        read_stream(&self.stdout, max_bytes).await
    }

    #[napi(js_name = "readStderr")]
    pub async fn read_stderr(&self, max_bytes: u32) -> Result<Option<JsBytes>> {
        read_stream(&self.stderr, max_bytes).await
    }

    #[napi]
    pub async fn wait(&self) -> Result<OutputCore> {
        let output = self
            .process
            .lock()
            .await
            .wait()
            .await
            .map_err(sdk_error)?;
        Ok(OutputCore { inner: output })
    }

    #[napi]
    pub async fn terminate(&self, grace_ms: f64) -> Result<()> {
        let grace = duration_from_ms(grace_ms)?;
        self.handle.terminate(grace).await;
        Ok(())
    }

    #[napi]
    pub fn kill(&self) {
        self.handle.kill();
    }

    #[napi(js_name = "resizeTerminal")]
    pub fn resize_terminal(&self, columns: u32, rows: u32) -> Result<()> {
        self.handle
            .resize_terminal(columns, rows)
            .map_err(sdk_error)
    }
}

async fn read_stream<S>(
    stream: &tokio::sync::Mutex<Option<S>>,
    max_bytes: u32,
) -> Result<Option<JsBytes>>
where
    S: tokio::io::AsyncRead + Unpin,
{
    use tokio::io::AsyncReadExt;
    if max_bytes == 0 {
        return Err(invalid_argument(
            "`maxBytes` must be an integer greater than zero",
        ));
    }
    let mut stream = stream.lock().await;
    let Some(reader) = stream.as_mut() else {
        return Ok(None);
    };
    let mut bytes = vec![0_u8; max_bytes as usize];
    let length = reader.read(&mut bytes).await.map_err(target_error)?;
    if length == 0 {
        stream.take();
        return Ok(None);
    }
    bytes.truncate(length);
    Ok(Some(bytes.into()))
}
