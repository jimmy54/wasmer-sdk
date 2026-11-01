use std::{
    env, fs,
    io::Read,
    path::{Path, PathBuf},
};

const PREBUILT_V8_VERSION: &str = "11.9.9";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum V8Method {
    Local,
    Prebuilt,
    Source,
}

#[allow(unused)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum V8Origin {
    Local,
    Prebuilt,
}

#[derive(Debug, Clone)]
struct V8Config {
    include_dir: PathBuf,
    library_path: PathBuf,
    extra_links: Vec<ExtraLink>,
    #[allow(unused)]
    origin: V8Origin,
}

#[derive(Debug, Clone)]
enum ExtraLink {
    LibraryPath(PathBuf),
    Framework(PathBuf),
    Name(String),
}

fn main() {
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    if target_arch == "wasm32" {
        if env::var_os("CARGO_FEATURE_JS").is_none() {
            panic!("wasmer-napi on wasm32 requires the `js` feature");
        }
        // The wasm32 backend is implemented in Rust with wasm-bindgen and must
        // not download, build, or link the native V8 bridge.
        return;
    }

    // V8 publishes no HarmonyOS prebuilts and cannot be relocated from a
    // glibc build, so OHOS hosts use the bundled QuickJS N-API engine instead.
    if env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("ohos") {
        build_quickjs_backend();
        return;
    }

    println!("cargo:rerun-if-changed=src/napi_bridge_init.cc");
    println!("cargo:rerun-if-changed=include");
    println!("cargo:rerun-if-changed=lib/src");
    println!("cargo:rerun-if-changed=v8/src");
    println!("cargo:rerun-if-env-changed=V8_INCLUDE_DIR");
    println!("cargo:rerun-if-env-changed=V8_LIB_DIR");
    println!("cargo:rerun-if-env-changed=V8_DEFINES");
    println!("cargo:rerun-if-env-changed=NAPI_V8_BUILD_METHOD");
    println!("cargo:rerun-if-env-changed=NAPI_V8_DEFINES");
    println!("cargo:rerun-if-env-changed=NAPI_V8_EXTRA_LIBS");
    println!("cargo:rerun-if-env-changed=NAPI_V8_FORCE_LOCAL_BUILD");
    println!("cargo:rerun-if-env-changed=NAPI_V8_INCLUDE_DIR");
    println!("cargo:rerun-if-env-changed=NAPI_V8_LIBRARY");
    println!("cargo:rerun-if-env-changed=NAPI_V8_V8_DEFINES");
    println!("cargo:rerun-if-env-changed=NAPI_V8_V8_EXTRA_LIBS");
    println!("cargo:rerun-if-env-changed=NAPI_V8_V8_INCLUDE_DIR");
    println!("cargo:rerun-if-env-changed=NAPI_V8_V8_LIBRARY");
    println!("cargo:rerun-if-env-changed=NAPI_V8_V8_MONOLITH_LIB");

    let manifest_dir =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is not set"));
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is not set"));
    let napi_include = manifest_dir.join("include");
    let napi_lib_src = manifest_dir.join("lib/src");
    let napi_v8_src = manifest_dir.join("v8/src");
    let v8 = resolve_v8_config().unwrap_or_else(|err| panic!("{err}"));

    // The module is loaded into Node (or ArkVM), whose napi_* imports must
    // reach the host's N-API implementation. The embedded engine defines the
    // same entry points, so keep them in a private namespace; otherwise the
    // linker binds the host bridge's napi_* calls to that engine and it
    // receives an env it does not own.
    const HIDDEN: &str = "__attribute__((visibility(\"hidden\")))";
    let prefix_header = out_dir.join("snapi_engine_napi_prefix.h");
    write_napi_prefix_header(&napi_include, &prefix_header, "snapi_engine_");

    assert!(
        v8.include_dir.join("v8.h").exists(),
        "V8 headers not found in {}",
        v8.include_dir.display()
    );
    assert!(
        v8.library_path.exists(),
        "V8 library not found at {}",
        v8.library_path.display()
    );

    let v8_defines = read_env_value("V8_DEFINES", &["NAPI_V8_DEFINES", "NAPI_V8_V8_DEFINES"])
        .unwrap_or_else(|| "V8_COMPRESS_POINTERS".to_string());

    let mut build = cc::Build::new();
    build
        .cpp(true)
        .flag_if_supported("-std=c++20")
        .flag_if_supported("-fno-rtti")
        .flag_if_supported("-fvisibility=hidden")
        .flag("-include")
        .flag(&prefix_header)
        .flag_if_supported("-w")
        .define("NAPI_EXTERN", Some(HIDDEN))
        .include(&v8.include_dir)
        .include(napi_include.to_str().unwrap())
        .include(napi_lib_src.to_str().unwrap())
        .include(napi_v8_src.to_str().unwrap())
        .file("src/napi_bridge_init.cc")
        .file(napi_lib_src.join("napi_error_state.cc").to_str().unwrap())
        .file(
            napi_lib_src
                .join("napi_lifetime_tracker.cc")
                .to_str()
                .unwrap(),
        )
        .file(napi_lib_src.join("napi_buffer_lease.cc").to_str().unwrap())
        .file(napi_lib_src.join("napi_periodic_gate.cc").to_str().unwrap())
        .file(napi_lib_src.join("napi_text.cc").to_str().unwrap())
        .file(
            napi_lib_src
                .join("napi_typedarray_metadata.cc")
                .to_str()
                .unwrap(),
        )
        .file(napi_v8_src.join("js_native_api_v8.cc").to_str().unwrap())
        .file(
            napi_v8_src
                .join("internal/napi_escapable_handle_scope_wrapper.cc")
                .to_str()
                .unwrap(),
        )
        .file(
            napi_v8_src
                .join("internal/napi_external_wrapper.cc")
                .to_str()
                .unwrap(),
        )
        .file(
            napi_v8_src
                .join("internal/napi_function_callback_info.cc")
                .to_str()
                .unwrap(),
        )
        .file(
            napi_v8_src
                .join("internal/napi_getter_callback_info.cc")
                .to_str()
                .unwrap(),
        )
        .file(
            napi_v8_src
                .join("internal/napi_handle_scope_wrapper.cc")
                .to_str()
                .unwrap(),
        )
        .file(
            napi_v8_src
                .join("internal/napi_lifetime_tracker.cc")
                .to_str()
                .unwrap(),
        )
        .file(napi_v8_src.join("internal/napi_ref.cc").to_str().unwrap())
        .file(
            napi_v8_src
                .join("internal/napi_ref_tracker.cc")
                .to_str()
                .unwrap(),
        )
        .file(
            napi_v8_src
                .join("internal/napi_ref_with_data.cc")
                .to_str()
                .unwrap(),
        )
        .file(
            napi_v8_src
                .join("internal/napi_ref_with_finalizer.cc")
                .to_str()
                .unwrap(),
        )
        .file(
            napi_v8_src
                .join("internal/napi_setter_callback_info.cc")
                .to_str()
                .unwrap(),
        )
        .file(napi_v8_src.join("unofficial_napi.cc").to_str().unwrap())
        .file(
            napi_v8_src
                .join("unofficial_napi_error_utils.cc")
                .to_str()
                .unwrap(),
        )
        .file(
            napi_v8_src
                .join("unofficial_napi_contextify.cc")
                .to_str()
                .unwrap(),
        )
        .file(napi_v8_src.join("edge_v8_platform.cc").to_str().unwrap());

    for raw in v8_defines.split(&[';', ',', ' '][..]) {
        let entry = raw.trim();
        if entry.is_empty() {
            continue;
        }
        if let Some((name, value)) = entry.split_once('=') {
            build.define(name.trim(), Some(value.trim()));
        } else {
            build.define(entry, Some("1"));
        }
    }

    build.compile("napi_bridge");

    emit_library_link(&v8.library_path);
    for extra_link in &v8.extra_links {
        emit_extra_link(extra_link);
    }

    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "macos" || target_os == "ios" {
        println!("cargo:rustc-link-lib=dylib=c++");
    } else {
        println!("cargo:rustc-link-lib=dylib=stdc++");
        println!("cargo:rustc-link-lib=dylib=dl");
        println!("cargo:rustc-link-lib=dylib=m");
        println!("cargo:rustc-link-lib=dylib=pthread");
        println!("cargo:rustc-link-lib=dylib=rt");
        if target_os == "linux" && env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("aarch64") {
            println!("cargo:rustc-link-lib=dylib=atomic");
        }
    }
}

fn resolve_v8_config() -> Result<V8Config, String> {
    let include_override = read_env_value(
        "NAPI_V8_INCLUDE_DIR",
        &["V8_INCLUDE_DIR", "NAPI_V8_V8_INCLUDE_DIR"],
    );
    let library_override = read_env_value(
        "NAPI_V8_LIBRARY",
        &["NAPI_V8_V8_LIBRARY", "NAPI_V8_V8_MONOLITH_LIB"],
    );
    let lib_dir_override = env::var("V8_LIB_DIR")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let extra_override = read_env_value("NAPI_V8_EXTRA_LIBS", &["NAPI_V8_V8_EXTRA_LIBS"]);

    if include_override.is_some() || library_override.is_some() || lib_dir_override.is_some() {
        return resolve_explicit_v8(
            include_override,
            library_override,
            lib_dir_override,
            extra_override,
        );
    }

    let requested_method = requested_v8_method();
    match requested_method {
        V8Method::Local => resolve_local_v8(extra_override.as_deref()).ok_or_else(|| {
            "local V8 requested but no supported installation was found".to_string()
        }),
        V8Method::Prebuilt => {
            resolve_prebuilt_v8(extra_override.as_deref()).or_else(|prebuilt_err| {
                resolve_local_v8(extra_override.as_deref()).ok_or_else(|| {
                    format!("failed to resolve V8 via prebuilt or local strategies: {prebuilt_err}")
                })
            })
        }
        V8Method::Source => Err(
            "NAPI_V8_BUILD_METHOD=source is not supported by napi cargo build.rs yet".to_string(),
        ),
    }
}

fn resolve_explicit_v8(
    include_override: Option<String>,
    library_override: Option<String>,
    lib_dir_override: Option<String>,
    extra_override: Option<String>,
) -> Result<V8Config, String> {
    let include_dir = include_override
        .map(PathBuf::from)
        .ok_or_else(|| "V8 include directory is not set. Set NAPI_V8_INCLUDE_DIR.".to_string())?;

    let library_path = match (library_override, lib_dir_override) {
        (Some(path), _) => PathBuf::from(path),
        (None, Some(dir)) => resolve_primary_library(&PathBuf::from(dir))
            .ok_or_else(|| "V8 library not found in V8_LIB_DIR.".to_string())?,
        (None, None) => {
            return Err("V8 library path is not set. Set NAPI_V8_LIBRARY.".to_string());
        }
    };

    let extra_links = extra_override
        .as_deref()
        .map(parse_extra_links)
        .unwrap_or_else(|| default_local_extra_links(&library_path));

    Ok(V8Config {
        include_dir,
        library_path,
        extra_links,
        origin: V8Origin::Local,
    })
}

fn resolve_local_v8(extra_override: Option<&str>) -> Option<V8Config> {
    let mut candidates = Vec::new();
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "macos" {
        candidates.push(PathBuf::from("/opt/homebrew/Cellar/v8/14.5.201.9"));
        candidates.push(PathBuf::from("/opt/homebrew/opt/v8"));
    }

    for root in candidates {
        let include_dir = root.join("include");
        let library_path = root.join("lib/libv8.dylib");
        if include_dir.join("v8.h").exists() && library_path.exists() {
            let extra_links = extra_override
                .map(parse_extra_links)
                .unwrap_or_else(|| default_local_extra_links(&library_path));
            return Some(V8Config {
                include_dir,
                library_path,
                extra_links,
                origin: V8Origin::Local,
            });
        }
    }

    None
}

fn resolve_prebuilt_v8(extra_override: Option<&str>) -> Result<V8Config, String> {
    let (asset_name, platform_name) = prebuilt_asset_name()?;
    let out_dir = PathBuf::from(env::var("OUT_DIR").map_err(|err| err.to_string())?);
    let cache_dir = out_dir
        .join("v8-prebuilt")
        .join(PREBUILT_V8_VERSION)
        .join(platform_name);
    let archive_path = cache_dir.join(asset_name);

    std::fs::create_dir_all(&cache_dir)
        .map_err(|err| format!("failed to create {}: {err}", cache_dir.display()))?;

    if !cache_dir.join("include/v8.h").exists()
        || resolve_primary_library(&cache_dir.join("lib")).is_none()
    {
        download_prebuilt_archive(asset_name, &archive_path)?;
        unpack_prebuilt_archive(&archive_path, &cache_dir)?;
    }

    let include_dir = cache_dir.join("include");
    let library_dir = cache_dir.join("lib");
    let library_path = resolve_primary_library(&library_dir).ok_or_else(|| {
        format!(
            "prebuilt V8 archive did not produce an expected library under {}",
            library_dir.display()
        )
    })?;

    let extra_links = extra_override
        .map(parse_extra_links)
        .unwrap_or_else(default_prebuilt_extra_links);

    Ok(V8Config {
        include_dir,
        library_path,
        extra_links,
        origin: V8Origin::Prebuilt,
    })
}

fn requested_v8_method() -> V8Method {
    if env_truthy("NAPI_V8_FORCE_LOCAL_BUILD") {
        return V8Method::Local;
    }

    match env::var("NAPI_V8_BUILD_METHOD")
        .unwrap_or_else(|_| "prebuilt".to_string())
        .to_lowercase()
        .as_str()
    {
        "local" => V8Method::Local,
        "source" => V8Method::Source,
        _ => V8Method::Prebuilt,
    }
}

fn prebuilt_asset_name() -> Result<(&'static str, &'static str), String> {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();

    match (
        target_os.as_str(),
        target_arch.as_str(),
        target_env.as_str(),
    ) {
        ("macos", "aarch64", _) => Ok(("v8-darwin-aarch64.tar.xz", "darwin-arm64")),
        ("macos", "x86_64", _) => Ok(("v8-darwin-amd64.tar.xz", "darwin-amd64")),
        ("linux", "x86_64", "gnu") => Ok(("v8-linux-amd64.tar.xz", "linux-amd64")),
        ("linux", "aarch64", "gnu") => Ok(("v8-linux-arm64.tar.xz", "linux-arm64")),
        ("linux", "x86_64", "musl") => Ok(("v8-linux-musl-amd64.tar.xz", "linux-musl-amd64")),
        ("android", "aarch64", _) => Ok(("v8-android-arm64.tar.xz", "android-arm64")),
        ("windows", "x86_64", _) => Ok(("v8-windows-amd64.tar.xz", "windows-amd64")),
        (os, arch, env_kind) => Err(format!(
            "unsupported target for prebuilt V8: os={os}, arch={arch}, env={env_kind}"
        )),
    }
}

fn download_prebuilt_archive(asset_name: &str, archive_path: &Path) -> Result<(), String> {
    let url = format!(
        "https://github.com/wasmerio/v8-custom-builds/releases/download/{PREBUILT_V8_VERSION}/{asset_name}"
    );
    let response = ureq::get(&url)
        .call()
        .map_err(|err| format!("failed to download {url}: {err}"))?;

    let mut reader = response.into_reader();
    let mut tar_data = Vec::new();
    reader
        .read_to_end(&mut tar_data)
        .map_err(|err| format!("failed to read response body from {url}: {err}"))?;

    std::fs::write(archive_path, tar_data)
        .map_err(|err| format!("failed to write {}: {err}", archive_path.display()))?;

    Ok(())
}

fn unpack_prebuilt_archive(archive_path: &Path, cache_dir: &Path) -> Result<(), String> {
    let tar_data = std::fs::read(archive_path)
        .map_err(|err| format!("failed to read {}: {err}", archive_path.display()))?;
    let tar = xz::read::XzDecoder::new(tar_data.as_slice());
    let mut archive = tar::Archive::new(tar);
    archive
        .unpack(cache_dir)
        .map_err(|err| format!("failed to unpack {}: {err}", archive_path.display()))
}

fn resolve_primary_library(dir: &Path) -> Option<PathBuf> {
    for candidate in [
        "libv8.a",
        "libv8.so",
        "libv8.dylib",
        "libv8_monolith.a",
        "libv8_monolith.so",
        "libv8_monolith.dylib",
    ] {
        let path = dir.join(candidate);
        if path.exists() {
            return Some(path);
        }
    }
    None
}

fn default_local_extra_links(library_path: &Path) -> Vec<ExtraLink> {
    let mut extra_links = Vec::new();
    let Some(lib_dir) = library_path.parent() else {
        return extra_links;
    };

    for candidate in [
        "libv8_libplatform.a",
        "libv8_libplatform.so",
        "libv8_libplatform.dylib",
    ] {
        let path = lib_dir.join(candidate);
        if path.exists() {
            extra_links.push(ExtraLink::LibraryPath(path));
            break;
        }
    }

    for candidate in ["libv8_libbase.a", "libv8_libbase.so", "libv8_libbase.dylib"] {
        let path = lib_dir.join(candidate);
        if path.exists() {
            extra_links.push(ExtraLink::LibraryPath(path));
            break;
        }
    }

    extra_links
}

fn default_prebuilt_extra_links() -> Vec<ExtraLink> {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "macos" || target_os == "ios" {
        vec![ExtraLink::Framework(PathBuf::from(
            "/System/Library/Frameworks/CoreFoundation.framework",
        ))]
    } else {
        Vec::new()
    }
}

fn parse_extra_links(raw: &str) -> Vec<ExtraLink> {
    raw.split(&[';', ','][..])
        .filter_map(|entry| {
            let trimmed = entry.trim();
            if trimmed.is_empty() {
                return None;
            }

            if trimmed.ends_with(".framework") {
                return Some(ExtraLink::Framework(PathBuf::from(trimmed)));
            }

            let path = PathBuf::from(trimmed);
            if path.is_absolute() || path.parent().is_some() {
                return Some(ExtraLink::LibraryPath(path));
            }

            Some(ExtraLink::Name(trimmed.to_string()))
        })
        .collect()
}

fn emit_library_link(path: &Path) {
    let dir = path
        .parent()
        .expect("linked library path has no parent directory");
    println!("cargo:rustc-link-search=native={}", dir.display());

    let extension = path
        .extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or_default();
    let kind = if extension == "a" { "static" } else { "dylib" };
    let name = link_name_from_path(path);
    println!("cargo:rustc-link-lib={kind}={name}");
}

fn emit_extra_link(link: &ExtraLink) {
    match link {
        ExtraLink::LibraryPath(path) => emit_library_link(path),
        ExtraLink::Framework(path) => {
            let dir = path
                .parent()
                .expect("framework path has no parent directory");
            let name = path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .expect("framework path is not valid UTF-8");
            println!("cargo:rustc-link-search=framework={}", dir.display());
            println!("cargo:rustc-link-lib=framework={name}");
        }
        ExtraLink::Name(name) => {
            println!("cargo:rustc-link-lib={name}");
        }
    }
}

fn link_name_from_path(path: &Path) -> String {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .expect("library path is not valid UTF-8");
    let without_prefix = file_name.strip_prefix("lib").unwrap_or(file_name);
    let without_suffix = without_prefix
        .strip_suffix(".a")
        .or_else(|| without_prefix.strip_suffix(".so"))
        .or_else(|| without_prefix.strip_suffix(".dylib"))
        .unwrap_or(without_prefix);
    without_suffix.to_string()
}

fn read_env_value(name: &str, aliases: &[&str]) -> Option<String> {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            aliases.iter().find_map(|alias| {
                env::var(alias)
                    .ok()
                    .filter(|value| !value.trim().is_empty())
            })
        })
}

fn env_truthy(name: &str) -> bool {
    env::var(name)
        .ok()
        .map(|value| {
            let normalized = value.trim();
            !normalized.is_empty() && normalized != "0" && normalized.to_lowercase() != "false"
        })
        .unwrap_or(false)
}

// HarmonyOS build: compile the bundled QuickJS engine behind the same
// `snapi_bridge_*` interface the V8 backend exposes.
//
// The host module and the sandbox engine both speak N-API, so the engine's
// entry points are renamed behind a private prefix. Without that, the linker
// would satisfy the host's napi_* imports (which must reach ArkVM's
// libace_napi) with the engine's own definitions.
fn build_quickjs_backend() {
    const HIDDEN: &str = "__attribute__((visibility(\"hidden\")))";
    const PREFIX: &str = "snapi_qjs_";

    let manifest_dir =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is not set"));
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is not set"));

    let napi_include = manifest_dir.join("include");
    let napi_lib_src = manifest_dir.join("lib/src");
    let quickjs_root = manifest_dir.join("quickjs");
    let quickjs_src = quickjs_root.join("deps/quickjs");
    let napi_engine_src = quickjs_root.join("src");

    println!("cargo:rerun-if-changed=src/napi_bridge_init.cc");
    println!("cargo:rerun-if-changed=quickjs/src");
    println!("cargo:rerun-if-changed=quickjs/deps/quickjs");

    let prefix_header = out_dir.join("snapi_napi_prefix.h");
    write_napi_prefix_header(&napi_include, &prefix_header, PREFIX);

    let force_prefix = |build: &mut cc::Build| {
        build.flag("-include").flag(&prefix_header);
    };

    let mut core = cc::Build::new();
    core.flag_if_supported("-std=gnu11")
        .flag_if_supported("-fvisibility=hidden")
        .flag_if_supported("-funsigned-char")
        .flag_if_supported("-w")
        .define("_GNU_SOURCE", None)
        .define("QUICKJS_NG_BUILD", None)
        .include(&quickjs_src)
        .files(["dtoa.c", "libregexp.c", "libunicode.c", "quickjs.c"].map(|f| quickjs_src.join(f)))
        .cargo_metadata(false)
        .compile("quickjs_core");

    let mut engine = cc::Build::new();
    engine
        .cpp(true)
        .flag_if_supported("-std=c++20")
        .flag_if_supported("-fno-rtti")
        .flag_if_supported("-fvisibility=hidden")
        .flag_if_supported("-w")
        .define("NAPI_EXTERN", Some(HIDDEN))
        .define("NAPI_EXTENSION_WASMER_EXTERN", Some(HIDDEN))
        .define("NAPI_BUNDLED_QUICKJS", Some("1"))
        .include(&napi_include)
        .include(&napi_lib_src)
        .include(&napi_engine_src)
        .include(&quickjs_src);
    for dir in [&napi_engine_src, &napi_engine_src.join("internal"), &napi_lib_src] {
        for entry in fs::read_dir(dir).expect("engine source directory") {
            let path = entry.expect("engine source entry").path();
            let is_cc = path.extension().and_then(|ext| ext.to_str()) == Some("cc");
            let is_lifetime_tracker = path
                .file_name()
                .and_then(|name| name.to_str())
                .map(|name| name == "napi_lifetime_tracker.cc")
                .unwrap_or(false);
            // snapi_quickjs_compat.cc is compiled with the bridge below.
            let is_compat = path
                .file_name()
                .and_then(|name| name.to_str())
                .map(|name| name == "snapi_quickjs_compat.cc")
                .unwrap_or(false);
            if is_cc && !is_lifetime_tracker && !is_compat {
                engine.file(path);
            }
        }
    }
    force_prefix(&mut engine);
    engine.cargo_metadata(false).compile("napi_quickjs");

    let mut bridge = cc::Build::new();
    bridge
        .cpp(true)
        .flag_if_supported("-std=c++20")
        .flag_if_supported("-fno-rtti")
        .flag_if_supported("-fvisibility=hidden")
        .flag_if_supported("-w")
        .define("NAPI_EXTERN", Some(HIDDEN))
        .define("NAPI_EXTENSION_WASMER_EXTERN", Some(HIDDEN))
        .define("NAPI_BUNDLED_QUICKJS", Some("1"))
        .include(&napi_include)
        .include(&napi_engine_src)
        .include(&quickjs_src)
        .file(manifest_dir.join("src/napi_bridge_init.cc"))
        .file(napi_engine_src.join("snapi_quickjs_compat.cc"));
    force_prefix(&mut bridge);
    bridge.cargo_metadata(false).compile("napi_bridge_quickjs");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=napi_bridge_quickjs");
    println!("cargo:rustc-link-lib=static=napi_quickjs");
    println!("cargo:rustc-link-lib=static=quickjs_core");
    println!("cargo:rustc-link-lib=dylib=c++");
    println!("cargo:rustc-link-lib=dylib=m");
}

fn write_napi_prefix_header(include_dir: &Path, out: &Path, prefix: &str) {
    let mut names = Vec::new();
    for header in ["js_native_api.h", "node_api.h"] {
        let text = fs::read_to_string(include_dir.join(header)).expect("read N-API header");
        collect_napi_functions(&text, &mut names);
    }
    names.sort();
    names.dedup();

    let mut contents =
        String::from("/* Generated: private namespace for the bundled N-API engine. */\n");
    for name in names {
        contents.push_str(&format!("#define {name} {prefix}{name}\n"));
    }
    fs::write(out, contents).expect("write N-API prefix header");
}

// Collects `napi_*` identifiers used as function calls or declarations in the
// public headers, leaving parameter and type names such as `napi_value` alone.
fn collect_napi_functions(text: &str, out: &mut Vec<String>) {
    let bytes = text.as_bytes();
    let mut index = 0;
    while let Some(offset) = text[index..].find("napi_") {
        let start = index + offset;
        let mut end = start + "napi_".len();
        while end < bytes.len() && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_') {
            end += 1;
        }
        let mut after = end;
        while after < bytes.len() && bytes[after].is_ascii_whitespace() {
            after += 1;
        }
        if end > start + "napi_".len() && after < bytes.len() && bytes[after] == b'(' {
            out.push(text[start..end].to_string());
        }
        index = end;
    }
}
