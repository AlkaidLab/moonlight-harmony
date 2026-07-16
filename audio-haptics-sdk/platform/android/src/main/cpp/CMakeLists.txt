# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.22.1)

project(moonlight_haptics_android LANGUAGES C CXX)

set(MOONLIGHT_HAPTICS_SDK_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../../..")
add_subdirectory(
    "${MOONLIGHT_HAPTICS_SDK_ROOT}"
    "${CMAKE_CURRENT_BINARY_DIR}/moonlight-haptics-core"
)

add_library(moonlight_haptics_android SHARED
    android_haptics_jni.cpp
)

target_include_directories(moonlight_haptics_android
    PUBLIC "${CMAKE_CURRENT_LIST_DIR}/include"
)
target_link_libraries(moonlight_haptics_android
    PRIVATE moonlight_haptics_core log
)
target_compile_features(moonlight_haptics_android PRIVATE cxx_std_17)
set_target_properties(moonlight_haptics_android PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
)
