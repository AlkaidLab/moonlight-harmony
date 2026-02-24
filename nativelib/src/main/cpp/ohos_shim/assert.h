/**
 * @file ohos_shim/assert.h
 * @brief Minimal assert.h shim for OHOS x86_64 target multiversioning compatibility.
 *
 * rswrapper.c uses #pragma clang attribute push(target(...)) to compile
 * multiple ISA variants. Each variant #includes nanors/rs.c which includes
 * <assert.h>. OHOS's assert.h declares __assert_fail, and re-declaring it
 * under different target attributes triggers a Clang error.
 *
 * Since NDEBUG is defined in rswrapper.c (assert is never called), we can
 * safely use this shim that only defines assert() as a no-op without
 * declaring __assert_fail.
 *
 * This shim is ONLY used for rswrapper.c via -isystem include path override.
 */

#undef assert
#define assert(x) ((void)0)
