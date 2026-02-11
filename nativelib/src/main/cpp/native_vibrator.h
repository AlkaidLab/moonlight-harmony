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
 * @file native_vibrator.h
 * @brief Native 层设备振动支持（C API）
 * 
 * 使用 HarmonyOS Vibrator C API 在 native 线程直接触发设备振动，
 * 避免经过 TSFN→ArkTS→vibrator 的链路延迟。
 * 
 * 局限性：C API 仅支持固定时长振动，无法控制强度/频率。
 * 因此本模块作为"快速启动"使用，精细控制仍由 ArkTS 层的
 * VibratorPatternBuilder 负责。
 * 
 * 使用 dlopen 动态加载，避免硬依赖 libohvibrator.z.so
 */

#ifndef NATIVE_VIBRATOR_H
#define NATIVE_VIBRATOR_H

#include <cstdint>
#include <atomic>

namespace NativeVibrator {

/**
 * 初始化振动器（dlopen 加载 libohvibrator.z.so）
 * @return true 成功，false 失败（库不可用）
 */
bool Init();

/**
 * 检查是否可用
 */
bool IsAvailable();

/**
 * 设置是否启用 native 层振动
 * 当 ArkTS 层的 GamepadVibrationService 不使用设备振动时应禁用
 */
void SetEnabled(bool enabled);

/**
 * 获取是否启用
 */
bool IsEnabled();

/**
 * 触发设备振动（低延迟，固定时长）
 * 
 * 由 BridgeClRumble 直接调用，在网络回调线程中执行。
 * 根据 lowFreq/highFreq 判断是否需要振动：
 * - 两者都为 0 → 停止振动
 * - 否则 → 启动固定时长振动
 * 
 * @param lowFreqMotor 低频马达 (0-65535)
 * @param highFreqMotor 高频马达 (0-65535)
 */
void HandleRumble(uint16_t lowFreqMotor, uint16_t highFreqMotor);

/**
 * 停止振动
 */
void Cancel();

/**
 * 清理资源
 */
void Cleanup();

} // namespace NativeVibrator

#endif // NATIVE_VIBRATOR_H
