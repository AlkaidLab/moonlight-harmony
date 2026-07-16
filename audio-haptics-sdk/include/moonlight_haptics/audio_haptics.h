// SPDX-License-Identifier: Apache-2.0

#ifndef MOONLIGHT_HAPTICS_AUDIO_HAPTICS_H
#define MOONLIGHT_HAPTICS_AUDIO_HAPTICS_H

#include <stddef.h>
#include <stdint.h>

#include "moonlight_haptics/version.h"

#if defined(_WIN32) && !defined(MOONLIGHT_HAPTICS_STATIC)
#  if defined(MOONLIGHT_HAPTICS_BUILDING_LIBRARY)
#    define MOONLIGHT_HAPTICS_API __declspec(dllexport)
#  else
#    define MOONLIGHT_HAPTICS_API __declspec(dllimport)
#  endif
#elif defined(__GNUC__) && !defined(MOONLIGHT_HAPTICS_STATIC)
#  define MOONLIGHT_HAPTICS_API __attribute__((visibility("default")))
#else
#  define MOONLIGHT_HAPTICS_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AhEngine AhEngine;

typedef int32_t AhStatus;
enum {
    AH_STATUS_OK = 0,
    AH_STATUS_OUTPUT_AVAILABLE = 1,
    AH_STATUS_INVALID_ARGUMENT = -1,
    AH_STATUS_UNSUPPORTED = -2,
    AH_STATUS_BUFFER_TOO_SMALL = -3,
    AH_STATUS_OUT_OF_MEMORY = -4,
    AH_STATUS_BAD_STATE = -5,
    AH_STATUS_RECREATE_REQUIRED = -6
};

typedef uint32_t AhScene;
enum {
    AH_SCENE_GAME = 0,
    AH_SCENE_MUSIC = 1,
    AH_SCENE_AUTO = 2,
    AH_SCENE_UNKNOWN = 3
};

typedef uint32_t AhFrameFlags;
enum {
    AH_FRAME_NONE = 0,
    AH_FRAME_CONTINUOUS_CHANGED = 1u << 0,
    AH_FRAME_TRANSIENT = 1u << 1,
    AH_FRAME_STOP = 1u << 2,
    AH_FRAME_SCENE_CHANGED = 1u << 3,
    /* Beat inferred by the causal rhythm clock with current acoustic support. */
    AH_FRAME_RHYTHM_PREDICTED = 1u << 4,
    /* First MUSIC transient after reset or at least 30 seconds without one. */
    AH_FRAME_MUSIC_RESTART = 1u << 5
};

typedef struct AhConfig {
    uint32_t struct_size;
    uint32_t sample_rate;
    uint32_t channel_count;
    uint32_t requested_scene;     /* AhScene */
    float sensitivity;            /* 0.1 .. 3.0 */
    float output_gain;            /* 0.0 .. 1.0 */
    uint32_t feature_flags;       /* Must be 0 in ABI v1. */
    uint32_t reserved[8];
} AhConfig;

typedef struct AhProcessInput {
    uint32_t struct_size;
    const int16_t* interleaved_pcm;
    uint32_t frame_count;         /* Samples per channel. */
    uint64_t first_sample_time_us;
} AhProcessInput;

typedef struct AhHapticFrame {
    uint32_t struct_size;
    uint32_t flags;               /* AhFrameFlags bitset. */
    uint64_t timestamp_us;

    float continuous_amplitude;  /* 0.0 .. 1.0 */
    float transient_amplitude;   /* 0.0 .. 1.0 */
    float transient_duration_ms;
    float sharpness;              /* 0.0 heavy .. 1.0 crisp */
    float low_band_ratio;         /* 0.0 .. 1.0 */
    float stereo_pan;             /* -1.0 left .. 1.0 right */
    float confidence;             /* 0.0 .. 1.0 */

    uint32_t active_scene;        /* AhScene */
    /*
     * ABI v1 diagnostic extension: reserved[0..2] contain the IEEE-754 bit
     * patterns for candidate rhythm tempo BPM, confidence, and phase;
     * reserved[3] is 1 when the rhythm clock is locked; reserved[4..5] contain
     * the IEEE-754 bit patterns for rhythm activation and low-frequency
     * support; reserved[6] is 1 while an established clock is silently
     * coasting. Remaining words are zero. Hosts may ignore all diagnostics.
     */
    uint32_t reserved[8];
} AhHapticFrame;

#define AH_CONFIG_V1_SIZE 60u
#define AH_PROCESS_INPUT_V1_SIZE \
    ((uint32_t)(offsetof(AhProcessInput, first_sample_time_us) + sizeof(uint64_t)))
#define AH_HAPTIC_FRAME_V1_SIZE 80u

/* Fill a v1 config with production-safe defaults for the supplied format. */
MOONLIGHT_HAPTICS_API AhStatus ah_config_init(
    AhConfig* config,
    uint32_t sample_rate,
    uint32_t channel_count);

MOONLIGHT_HAPTICS_API AhStatus ah_create(
    const AhConfig* config,
    AhEngine** out_engine);

/* Sample rate and channel count are immutable and require engine recreation. */
MOONLIGHT_HAPTICS_API AhStatus ah_update_config(
    AhEngine* engine,
    const AhConfig* config);

/*
 * Worst-case output capacity for one input call. A non-zero return value must
 * be provided to ah_process_i16() when input_frame_count is non-zero.
 */
MOONLIGHT_HAPTICS_API uint32_t ah_get_max_output_frames(
    const AhEngine* engine,
    uint32_t input_frame_count);

/*
 * On AH_STATUS_BUFFER_TOO_SMALL, the input is not consumed and out_count is 0.
 * Returns AH_STATUS_OUTPUT_AVAILABLE whenever one or more IR frames are written.
 */
MOONLIGHT_HAPTICS_API AhStatus ah_process_i16(
    AhEngine* engine,
    const AhProcessInput* input,
    AhHapticFrame* out_frames,
    uint32_t out_capacity,
    uint32_t* out_count);

MOONLIGHT_HAPTICS_API void ah_reset(AhEngine* engine);
MOONLIGHT_HAPTICS_API void ah_destroy(AhEngine* engine);

MOONLIGHT_HAPTICS_API uint32_t ah_get_abi_version(void);
MOONLIGHT_HAPTICS_API const char* ah_get_version_string(void);
MOONLIGHT_HAPTICS_API const char* ah_get_parameter_set_version(void);
MOONLIGHT_HAPTICS_API const char* ah_status_string(AhStatus status);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // MOONLIGHT_HAPTICS_AUDIO_HAPTICS_H
