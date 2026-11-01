// V8-only host extensions that the Rust side expects every snapi engine to
// export. QuickJS exposes buffer data through napi_get_arraybuffer_info
// instead of leased views, so lease requests fail cleanly rather than handing
// guest code a pointer whose lifetime the host cannot track.
#include "node_api.h"
#include "unofficial_napi.h"

extern "C" napi_status NAPI_CDECL unofficial_napi_acquire_buffer_lease(
    napi_env /*env*/, napi_value /*value*/, size_t /*byte_offset*/,
    size_t /*byte_length*/, unofficial_napi_buffer_access_mode /*mode*/,
    unofficial_napi_buffer_lease* /*lease*/, void** /*data*/) {
  return napi_generic_failure;
}

extern "C" napi_status NAPI_CDECL unofficial_napi_release_buffer_lease(
    napi_env /*env*/, unofficial_napi_buffer_lease /*lease*/, bool /*modified*/) {
  return napi_generic_failure;
}
