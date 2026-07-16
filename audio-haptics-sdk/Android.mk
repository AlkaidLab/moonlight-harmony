# SPDX-License-Identifier: Apache-2.0

LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := moonlight_haptics_core
LOCAL_SRC_FILES := src/core/audio_haptics_engine.cpp \
                   src/core/causal_onset_detector.cpp \
                   src/core/causal_rhythm_clock.cpp \
                   src/core/feature_extractor.cpp \
                   src/core/music_scene_author.cpp \
                   src/core/rhythm_activation_extractor.cpp \
                   src/dsp/aosp_haptic_envelope.cpp \
                   src/dsp/real_fft.cpp
LOCAL_C_INCLUDES := $(LOCAL_PATH)/include \
                    $(LOCAL_PATH)/src
LOCAL_EXPORT_C_INCLUDES := $(LOCAL_PATH)/include
LOCAL_CPPFLAGS := -std=c++17 -O2 -DNDEBUG \
                  -Wall -Wextra -Wpedantic -Wconversion -Wshadow
LOCAL_CPP_FEATURES := exceptions
LOCAL_EXPORT_CFLAGS := -DMOONLIGHT_HAPTICS_STATIC=1
LOCAL_CFLAGS := -DMOONLIGHT_HAPTICS_STATIC=1
LOCAL_BRANCH_PROTECTION := standard
include $(BUILD_STATIC_LIBRARY)
