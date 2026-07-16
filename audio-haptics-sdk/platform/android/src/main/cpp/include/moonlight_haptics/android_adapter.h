// SPDX-License-Identifier: Apache-2.0

#ifndef MOONLIGHT_HAPTICS_ANDROID_ADAPTER_H
#define MOONLIGHT_HAPTICS_ANDROID_ADAPTER_H

#include <stdint.h>

#if defined(_WIN32)
#define MH_ANDROID_EXPORT __declspec(dllexport)
#else
#define MH_ANDROID_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MhAndroidSession MhAndroidSession;

MH_ANDROID_EXPORT void mh_android_session_acquire(MhAndroidSession* session);
MH_ANDROID_EXPORT void mh_android_session_release(MhAndroidSession* session);
MH_ANDROID_EXPORT int32_t mh_android_session_configure(
    MhAndroidSession* session,
    uint32_t sample_rate,
    uint32_t channel_count);
MH_ANDROID_EXPORT void mh_android_session_reset(MhAndroidSession* session);
MH_ANDROID_EXPORT void mh_android_session_set_scene(
    MhAndroidSession* session,
    uint32_t scene);
MH_ANDROID_EXPORT void mh_android_session_set_sensitivity(
    MhAndroidSession* session,
    float sensitivity);
MH_ANDROID_EXPORT int32_t mh_android_session_process_i16(
    MhAndroidSession* session,
    const int16_t* interleaved_pcm,
    uint32_t frame_count);
MH_ANDROID_EXPORT void mh_android_session_notify(MhAndroidSession* session);
MH_ANDROID_EXPORT uint64_t mh_android_session_dropped_frames(
    const MhAndroidSession* session);

#ifdef __cplusplus
}
#endif

#endif // MOONLIGHT_HAPTICS_ANDROID_ADAPTER_H
