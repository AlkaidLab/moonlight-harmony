# Resolve the standalone Apache-2.0 audio-haptics SDK for host-side tools and
# HarmonyOS integration. CI should set AUDIO_HAPTICS_SDK_DIR to an immutable
# checkout; local sibling checkout is only a developer convenience.

set(AUDIO_HAPTICS_SDK_DIR "" CACHE PATH
    "Path to the standalone moonlight-audio-haptics checkout")

function(resolve_moonlight_audio_haptics output_var repository_root)
    set(_sdk_path "${AUDIO_HAPTICS_SDK_DIR}")
    if(_sdk_path STREQUAL "" AND DEFINED ENV{AUDIO_HAPTICS_SDK_DIR})
        set(_sdk_path "$ENV{AUDIO_HAPTICS_SDK_DIR}")
    endif()
    if(_sdk_path STREQUAL "")
        set(_sdk_path "${repository_root}/../moonlight-audio-haptics")
    endif()

    get_filename_component(_sdk_path "${_sdk_path}" ABSOLUTE)
    if(NOT EXISTS "${_sdk_path}/CMakeLists.txt")
        message(FATAL_ERROR
            "moonlight-audio-haptics not found at ${_sdk_path}. "
            "Clone https://github.com/AlkaidLab/moonlight-audio-haptics and "
            "set AUDIO_HAPTICS_SDK_DIR to its root.")
    endif()

    set(${output_var} "${_sdk_path}" PARENT_SCOPE)
endfunction()
