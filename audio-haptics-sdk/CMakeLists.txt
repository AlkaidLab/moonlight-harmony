# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.16)

project(moonlight_haptics
    VERSION 0.5.14
    DESCRIPTION "Portable real-time audio-to-haptics core"
    LANGUAGES C CXX
)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(CMAKE_SOURCE_DIR STREQUAL PROJECT_SOURCE_DIR)
    set(_MOONLIGHT_HAPTICS_TESTS_DEFAULT ON)
else()
    set(_MOONLIGHT_HAPTICS_TESTS_DEFAULT OFF)
endif()
option(MOONLIGHT_HAPTICS_BUILD_TESTS
    "Build moonlight-haptics API and ABI tests"
    ${_MOONLIGHT_HAPTICS_TESTS_DEFAULT}
)

add_library(moonlight_haptics_core STATIC
    src/core/audio_haptics_engine.cpp
    src/core/causal_onset_detector.cpp
    src/core/causal_rhythm_clock.cpp
    src/core/feature_extractor.cpp
    src/core/game_scene_author.cpp
    src/core/music_scene_author.cpp
    src/core/rhythm_activation_extractor.cpp
    src/dsp/aosp_haptic_envelope.cpp
    src/dsp/real_fft.cpp
)
add_library(moonlight::haptics ALIAS moonlight_haptics_core)

target_include_directories(moonlight_haptics_core
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_compile_definitions(moonlight_haptics_core
    PUBLIC MOONLIGHT_HAPTICS_STATIC=1
)
set_target_properties(moonlight_haptics_core PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
    POSITION_INDEPENDENT_CODE ON
)

if(MSVC)
    target_compile_options(moonlight_haptics_core PRIVATE /W4 /permissive-)
else()
    target_compile_options(moonlight_haptics_core PRIVATE
        -Wall -Wextra -Wpedantic -Wconversion -Wshadow
    )
endif()

include(GNUInstallDirs)
install(TARGETS moonlight_haptics_core
    EXPORT moonlight_haptics_targets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(FILES LICENSE THIRD_PARTY_NOTICES.md ALGORITHM_PROVENANCE.md
    DESTINATION ${CMAKE_INSTALL_DATADIR}/moonlight-haptics)
install(EXPORT moonlight_haptics_targets
    FILE moonlight_haptics_targets.cmake
    NAMESPACE moonlight::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/moonlight-haptics
)

if(MOONLIGHT_HAPTICS_BUILD_TESTS)
    include(CTest)
    find_package(Python3 COMPONENTS Interpreter REQUIRED)

    function(moonlight_haptics_enable_test_assertions target)
        # C/C++ assert() must remain active in Release test binaries. Otherwise
        # CTest can report false passes after a version or DSP regression.
        if(MSVC)
            target_compile_options(${target} PRIVATE /UNDEBUG)
        else()
            target_compile_options(${target} PRIVATE -UNDEBUG)
        endif()
    endfunction()

    add_executable(moonlight_haptics_c_api_test tests/c_api_test.c)
    target_link_libraries(moonlight_haptics_c_api_test PRIVATE moonlight_haptics_core)
    set_target_properties(moonlight_haptics_c_api_test PROPERTIES LINKER_LANGUAGE CXX)
    moonlight_haptics_enable_test_assertions(moonlight_haptics_c_api_test)
    add_test(NAME moonlight_haptics_c_api COMMAND moonlight_haptics_c_api_test)

    add_executable(moonlight_haptics_abi_test tests/abi_test.cpp)
    target_link_libraries(moonlight_haptics_abi_test PRIVATE moonlight_haptics_core)
    moonlight_haptics_enable_test_assertions(moonlight_haptics_abi_test)
    add_test(NAME moonlight_haptics_abi COMMAND moonlight_haptics_abi_test)

    add_executable(moonlight_haptics_dsp_integration_test
        tests/dsp_integration_test.cpp)
    target_include_directories(moonlight_haptics_dsp_integration_test
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
    target_link_libraries(moonlight_haptics_dsp_integration_test
        PRIVATE moonlight_haptics_core)
    moonlight_haptics_enable_test_assertions(
        moonlight_haptics_dsp_integration_test)
    add_test(NAME moonlight_haptics_dsp_integration
        COMMAND moonlight_haptics_dsp_integration_test)

    add_executable(moonlight_haptics_rhythm_clock_test
        tests/rhythm_clock_test.cpp)
    target_include_directories(moonlight_haptics_rhythm_clock_test
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
    target_link_libraries(moonlight_haptics_rhythm_clock_test
        PRIVATE moonlight_haptics_core)
    moonlight_haptics_enable_test_assertions(
        moonlight_haptics_rhythm_clock_test)
    add_test(NAME moonlight_haptics_rhythm_clock
        COMMAND moonlight_haptics_rhythm_clock_test)

    add_executable(moonlight_haptics_music_scene_author_test
        tests/music_scene_author_test.cpp)
    target_include_directories(moonlight_haptics_music_scene_author_test
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
    target_link_libraries(moonlight_haptics_music_scene_author_test
        PRIVATE moonlight_haptics_core)
    moonlight_haptics_enable_test_assertions(
        moonlight_haptics_music_scene_author_test)
    add_test(NAME moonlight_haptics_music_scene_author
        COMMAND moonlight_haptics_music_scene_author_test)

    add_executable(moonlight_haptics_game_scene_author_test
        tests/game_scene_author_test.cpp)
    target_include_directories(moonlight_haptics_game_scene_author_test
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
    target_link_libraries(moonlight_haptics_game_scene_author_test
        PRIVATE moonlight_haptics_core)
    moonlight_haptics_enable_test_assertions(
        moonlight_haptics_game_scene_author_test)
    add_test(NAME moonlight_haptics_game_scene_author
        COMMAND moonlight_haptics_game_scene_author_test)

    add_executable(moonlight_haptics_percussive_feature_test
        tests/percussive_feature_test.cpp)
    target_include_directories(moonlight_haptics_percussive_feature_test
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
    target_link_libraries(moonlight_haptics_percussive_feature_test
        PRIVATE moonlight_haptics_core)
    moonlight_haptics_enable_test_assertions(
        moonlight_haptics_percussive_feature_test)
    add_test(NAME moonlight_haptics_percussive_feature
        COMMAND moonlight_haptics_percussive_feature_test)

    add_test(
        NAME moonlight_haptics_license_check
        COMMAND "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tools/check_licenses.py"
                "${CMAKE_CURRENT_SOURCE_DIR}"
    )
endif()
