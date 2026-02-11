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
 * @file native_vibrator.cpp
 * @brief Native 层设备振动实现
 * 
 * 通过 dlopen 动态加载 libohvibrator.z.so，在 native 线程
 * 直接调用 OH_Vibrator_PlayVibration / OH_Vibrator_Cancel。
 * 
 * 优点：
 * - 消除 TSFN→JS 线程切换延迟（~5-15ms）
 * - 在网络回调线程直接执行，响应更快
 * 
 * 限制：
 * - C API 不支持 intensity/frequency 参数
 * - 只有 on/off 控制，无法精细映射 lowFreq/highFreq
 * - 需要 ohos.permission.VIBRATE 权限
 */

#include "native_vibrator.h"
#include <dlfcn.h>
#include <hilog/log.h>
#include <mutex>
#include <chrono>

#define LOG_TAG "NativeVibrator"

// =============================================================================
// Vibrator C API 类型定义（来自 sensors/vibrator.h）
// =============================================================================

// 振动用途枚举
typedef enum {
    VIBRATOR_USAGE_UNKNOWN = 0,
    VIBRATOR_USAGE_ALARM = 1,
    VIBRATOR_USAGE_RING = 2,
    VIBRATOR_USAGE_NOTIFICATION = 3,
    VIBRATOR_USAGE_COMMUNICATION = 4,
    VIBRATOR_USAGE_TOUCH = 5,
    VIBRATOR_USAGE_MEDIA = 6,
    VIBRATOR_USAGE_PHYSICAL_FEEDBACK = 7,
    VIBRATOR_USAGE_SIMULATE_REALITY = 8,
} Vibrator_Usage;

// 振动属性
typedef struct {
    Vibrator_Usage usage;
} Vibrator_Attribute;

// 函数指针类型
typedef int32_t (*PFN_OH_Vibrator_PlayVibration)(int32_t duration, Vibrator_Attribute attribute);
typedef int32_t (*PFN_OH_Vibrator_Cancel)(void);

// =============================================================================
// 全局状态
// =============================================================================

static PFN_OH_Vibrator_PlayVibration g_pfnPlayVibration = nullptr;
static PFN_OH_Vibrator_Cancel g_pfnCancel = nullptr;
static void* g_vibratorLib = nullptr;
static bool g_initialized = false;
static std::atomic<bool> g_enabled{false};
static std::atomic<bool> g_vibrating{false};

// 防抖：记录上次振动状态变化时间
static std::chrono::steady_clock::time_point g_lastChangeTime;
static std::atomic<uint16_t> g_lastLowFreq{0};
static std::atomic<uint16_t> g_lastHighFreq{0};

// 变化阈值（5%）
static constexpr uint16_t CHANGE_THRESHOLD = 3000;

// 振动持续时间（ms）— 每次触发固定 500ms，
// rumble 回调通常每 100-200ms 来一次，所以总是会续期
static constexpr int32_t VIBRATION_DURATION_MS = 500;

// =============================================================================
// 实现
// =============================================================================

namespace NativeVibrator {

bool Init() {
    if (g_initialized) {
        return g_pfnPlayVibration != nullptr;
    }
    g_initialized = true;

    // 动态加载 libohvibrator.z.so
    g_vibratorLib = dlopen("libohvibrator.z.so", RTLD_NOW);
    if (g_vibratorLib == nullptr) {
        OH_LOG_WARN(LOG_APP, "Failed to load libohvibrator.z.so: %{public}s", dlerror());
        return false;
    }

    g_pfnPlayVibration = (PFN_OH_Vibrator_PlayVibration)dlsym(g_vibratorLib, "OH_Vibrator_PlayVibration");
    g_pfnCancel = (PFN_OH_Vibrator_Cancel)dlsym(g_vibratorLib, "OH_Vibrator_Cancel");

    if (g_pfnPlayVibration == nullptr || g_pfnCancel == nullptr) {
        OH_LOG_WARN(LOG_APP, "Vibrator API symbols not found");
        // 不 dlclose，因为可能部分可用
        g_pfnPlayVibration = nullptr;
        g_pfnCancel = nullptr;
        return false;
    }

    OH_LOG_INFO(LOG_APP, "Native Vibrator API loaded successfully");
    g_lastChangeTime = std::chrono::steady_clock::now();
    return true;
}

bool IsAvailable() {
    return g_pfnPlayVibration != nullptr && g_pfnCancel != nullptr;
}

void SetEnabled(bool enabled) {
    g_enabled.store(enabled, std::memory_order_relaxed);
    OH_LOG_INFO(LOG_APP, "Native vibrator %{public}s", enabled ? "enabled" : "disabled");
    
    // 禁用时停止当前振动
    if (!enabled && g_vibrating.load(std::memory_order_relaxed)) {
        Cancel();
    }
}

bool IsEnabled() {
    return g_enabled.load(std::memory_order_relaxed);
}

void HandleRumble(uint16_t lowFreqMotor, uint16_t highFreqMotor) {
    if (!g_enabled.load(std::memory_order_relaxed) || !IsAvailable()) {
        return;
    }

    // 停止震动
    if (lowFreqMotor == 0 && highFreqMotor == 0) {
        if (g_vibrating.load(std::memory_order_relaxed)) {
            Cancel();
            g_lastLowFreq.store(0, std::memory_order_relaxed);
            g_lastHighFreq.store(0, std::memory_order_relaxed);
        }
        return;
    }

    // 防抖：变化太小不更新
    uint16_t lastLow = g_lastLowFreq.load(std::memory_order_relaxed);
    uint16_t lastHigh = g_lastHighFreq.load(std::memory_order_relaxed);
    
    int lowDelta = abs((int)lowFreqMotor - (int)lastLow);
    int highDelta = abs((int)highFreqMotor - (int)lastHigh);
    
    if (g_vibrating.load(std::memory_order_relaxed) && 
        lowDelta < CHANGE_THRESHOLD && highDelta < CHANGE_THRESHOLD) {
        return;  // 变化太小，跳过
    }

    g_lastLowFreq.store(lowFreqMotor, std::memory_order_relaxed);
    g_lastHighFreq.store(highFreqMotor, std::memory_order_relaxed);

    // 触发固定时长振动
    Vibrator_Attribute attr;
    attr.usage = VIBRATOR_USAGE_PHYSICAL_FEEDBACK;

    int32_t ret = g_pfnPlayVibration(VIBRATION_DURATION_MS, attr);
    if (ret == 0) {
        g_vibrating.store(true, std::memory_order_relaxed);
    } else {
        // 某些设备可能不支持此 usage，尝试 UNKNOWN
        attr.usage = VIBRATOR_USAGE_UNKNOWN;
        ret = g_pfnPlayVibration(VIBRATION_DURATION_MS, attr);
        if (ret == 0) {
            g_vibrating.store(true, std::memory_order_relaxed);
        } else {
            OH_LOG_WARN(LOG_APP, "OH_Vibrator_PlayVibration failed: %{public}d", ret);
        }
    }
}

void Cancel() {
    if (IsAvailable() && g_pfnCancel != nullptr) {
        g_pfnCancel();
    }
    g_vibrating.store(false, std::memory_order_relaxed);
}

void Cleanup() {
    Cancel();
    g_enabled.store(false, std::memory_order_relaxed);
    g_lastLowFreq.store(0, std::memory_order_relaxed);
    g_lastHighFreq.store(0, std::memory_order_relaxed);
    // 不 dlclose libohvibrator，进程退出时自动释放
}

} // namespace NativeVibrator
