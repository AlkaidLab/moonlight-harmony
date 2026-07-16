# SPDX-License-Identifier: GPL-3.0-or-later

cmake_minimum_required(VERSION 3.20)
project(audio_haptics_android_bench LANGUAGES C CXX)

if(NOT ANDROID)
    message(FATAL_ERROR "This benchmark must be cross-compiled with the Android NDK")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(MOONLIGHT_HAPTICS_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(
    "${REPO_ROOT}/audio-haptics-sdk"
    "${CMAKE_CURRENT_BINARY_DIR}/audio-haptics-sdk"
)

add_executable(audio_haptics_android_bench src/main.cpp)
target_link_libraries(audio_haptics_android_bench PRIVATE moonlight::haptics)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(audio_haptics_android_bench PRIVATE
        -Wall -Wextra -Wpedantic -Wconversion -Wshadow
    )
endif()
