cmake_minimum_required(VERSION 3.16)
project(moonlight_nativelib)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

# HarmonyOS 平台定义
add_definitions(-D__OHOS__)
# ENet socket 选项 - 完整启用所有功能
add_definitions(-DHAS_SOCKLEN_T=1)
add_definitions(-DHAS_INET_PTON=1)
add_definitions(-DHAS_INET_NTOP=1)
add_definitions(-DHAS_FCNTL=1)
add_definitions(-DHAS_IOCTL=1)
add_definitions(-DHAS_POLL=1)
add_definitions(-DHAS_GETADDRINFO=1)
add_definitions(-DHAS_GETNAMEINFO=1)
add_definitions(-DHAS_MSGHDR_FLAGS=1)
add_definitions(-DLC_ERRNO=errno)
add_definitions(-DLC_CODE_FUNC_NAME="__func__")
add_definitions(-DENET_FEATURE_ADDRESS_MAPPING)

# 使用 OpenSSL (ohos-openssl 预编译版本)
# 根据架构选择正确的 OpenSSL 库路径
set(OPENSSL_ROOT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/ohos-openssl/prelude/${OHOS_ARCH})
set(OPENSSL_INCLUDE_DIR ${OPENSSL_ROOT_DIR}/include)
# 使用静态库以避免打包问题
set(OPENSSL_CRYPTO_LIBRARY ${OPENSSL_ROOT_DIR}/lib/libcrypto.a)
set(OPENSSL_SSL_LIBRARY ${OPENSSL_ROOT_DIR}/lib/libssl.a)

# 使用 libopus 原生解码器（支持 PLC 丢包补偿）
# 根据架构选择正确的 libopus 库路径
set(LIBOPUS_ROOT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/libopus)
set(LIBOPUS_INCLUDE_DIR ${LIBOPUS_ROOT_DIR}/include)
set(LIBOPUS_LIBRARY ${LIBOPUS_ROOT_DIR}/${OHOS_ARCH}/libopus.a)

# 设置根路径
set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(MOONLIGHT_COMMON_PATH ${NATIVERENDER_ROOT_PATH}/moonlight-common-c)
get_filename_component(MOONLIGHT_REPOSITORY_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../.." ABSOLUTE)

include("${MOONLIGHT_REPOSITORY_ROOT}/cmake/ResolveMoonlightAudioHaptics.cmake")
resolve_moonlight_audio_haptics(
    MOONLIGHT_AUDIO_HAPTICS_SDK
    "${MOONLIGHT_REPOSITORY_ROOT}")
set(MOONLIGHT_HAPTICS_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(
    "${MOONLIGHT_AUDIO_HAPTICS_SDK}"
    "${CMAKE_CURRENT_BINARY_DIR}/moonlight-audio-haptics"
    EXCLUDE_FROM_ALL)

# 包含目录
include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
    ${OPENSSL_INCLUDE_DIR}
    ${LIBOPUS_INCLUDE_DIR}
    ${MOONLIGHT_COMMON_PATH}/src
    ${MOONLIGHT_COMMON_PATH}/enet/include
    ${MOONLIGHT_COMMON_PATH}/nanors
    ${MOONLIGHT_COMMON_PATH}/nanors/deps
    ${MOONLIGHT_COMMON_PATH}/nanors/deps/obl
    ${CMAKE_CURRENT_BINARY_DIR}/generated
)

# ---- GLSL 着色器 → C++ 字符串常量头文件 ----
set(SHADER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/shaders)
set(SHADER_HEADER ${CMAKE_CURRENT_BINARY_DIR}/generated/shader_strings.h)
file(GLOB SHADER_SOURCES ${SHADER_DIR}/*.vert ${SHADER_DIR}/*.frag)
find_package(Python3 COMPONENTS Interpreter QUIET)
if(NOT Python3_FOUND)
    find_program(Python3_EXECUTABLE NAMES python3 python)
endif()
add_custom_command(
    OUTPUT ${SHADER_HEADER}
    COMMAND ${Python3_EXECUTABLE} ${SHADER_DIR}/embed_shaders.py ${SHADER_DIR} ${SHADER_HEADER}
    DEPENDS ${SHADER_SOURCES} ${SHADER_DIR}/embed_shaders.py
    COMMENT "Embedding GLSL shaders into shader_strings.h"
)
add_custom_target(generate_shader_header DEPENDS ${SHADER_HEADER})

# 主要源文件 - NAPI 桥接层
set(SOURCE_FILES
    napi_init.cpp
    moonlight_bridge.cpp
    callbacks.cpp
    audio_haptics_engine.cpp
    opus_libopus.cpp
    opus_encoder.cpp
    hdr_vivid_metadata_scanner.cpp
    video_decoder.cpp
    audio_renderer.cpp
    mic_capturer.cpp
    gamepad_napi.cpp
    game_controller_native.cpp
    input_interceptor.cpp
    mouse_interceptor.cpp
    usb_helper.cpp
    usb_ddk_poller.cpp
    native_render.cpp
    presentation_scheduler.cpp
    two_step_presentation_scheduler.cpp
    rolling_frame_rate.cpp
    gl_post_processor.cpp
    sdl_gamecontrollerdb.cpp
)

# moonlight-common-c 源文件
set(MOONLIGHT_COMMON_SOURCES
    ${MOONLIGHT_COMMON_PATH}/src/Connection.c
    ${MOONLIGHT_COMMON_PATH}/src/ControlStream.c
    ${MOONLIGHT_COMMON_PATH}/src/CursorStream.c
    ${MOONLIGHT_COMMON_PATH}/src/VideoStream.c
    ${MOONLIGHT_COMMON_PATH}/src/AudioStream.c
    ${MOONLIGHT_COMMON_PATH}/src/InputStream.c
    ${MOONLIGHT_COMMON_PATH}/src/RtspConnection.c
    ${MOONLIGHT_COMMON_PATH}/src/RtspParser.c
    ${MOONLIGHT_COMMON_PATH}/src/SdpGenerator.c
    ${MOONLIGHT_COMMON_PATH}/src/RtpVideoQueue.c
    ${MOONLIGHT_COMMON_PATH}/src/RtpAudioQueue.c
    ${MOONLIGHT_COMMON_PATH}/src/VideoDepacketizer.c
    ${MOONLIGHT_COMMON_PATH}/src/Misc.c
    ${MOONLIGHT_COMMON_PATH}/src/LinkedBlockingQueue.c
    ${MOONLIGHT_COMMON_PATH}/src/Platform.c
    ${MOONLIGHT_COMMON_PATH}/src/PlatformSockets.c
    ${MOONLIGHT_COMMON_PATH}/src/PlatformCrypto.c
    ${MOONLIGHT_COMMON_PATH}/src/ByteBuffer.c
    ${MOONLIGHT_COMMON_PATH}/src/SimpleStun.c
    ${MOONLIGHT_COMMON_PATH}/src/ConnectionTester.c
    ${MOONLIGHT_COMMON_PATH}/src/MicrophoneStream.c
    ${MOONLIGHT_COMMON_PATH}/src/FakeCallbacks.c
    ${MOONLIGHT_COMMON_PATH}/nanors/rs.c
    ${MOONLIGHT_COMMON_PATH}/nanors/deps/obl/oblas_common.c
    ${MOONLIGHT_COMMON_PATH}/nanors/deps/obl/oblas_lite.c
)

# ENet 网络库源文件
set(ENET_SOURCES
    ${MOONLIGHT_COMMON_PATH}/enet/callbacks.c
    ${MOONLIGHT_COMMON_PATH}/enet/compress.c
    ${MOONLIGHT_COMMON_PATH}/enet/host.c
    ${MOONLIGHT_COMMON_PATH}/enet/list.c
    ${MOONLIGHT_COMMON_PATH}/enet/packet.c
    ${MOONLIGHT_COMMON_PATH}/enet/peer.c
    ${MOONLIGHT_COMMON_PATH}/enet/protocol.c
    ${MOONLIGHT_COMMON_PATH}/enet/unix.c
)



# 创建共享库
add_library(moonlight_nativelib SHARED
    ${SOURCE_FILES}
    ${MOONLIGHT_COMMON_SOURCES}
    ${ENET_SOURCES}
)
add_dependencies(moonlight_nativelib generate_shader_header)

# nanors 需要优化标志以获得最佳 Reed-Solomon 性能
# 使用 ohos_shim/assert.h 避免 OHOS assert.h 的 __assert_fail 与 Clang target
# multiversioning 冲突 (尤其是 x86_64 模拟器构建)
set_source_files_properties(
    ${MOONLIGHT_COMMON_PATH}/nanors/rs.c
    ${MOONLIGHT_COMMON_PATH}/nanors/deps/obl/oblas_common.c
    ${MOONLIGHT_COMMON_PATH}/nanors/deps/obl/oblas_lite.c
    PROPERTIES COMPILE_FLAGS "-ftree-vectorize -funroll-loops -isystem ${CMAKE_CURRENT_SOURCE_DIR}/ohos_shim")

# Game Controller Kit 可能不存在于所有设备 (如 HarmonyOS 5.0.5)
# 不链接 libohgame_controller.z.so，改为运行时 dlopen 加载
# 所有 OH_Game* 函数通过 dlsym 获取的函数指针调用

# 链接库
target_link_libraries(moonlight_nativelib PUBLIC
    moonlight::haptics
    libace_napi.z.so
    libace_ndk.z.so
    libhilog_ndk.z.so
    libnative_window.so
    libnative_vsync.so
    libnative_media_core.so
    libnative_media_codecbase.so
    libnative_media_acodec.so
    libnative_media_vdec.so
    libnative_media_avsource.so
    libohaudio.so
    libqos.so
    libohinput.so
    ${OPENSSL_CRYPTO_LIBRARY}
    ${OPENSSL_SSL_LIBRARY}
    ${LIBOPUS_LIBRARY}
)
