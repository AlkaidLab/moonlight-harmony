/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * @file moonlight_bridge.h
 * @brief HarmonyOS NAPI 桥接层头文件
 * 
 * 定义所有 NAPI 导出函数和回调结构，类似 Android JNI 层
 */

#ifndef MOONLIGHT_BRIDGE_H
#define MOONLIGHT_BRIDGE_H

#include <napi/native_api.h>
#include <js_native_api.h>
#include <js_native_api_types.h>

#ifdef __cplusplus
extern "C" {
#endif

// =============================================================================
// 模块初始化
// =============================================================================

/**
 * 初始化 Moonlight 桥接层
 * 保存 JS 环境和回调函数引用
 */
napi_value MoonBridge_Init(napi_env env, napi_callback_info info);

// =============================================================================
// 连接管理
// =============================================================================

/**
 * 开始串流连接
 */
napi_value MoonBridge_StartConnection(napi_env env, napi_callback_info info);

/**
 * 停止连接
 */
napi_value MoonBridge_StopConnection(napi_env env, napi_callback_info info);

/**
 * 中断连接
 */
napi_value MoonBridge_InterruptConnection(napi_env env, napi_callback_info info);

/**
 * 从后台恢复解码器
 * 当应用从后台切回前台时调用
 */
napi_value MoonBridge_ResumeDecoder(napi_env env, napi_callback_info info);

// =============================================================================
// 输入处理 - 鼠标
// =============================================================================

napi_value MoonBridge_SendMouseMove(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendMousePosition(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendMouseMoveAsMousePosition(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendMouseButton(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendMouseHighResScroll(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendMouseHighResHScroll(napi_env env, napi_callback_info info);

// =============================================================================
// 输入处理 - 键盘
// =============================================================================

napi_value MoonBridge_SendKeyboardInput(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendUtf8Text(napi_env env, napi_callback_info info);

// =============================================================================
// 输入处理 - 手柄
// =============================================================================

napi_value MoonBridge_SendMultiControllerInput(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendControllerArrivalEvent(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendControllerTouchEvent(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendControllerMotionEvent(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendControllerBatteryEvent(napi_env env, napi_callback_info info);

// =============================================================================
// 输入处理 - 触摸/触控笔
// =============================================================================

napi_value MoonBridge_SendTouchEvent(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendPenEvent(napi_env env, napi_callback_info info);

// =============================================================================
// 麦克风支持
// =============================================================================

napi_value MoonBridge_GetMicPortNumber(napi_env env, napi_callback_info info);
napi_value MoonBridge_IsMicrophoneRequested(napi_env env, napi_callback_info info);
napi_value MoonBridge_SendMicrophoneOpusData(napi_env env, napi_callback_info info);
napi_value MoonBridge_IsMicrophoneEncryptionEnabled(napi_env env, napi_callback_info info);

// =============================================================================
// Opus 编码器
// =============================================================================

napi_value MoonBridge_OpusEncoderCreate(napi_env env, napi_callback_info info);
napi_value MoonBridge_OpusEncoderEncode(napi_env env, napi_callback_info info);
napi_value MoonBridge_OpusEncoderDestroy(napi_env env, napi_callback_info info);

// =============================================================================
// 状态和统计
// =============================================================================

napi_value MoonBridge_GetStageName(napi_env env, napi_callback_info info);
napi_value MoonBridge_GetPendingAudioDuration(napi_env env, napi_callback_info info);
napi_value MoonBridge_GetPendingVideoFrames(napi_env env, napi_callback_info info);
napi_value MoonBridge_GetEstimatedRttInfo(napi_env env, napi_callback_info info);
napi_value MoonBridge_GetHostFeatureFlags(napi_env env, napi_callback_info info);
napi_value MoonBridge_GetLaunchUrlQueryParameters(napi_env env, napi_callback_info info);

// =============================================================================
// 工具函数
// =============================================================================

napi_value MoonBridge_TestClientConnectivity(napi_env env, napi_callback_info info);
napi_value MoonBridge_GetPortFlagsFromStage(napi_env env, napi_callback_info info);
napi_value MoonBridge_GetPortFlagsFromTerminationErrorCode(napi_env env, napi_callback_info info);
napi_value MoonBridge_StringifyPortFlags(napi_env env, napi_callback_info info);
napi_value MoonBridge_FindExternalAddressIP4(napi_env env, napi_callback_info info);
napi_value MoonBridge_GuessControllerType(napi_env env, napi_callback_info info);
napi_value MoonBridge_GuessControllerHasPaddles(napi_env env, napi_callback_info info);
napi_value MoonBridge_GuessControllerHasShareButton(napi_env env, napi_callback_info info);

// =============================================================================
// 视频 Surface 管理
// =============================================================================

/**
 * 设置视频渲染 Surface
 * @param surfaceId XComponent 的 surface ID
 * @return boolean 是否成功
 */
napi_value MoonBridge_SetVideoSurface(napi_env env, napi_callback_info info);

/**
 * 释放视频 Surface
 */
napi_value MoonBridge_ReleaseVideoSurface(napi_env env, napi_callback_info info);

/**
 * 获取视频解码统计信息
 * @return { framesDecoded, framesDropped, avgDecodeTimeMs }
 */
napi_value MoonBridge_GetVideoStats(napi_env env, napi_callback_info info);

/**
 * 获取解码器能力信息
 * @return { supportsH264, supportsHEVC, supportsAV1, maxWidth, maxHeight, maxFps }
 */
napi_value MoonBridge_GetDecoderCapabilities(napi_env env, napi_callback_info info);

/**
 * 设置解码器缓冲区数量
 * @param count 缓冲区数量 (2-8，默认4)
 */
napi_value MoonBridge_SetDecoderBufferCount(napi_env env, napi_callback_info info);

/**
 * 设置解码器同步模式
 * 同步模式使用主动轮询代替回调，可减少约 1-3ms 延迟
 * 需要 API 20+
 * @param syncMode boolean - true 启用同步模式（低延迟），false 使用异步模式（默认）
 */
napi_value MoonBridge_SetDecoderSyncMode(napi_env env, napi_callback_info info);

/**
 * 获取解码器是否处于同步模式
 * @return boolean
 */
napi_value MoonBridge_IsDecoderSyncMode(napi_env env, napi_callback_info info);

/**
 * 设置 VRR (Variable Refresh Rate) 可变刷新率模式
 * 启用后解码器输出将适配可变刷新率显示，根据视频内容动态调整屏幕刷新率
 * 
 * 注意：
 * 1. 只支持硬件解码后直接送显的场景
 * 2. 当刷新率小于视频帧率时，会丢弃部分视频帧以节省功耗
 * 3. 游戏串流场景下可能不适合（丢帧会影响体验）
 * 4. 需要 API 15+ (HarmonyOS) 支持
 * 
 * @param enabled boolean - true 启用 VRR，false 禁用（默认）
 */
napi_value MoonBridge_SetVrrEnabled(napi_env env, napi_callback_info info);

/**
 * 设置是否启用 VSync 渲染模式
 * 启用后使用 RenderOutputBufferAtTime 精确控制帧呈现时间，可减少画面撕裂
 * 关闭时使用 RenderOutputBuffer 立即渲染，最低延迟
 * @param enabled boolean
 */
napi_value MoonBridge_SetVsyncEnabled(napi_env env, napi_callback_info info);

/**
 * 获取 VSync 渲染模式是否启用
 * @return boolean
 */
napi_value MoonBridge_IsVsyncEnabled(napi_env env, napi_callback_info info);

// =============================================================================
// 音频设置
// =============================================================================

/**
 * 设置是否启用空间音频
 * @param enabled boolean
 */
napi_value MoonBridge_SetSpatialAudioEnabled(napi_env env, napi_callback_info info);

/**
 * 获取空间音频是否启用
 * @return boolean
 */
napi_value MoonBridge_IsSpatialAudioEnabled(napi_env env, napi_callback_info info);

/**
 * 设置音量
 * @param volume 音量 (0.0 - 1.0)
 */
napi_value MoonBridge_SetAudioVolume(napi_env env, napi_callback_info info);

// =============================================================================
// 性能模式
// =============================================================================

/**
 * 查询性能模式是否启用（供 C++ 内部使用）
 * @return boolean
 */
bool MoonBridge_IsPerformanceModeEnabled();

/**
 * 设置是否启用性能模式
 * 性能模式会优化线程优先级和系统资源调度
 * @param enabled boolean
 */
napi_value MoonBridge_SetPerformanceModeEnabled(napi_env env, napi_callback_info info);

/**
 * 获取性能模式是否启用
 * @return boolean
 */
napi_value MoonBridge_GetPerformanceModeEnabled(napi_env env, napi_callback_info info);

// =============================================================================
// 常量定义
// =============================================================================

// 鼠标按钮动作
#define BUTTON_ACTION_PRESS 0x07
#define BUTTON_ACTION_RELEASE 0x08

// 鼠标按钮
#define BUTTON_LEFT 0x01
#define BUTTON_MIDDLE 0x02
#define BUTTON_RIGHT 0x03
#define BUTTON_X1 0x04
#define BUTTON_X2 0x05

// 键盘动作
#define KEY_ACTION_DOWN 0x03
#define KEY_ACTION_UP 0x04

// 修饰键
#define MODIFIER_SHIFT 0x01
#define MODIFIER_CTRL 0x02
#define MODIFIER_ALT 0x04
#define MODIFIER_META 0x08

// 触摸事件类型
#define LI_TOUCH_EVENT_HOVER 0x00
#define LI_TOUCH_EVENT_DOWN 0x01
#define LI_TOUCH_EVENT_UP 0x02
#define LI_TOUCH_EVENT_MOVE 0x03
#define LI_TOUCH_EVENT_CANCEL 0x04
#define LI_TOUCH_EVENT_BUTTON_ONLY 0x05
#define LI_TOUCH_EVENT_HOVER_LEAVE 0x06
#define LI_TOUCH_EVENT_CANCEL_ALL 0x07

// 手柄按钮
#define A_FLAG 0x1000
#define B_FLAG 0x2000
#define X_FLAG 0x4000
#define Y_FLAG 0x8000
#define UP_FLAG 0x0001
#define DOWN_FLAG 0x0002
#define LEFT_FLAG 0x0004
#define RIGHT_FLAG 0x0008
#define LB_FLAG 0x0100
#define RB_FLAG 0x0200
#define PLAY_FLAG 0x0010
#define BACK_FLAG 0x0020
#define LS_CLK_FLAG 0x0040
#define RS_CLK_FLAG 0x0080
#define SPECIAL_FLAG 0x0400
#define PADDLE1_FLAG 0x010000
#define PADDLE2_FLAG 0x020000
#define PADDLE3_FLAG 0x040000
#define PADDLE4_FLAG 0x080000
#define TOUCHPAD_FLAG 0x100000
#define MISC_FLAG 0x200000

// 手柄类型
#define LI_CTYPE_UNKNOWN 0x00
#define LI_CTYPE_XBOX 0x01
#define LI_CTYPE_PS 0x02
#define LI_CTYPE_NINTENDO 0x03

// 视频格式 - 这些在 Limelight.h 中也定义了，但值相同所以保留
// 如果出现警告，可以考虑在 moonlight_bridge.cpp 中直接使用 Limelight.h 的定义
#ifndef VIDEO_FORMAT_H264
#define VIDEO_FORMAT_H264 0x0001
#define VIDEO_FORMAT_H265 0x0100
#define VIDEO_FORMAT_H265_MAIN10 0x0200
#define VIDEO_FORMAT_AV1_MAIN8 0x1000
#define VIDEO_FORMAT_AV1_MAIN10 0x2000
#endif

// 音频配置、连接阶段、视频能力等由 Limelight.h 定义
// 在使用这些常量的 .cpp 文件中需要包含 Limelight.h

// 连接状态（Limelight.h 中没有定义）
#define CONN_STATUS_OKAY 0
#define CONN_STATUS_POOR 1

// Buffer 类型（与 Limelight.h 中 DECODE_UNIT 相关的常量不同）
#define BUFFER_TYPE_PICDATA 0x00
#define BUFFER_TYPE_SPS 0x01
#define BUFFER_TYPE_PPS 0x02
#define BUFFER_TYPE_VPS 0x03

// 帧类型
#define FRAME_TYPE_PFRAME 0x00
#define FRAME_TYPE_IDR 0x01

// 解码器返回值
#define DR_OK 0
#define DR_NEED_IDR -1

#ifdef __cplusplus
}
#endif

#endif // MOONLIGHT_BRIDGE_H
