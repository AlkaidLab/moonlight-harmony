cmake_minimum_required(VERSION 3.16)
project(moonlight_nativelib)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

# HarmonyOS 平台定义
add_definitions(-D__OHOS__)
add_definitions(-DHAS_SOCKLEN_T=1)

# 设置根路径
set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(MOONLIGHT_COMMON_PATH ${NATIVERENDER_ROOT_PATH}/moonlight-common-c)

# 包含目录
include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
    ${MOONLIGHT_COMMON_PATH}/src
    ${MOONLIGHT_COMMON_PATH}/enet/include
    ${MOONLIGHT_COMMON_PATH}/reedsolomon
)

# 主要源文件
set(SOURCE_FILES
    napi_init.cpp
    moonlight_bridge.cpp
    video_decoder.cpp
    audio_decoder.cpp
    input_handler.cpp
)

# moonlight-common-c 源文件
set(MOONLIGHT_COMMON_SOURCES
    ${MOONLIGHT_COMMON_PATH}/src/Connection.c
    ${MOONLIGHT_COMMON_PATH}/src/ControlStream.c
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

# Reed-Solomon 纠错源文件
set(RS_SOURCES
    ${MOONLIGHT_COMMON_PATH}/reedsolomon/rs.c
)

# 创建共享库
add_library(moonlight_nativelib SHARED
    ${SOURCE_FILES}
    ${MOONLIGHT_COMMON_SOURCES}
    ${ENET_SOURCES}
    ${RS_SOURCES}
)

# 链接库
target_link_libraries(moonlight_nativelib PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_window.so
    libnative_media_core.so
    libnative_media_codecbase.so
    libnative_media_avcodec.so
    libnative_media_avsource.so
    libohaudio.so
)
