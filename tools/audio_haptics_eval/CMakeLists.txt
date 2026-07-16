cmake_minimum_required(VERSION 3.20)

project(audio_haptics_eval LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(NATIVE_CPP_DIR "${REPO_ROOT}/nativelib/src/main/cpp")
set(AUBIO_SRC_DIR "${NATIVE_CPP_DIR}/aubio/src")
set(AUBIO_CONFIG_HEADER "${CMAKE_CURRENT_BINARY_DIR}/generated/config.h")

set(MOONLIGHT_HAPTICS_BUILD_TESTS OFF)
add_subdirectory(
    "${REPO_ROOT}/audio-haptics-sdk"
    "${CMAKE_CURRENT_BINARY_DIR}/audio-haptics-sdk"
)

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
configure_file(
    "${REPO_ROOT}/ci/sdk-stubs/aubio-config.h"
    "${AUBIO_CONFIG_HEADER}"
    COPYONLY
)

# This target intentionally remains in the GPL host-side evaluation tool.
# It must not be copied into the future Apache-2.0 SDK.
add_library(aubio_baseline STATIC
    ${AUBIO_SRC_DIR}/fvec.c
    ${AUBIO_SRC_DIR}/cvec.c
    ${AUBIO_SRC_DIR}/lvec.c
    ${AUBIO_SRC_DIR}/mathutils.c
    ${AUBIO_SRC_DIR}/vecutils.c
    ${AUBIO_SRC_DIR}/musicutils.c
    ${AUBIO_SRC_DIR}/spectral/ooura_fft8g.c
    ${AUBIO_SRC_DIR}/spectral/fft.c
    ${AUBIO_SRC_DIR}/spectral/phasevoc.c
    ${AUBIO_SRC_DIR}/spectral/specdesc.c
    ${AUBIO_SRC_DIR}/spectral/statistics.c
    ${AUBIO_SRC_DIR}/spectral/awhitening.c
    ${AUBIO_SRC_DIR}/temporal/filter.c
    ${AUBIO_SRC_DIR}/temporal/biquad.c
    ${AUBIO_SRC_DIR}/onset/onset.c
    ${AUBIO_SRC_DIR}/onset/peakpicker.c
    ${AUBIO_SRC_DIR}/utils/log.c
    ${AUBIO_SRC_DIR}/utils/hist.c
    ${AUBIO_SRC_DIR}/utils/scale.c
    ${AUBIO_SRC_DIR}/utils/strutils.c
)

target_include_directories(aubio_baseline PUBLIC
    "${AUBIO_SRC_DIR}"
    "${CMAKE_CURRENT_BINARY_DIR}/generated"
)
target_compile_definitions(aubio_baseline PRIVATE HAVE_CONFIG_H)

if(MSVC)
    target_compile_options(aubio_baseline PRIVATE /W3)
else()
    target_compile_options(aubio_baseline PRIVATE
        -Wall -Wextra
        -Wno-sign-compare
        -Wno-unused-parameter
        -Wno-missing-field-initializers
    )
endif()

add_executable(audio_haptics_eval
    src/main.cpp
)

target_include_directories(audio_haptics_eval PRIVATE
    "${NATIVE_CPP_DIR}"
)
target_link_libraries(audio_haptics_eval PRIVATE
    aubio_baseline
    moonlight::haptics
)

if(NOT MSVC)
    target_compile_options(audio_haptics_eval PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(UNIX AND NOT APPLE)
    target_link_libraries(audio_haptics_eval PRIVATE m)
endif()

include(CTest)
if(BUILD_TESTING)
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    set(TEST_FIXTURE_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_fixtures")
    set(TEST_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/test_output")

    add_test(
        NAME audio_haptics_generate_fixtures
        COMMAND "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/generate_fixtures.py"
                --output-dir "${TEST_FIXTURE_DIR}"
    )
    set_tests_properties(audio_haptics_generate_fixtures PROPERTIES
        FIXTURES_SETUP audio_haptics_fixtures
    )

    add_test(
        NAME audio_haptics_eval_smoke
        COMMAND audio_haptics_eval
                --input "${TEST_FIXTURE_DIR}/impulse_train_mono.wav"
                --labels "${TEST_FIXTURE_DIR}/impulse_train_mono.labels.csv"
                --backend all
                --events-out "${TEST_OUTPUT_DIR}/events.csv"
                --summary-out "${TEST_OUTPUT_DIR}/summary.json"
                --runs 1
                --warmup-runs 0
    )
    set_tests_properties(audio_haptics_eval_smoke PROPERTIES
        FIXTURES_REQUIRED audio_haptics_fixtures
    )

    add_test(
        NAME audio_haptics_dataset_validate
        COMMAND "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/validate_dataset.py"
                --manifest "${TEST_FIXTURE_DIR}/manifest.csv"
    )
    set_tests_properties(audio_haptics_dataset_validate PROPERTIES
        FIXTURES_REQUIRED audio_haptics_fixtures
    )

    add_test(
        NAME audio_haptics_real_world_dataset_gate
        COMMAND "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/validate_dataset.py"
                --manifest "${TEST_FIXTURE_DIR}/manifest.csv"
                --require-real-world
    )
    set_tests_properties(audio_haptics_real_world_dataset_gate PROPERTIES
        FIXTURES_REQUIRED audio_haptics_fixtures
        WILL_FAIL TRUE
    )

    add_test(
        NAME audio_haptics_shadow_pipeline
        COMMAND "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/run_baseline.py"
                --build-dir "${CMAKE_CURRENT_BINARY_DIR}"
                --fixtures-dir "${TEST_FIXTURE_DIR}"
                --output-dir "${TEST_OUTPUT_DIR}/shadow"
                --skip-build
                --skip-generate
                --runs 1
                --warmup-runs 0
    )
    set_tests_properties(audio_haptics_shadow_pipeline PROPERTIES
        FIXTURES_REQUIRED audio_haptics_fixtures
    )

    add_executable(audio_haptics_device_shadow_test
        tests/audio_haptics_shadow_test.cpp
        "${NATIVE_CPP_DIR}/audio_haptics_shadow.cpp"
    )
    target_include_directories(audio_haptics_device_shadow_test PRIVATE
        "${NATIVE_CPP_DIR}"
    )
    target_compile_definitions(audio_haptics_device_shadow_test PRIVATE
        MOONLIGHT_AUDIO_HAPTICS_SHADOW=1
    )
    target_link_libraries(audio_haptics_device_shadow_test PRIVATE
        aubio_baseline
        moonlight::haptics
    )
    add_test(NAME audio_haptics_device_shadow
        COMMAND audio_haptics_device_shadow_test)

    add_executable(audio_haptics_shadow_disabled_test
        tests/audio_haptics_shadow_disabled_test.cpp
        "${NATIVE_CPP_DIR}/audio_haptics_shadow.cpp"
    )
    target_include_directories(audio_haptics_shadow_disabled_test PRIVATE
        "${NATIVE_CPP_DIR}"
    )
    target_compile_definitions(audio_haptics_shadow_disabled_test PRIVATE
        MOONLIGHT_AUDIO_HAPTICS_SHADOW=0
    )
    target_link_libraries(audio_haptics_shadow_disabled_test PRIVATE
        aubio_baseline
        moonlight::haptics
    )
    add_test(NAME audio_haptics_shadow_compile_off
        COMMAND audio_haptics_shadow_disabled_test)

    add_test(
        NAME audio_haptics_device_shadow_tools
        COMMAND "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_device_shadow_tools.py"
    )
endif()
