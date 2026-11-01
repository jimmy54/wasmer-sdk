fn main() {
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("ohos") {
        // HarmonyOS resolves NAPI entry points from libace_napi.z.so. Without an
        // explicit dependency the library is built with BIND_NOW and dlopen
        // fails to relocate symbols such as napi_delete_reference.
        let ndk = std::env::var("OHOS_NDK_HOME")
            .map(|sdk| format!("{sdk}/native"))
            .or_else(|_| std::env::var("OHOS_SDK_NATIVE"))
            .or_else(|_| std::env::var("DEVECO_SDK_HOME").map(|sdk| format!("{sdk}/default/openharmony/native")))
            .expect("set OHOS_NDK_HOME to the HarmonyOS SDK (openharmony) directory");
        println!("cargo:rustc-link-search=native={ndk}/sysroot/usr/lib/aarch64-linux-ohos");
        println!("cargo:rustc-link-lib=dylib=ace_napi.z");
        println!("cargo:rerun-if-env-changed=OHOS_NDK_HOME");
        println!("cargo:rerun-if-env-changed=OHOS_SDK_NATIVE");
        println!("cargo:rerun-if-env-changed=DEVECO_SDK_HOME");
    }
    napi_build::setup();
}
