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
 * @file video_decoder.cpp
 * @brief HarmonyOS AVCodec 视频解码器实现
 */

#include "video_decoder.h"
#include "native_render.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <time.h>
#include <dlfcn.h>
#include <sched.h>
#include <unistd.h>
#include <fstream>
#include <vector>
#include <qos/qos.h>

// moonlight-common-c API (用于 IDR 帧请求)
extern "C" {
    void LiRequestIdrFrame(void);
}

#define LOG_TAG "VideoDecoder"

// 是否启用异步渲染（通过 NativeRender）
// 启用后可利用 SetExpectedFrameRateRange 优化高帧率显示
static bool g_useAsyncRender = true;

// =============================================================================
// 大核绑定 + QoS 线程优化
// 检测 ARM big.LITTLE 架构中的高频核心（大核），将解码线程绑定以获取最大性能
// 结合 QoS_USER_INTERACTIVE（最高等级）确保调度优先级
// =============================================================================

// 缓存大核 CPU ID（运行期间不变，只检测一次）
static std::vector<int> g_bigCoreIds;
static bool g_bigCoreDetected = false;

/**
 * 检测大核 CPU ID
 * 读取 /sys/devices/system/cpu/cpuN/cpufreq/cpuinfo_max_freq
 * 将最高频率 80% 以上的核心视为大核
 */
static void DetectBigCores() {
    if (g_bigCoreDetected) return;
    g_bigCoreDetected = true;
    
    int numCpus = sysconf(_SC_NPROCESSORS_CONF);
    if (numCpus <= 0) {
        OH_LOG_WARN(LOG_APP, "Failed to get CPU count");
        return;
    }
    
    std::vector<long> freqs(numCpus, 0);
    long maxFreq = 0;
    
    for (int i = 0; i < numCpus; i++) {
        char path[128];
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
        std::ifstream f(path);
        long freq = 0;
        if (f >> freq) {
            freqs[i] = freq;
            maxFreq = std::max(maxFreq, freq);
        }
    }
    
    if (maxFreq <= 0) {
        OH_LOG_WARN(LOG_APP, "Failed to read CPU frequencies, big core detection skipped");
        return;
    }
    
    // 频率 >= 最高值 80% 的视为大核
    long threshold = static_cast<long>(maxFreq * 0.8);
    for (int i = 0; i < numCpus; i++) {
        if (freqs[i] >= threshold) {
            g_bigCoreIds.push_back(i);
        }
    }
    
    // 日志输出检测结果
    std::string coreList;
    for (size_t i = 0; i < g_bigCoreIds.size(); i++) {
        if (i > 0) coreList += ",";
        coreList += std::to_string(g_bigCoreIds[i]);
    }
    OH_LOG_INFO(LOG_APP, "Big core detection: %{public}d CPUs, maxFreq=%{public}ld, "
                "big cores=[%{public}s] (%{public}zu cores)",
                numCpus, maxFreq, coreList.c_str(), g_bigCoreIds.size());
}

/**
 * 配置当前线程为高性能解码线程
 * 1. 设置 QoS 为 USER_INTERACTIVE（最高等级）或 DEADLINE_REQUEST（次高）
 * 2. 尝试通过 sched_setaffinity 绑定到大核（失败则静默忽略）
 * 
 * 使用 thread_local 确保每个线程只执行一次
 */
static void SetupDecodeThreadPriority() {
    static thread_local bool setupDone = false;
    if (setupDone) return;
    setupDone = true;
    
    // 1. 设置 QoS 等级（优先 USER_INTERACTIVE，最高等级）
    int qosRet = OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);
    if (qosRet == 0) {
        OH_LOG_INFO(LOG_APP, "Decode thread QoS: USER_INTERACTIVE (highest)");
    } else {
        qosRet = OH_QoS_SetThreadQoS(QOS_DEADLINE_REQUEST);
        if (qosRet == 0) {
            OH_LOG_INFO(LOG_APP, "Decode thread QoS: DEADLINE_REQUEST (fallback)");
        } else {
            qosRet = OH_QoS_SetThreadQoS(QOS_USER_INITIATED);
            if (qosRet == 0) {
                OH_LOG_INFO(LOG_APP, "Decode thread QoS: USER_INITIATED (fallback2)");
            } else {
                OH_LOG_WARN(LOG_APP, "Failed to set decode thread QoS");
            }
        }
    }
    
    // 2. 检测大核并绑定
    DetectBigCores();
    
    if (!g_bigCoreIds.empty()) {
        cpu_set_t cpuset;
        CPU_ZERO(&cpuset);
        for (int cpu : g_bigCoreIds) {
            CPU_SET(cpu, &cpuset);
        }
        
        int ret = sched_setaffinity(0, sizeof(cpuset), &cpuset);
        if (ret == 0) {
            OH_LOG_INFO(LOG_APP, "Decode thread bound to %{public}zu big cores", g_bigCoreIds.size());
        } else {
            // HarmonyOS 沙箱可能限制 sched_setaffinity，失败是可接受的
            // QoS_USER_INTERACTIVE 已经暗示调度器优先使用大核
            OH_LOG_WARN(LOG_APP, "sched_setaffinity failed (errno=%{public}d), relying on QoS scheduling",
                        errno);
        }
    }
}

// =============================================================================
// 同步模式 API 动态加载（API 14+，HarmonyOS 5.0.5 等低版本不存在这些符号）
// 使用 dlsym 在运行时按需加载，避免硬依赖导致整个 native 模块加载失败
// =============================================================================
typedef OH_AVErrCode (*PFN_OH_VideoDecoder_QueryInputBuffer)(OH_AVCodec*, uint32_t*, int64_t);
typedef OH_AVErrCode (*PFN_OH_VideoDecoder_QueryOutputBuffer)(OH_AVCodec*, uint32_t*, int64_t);
typedef OH_AVErrCode (*PFN_OH_VideoDecoder_RenderOutputBufferAtTime)(OH_AVCodec*, uint32_t, int64_t);
typedef OH_AVBuffer* (*PFN_OH_VideoDecoder_GetInputBuffer)(OH_AVCodec*, uint32_t);
typedef OH_AVBuffer* (*PFN_OH_VideoDecoder_GetOutputBuffer)(OH_AVCodec*, uint32_t);

static PFN_OH_VideoDecoder_QueryInputBuffer  pfn_QueryInputBuffer = nullptr;
static PFN_OH_VideoDecoder_QueryOutputBuffer pfn_QueryOutputBuffer = nullptr;
static PFN_OH_VideoDecoder_RenderOutputBufferAtTime pfn_RenderOutputBufferAtTime = nullptr;
static PFN_OH_VideoDecoder_GetInputBuffer pfn_GetInputBuffer = nullptr;
static PFN_OH_VideoDecoder_GetOutputBuffer pfn_GetOutputBuffer = nullptr;
static bool g_syncApiLoaded = false;
static bool g_syncApiAvailable = false;

// =============================================================================
// AVFormat 键名动态加载（extern const char* 全局变量）
// OH_MD_KEY_ENABLE_SYNC_MODE (API 20+), OH_MD_KEY_VIDEO_DECODER_OUTPUT_ENABLE_VRR (API 15+)
// 这些是 extern const char* 变量，直接引用会在 .so 加载时触发符号解析失败
// 必须通过 dlsym 在运行时查找，避免链接器硬依赖
// =============================================================================
static const char* key_enable_sync_mode = nullptr;
static const char* key_vrr_enable = nullptr;
static bool g_mediaKeysLoaded = false;

/**
 * 尝试在运行时加载同步模式 API 函数
 * 这些函数在 API 14+ 才可用，低版本设备上 dlsym 返回 nullptr
 */
static bool TryLoadSyncModeApis() {
    if (g_syncApiLoaded) return g_syncApiAvailable;
    g_syncApiLoaded = true;
    
    // 先尝试 RTLD_DEFAULT（全局符号搜索）
    pfn_QueryInputBuffer = (PFN_OH_VideoDecoder_QueryInputBuffer)
        dlsym(RTLD_DEFAULT, "OH_VideoDecoder_QueryInputBuffer");
    pfn_QueryOutputBuffer = (PFN_OH_VideoDecoder_QueryOutputBuffer)
        dlsym(RTLD_DEFAULT, "OH_VideoDecoder_QueryOutputBuffer");
    pfn_RenderOutputBufferAtTime = (PFN_OH_VideoDecoder_RenderOutputBufferAtTime)
        dlsym(RTLD_DEFAULT, "OH_VideoDecoder_RenderOutputBufferAtTime");
    pfn_GetInputBuffer = (PFN_OH_VideoDecoder_GetInputBuffer)
        dlsym(RTLD_DEFAULT, "OH_VideoDecoder_GetInputBuffer");
    pfn_GetOutputBuffer = (PFN_OH_VideoDecoder_GetOutputBuffer)
        dlsym(RTLD_DEFAULT, "OH_VideoDecoder_GetOutputBuffer");
    
    // 如果 RTLD_DEFAULT 失败，尝试显式 dlopen libnative_media_vdec.so
    // 某些设备上 RTLD_DEFAULT 可能无法搜索到该库的符号
    if (pfn_QueryInputBuffer == nullptr || pfn_QueryOutputBuffer == nullptr) {
        OH_LOG_INFO(LOG_APP, "RTLD_DEFAULT failed, trying explicit dlopen libnative_media_vdec.so...");
        void* vdecHandle = dlopen("libnative_media_vdec.so", RTLD_NOW);
        if (vdecHandle != nullptr) {
            if (pfn_QueryInputBuffer == nullptr)
                pfn_QueryInputBuffer = (PFN_OH_VideoDecoder_QueryInputBuffer)
                    dlsym(vdecHandle, "OH_VideoDecoder_QueryInputBuffer");
            if (pfn_QueryOutputBuffer == nullptr)
                pfn_QueryOutputBuffer = (PFN_OH_VideoDecoder_QueryOutputBuffer)
                    dlsym(vdecHandle, "OH_VideoDecoder_QueryOutputBuffer");
            if (pfn_RenderOutputBufferAtTime == nullptr)
                pfn_RenderOutputBufferAtTime = (PFN_OH_VideoDecoder_RenderOutputBufferAtTime)
                    dlsym(vdecHandle, "OH_VideoDecoder_RenderOutputBufferAtTime");
            if (pfn_GetInputBuffer == nullptr)
                pfn_GetInputBuffer = (PFN_OH_VideoDecoder_GetInputBuffer)
                    dlsym(vdecHandle, "OH_VideoDecoder_GetInputBuffer");
            if (pfn_GetOutputBuffer == nullptr)
                pfn_GetOutputBuffer = (PFN_OH_VideoDecoder_GetOutputBuffer)
                    dlsym(vdecHandle, "OH_VideoDecoder_GetOutputBuffer");
            // 注意：不 dlclose，保持库加载
        } else {
            OH_LOG_WARN(LOG_APP, "dlopen libnative_media_vdec.so failed: %{public}s", dlerror());
        }
    }
    
    g_syncApiAvailable = (pfn_QueryInputBuffer != nullptr && pfn_QueryOutputBuffer != nullptr
                          && pfn_GetInputBuffer != nullptr);
    
    OH_LOG_INFO(LOG_APP, "Sync mode API availability: QueryInputBuffer=%{public}s, "
                "QueryOutputBuffer=%{public}s, RenderOutputBufferAtTime=%{public}s, "
                "GetInputBuffer=%{public}s, GetOutputBuffer=%{public}s",
                pfn_QueryInputBuffer ? "YES" : "NO",
                pfn_QueryOutputBuffer ? "YES" : "NO",
                pfn_RenderOutputBufferAtTime ? "YES" : "NO",
                pfn_GetInputBuffer ? "YES" : "NO",
                pfn_GetOutputBuffer ? "YES" : "NO");
    
    if (!g_syncApiAvailable) {
        OH_LOG_WARN(LOG_APP, "Sync mode APIs not available on this device, "
                    "will fall back to async mode");
    }
    
    return g_syncApiAvailable;
}

/**
 * 尝试加载 API 15+/20+ 的 AVFormat 键名符号
 * 这些是 extern const char* 全局变量，在低版本设备上不存在
 * dlsym 返回变量地址（const char**），需要解引用一次获取实际字符串
 */
static void TryLoadMediaKeys() {
    if (g_mediaKeysLoaded) return;
    g_mediaKeysLoaded = true;
    
    // OH_MD_KEY_VIDEO_DECODER_OUTPUT_ENABLE_VRR (API 15+)
    const char** pVrr = (const char**)dlsym(RTLD_DEFAULT, "OH_MD_KEY_VIDEO_DECODER_OUTPUT_ENABLE_VRR");
    if (pVrr) key_vrr_enable = *pVrr;
    
    // OH_MD_KEY_ENABLE_SYNC_MODE (API 20+)
    const char** pSync = (const char**)dlsym(RTLD_DEFAULT, "OH_MD_KEY_ENABLE_SYNC_MODE");
    if (pSync) key_enable_sync_mode = *pSync;
    
    // 如果 RTLD_DEFAULT 找不到，尝试从 libnative_media_codecbase.so 显式加载
    if (!pVrr || !pSync) {
        void* codecbaseHandle = dlopen("libnative_media_codecbase.so", RTLD_NOW);
        if (codecbaseHandle != nullptr) {
            if (!pVrr) {
                pVrr = (const char**)dlsym(codecbaseHandle, "OH_MD_KEY_VIDEO_DECODER_OUTPUT_ENABLE_VRR");
                if (pVrr) key_vrr_enable = *pVrr;
            }
            if (!pSync) {
                pSync = (const char**)dlsym(codecbaseHandle, "OH_MD_KEY_ENABLE_SYNC_MODE");
                if (pSync) key_enable_sync_mode = *pSync;
            }
        }
    }
    
    OH_LOG_INFO(LOG_APP, "Media keys availability: VRR_ENABLE=%{public}s, SYNC_MODE=%{public}s",
                key_vrr_enable ? key_vrr_enable : "N/A",
                key_enable_sync_mode ? key_enable_sync_mode : "N/A");
}

// 视频格式掩码（来自 moonlight-common-c/Limelight.h）
#define VIDEO_FORMAT_MASK_H264   0x000F
#define VIDEO_FORMAT_MASK_H265   0x0F00
#define VIDEO_FORMAT_MASK_AV1    0xF000

// =============================================================================
// 常量定义
// =============================================================================

// 缓冲区配置
static constexpr int kMinBufferCount = 2;       // 最小缓冲区数（双缓冲）
static constexpr int kMaxBufferCount = 8;       // 最大缓冲区数
static constexpr int kHighFpsThreshold = 60;    // 高帧率阈值
static constexpr int kHighFpsMaxBuffers = 4;    // 高帧率时最大缓冲区数

// 超时配置
static constexpr int kMinTimeoutMs = 50;        // 最小等待超时 (ms) - 增加以支持高帧率
static constexpr int kMaxTimeoutMs = 100;       // 最大等待超时 (ms) - 增加以支持高帧率

// 统计配置
static constexpr int64_t kStatsUpdateIntervalMs = 1000;  // 统计更新间隔
static constexpr size_t kMaxTimestampMapSize = 120;      // 时间戳映射最大大小
static constexpr int64_t kMaxValidDecodeTimeMs = 1000;   // 有效解码时间上限

// 颜色空间常量 (OH_ColorPrimary)
static constexpr int32_t kColorPrimaryBT709 = 1;
static constexpr int32_t kColorPrimaryBT601 = 6;
static constexpr int32_t kColorPrimaryBT2020 = 9;

// 传输特性常量 (OH_TransferCharacteristic)
static constexpr int32_t kTransferCharSDR = 1;   // BT709 (SDR)
static constexpr int32_t kTransferCharPQ = 16;   // PQ (HDR10/HDR10+)
static constexpr int32_t kTransferCharHLG = 18;  // HLG (HDR Vivid)

// 矩阵系数常量 (OH_MatrixCoefficient)
static constexpr int32_t kMatrixCoeffBT709 = 1;
static constexpr int32_t kMatrixCoeffBT601 = 6;
static constexpr int32_t kMatrixCoeffBT2020NCL = 9;

// EMA 平滑系数
static constexpr double kEmaAlphaKeyframe = 0.03;  // 关键帧权重（较小，减少影响）
static constexpr double kEmaAlphaNormal = 0.1;     // 普通帧权重

// 同步模式超时配置（微秒）
// 直接提交超时（在网络回调线程中）：必须为 0 以避免阻塞网络线程
// 参考官方文档：timeoutUs = 0 表示立即退出，不等待
static constexpr int64_t kSyncDirectSubmitTimeoutUs = 0;
// SyncDecodeLoop 中输入/输出查询超时：同样为 0，由循环自身控制节奏
static constexpr int64_t kSyncLoopQueryTimeoutUs = 0;

// 延迟恢复常量
// L1: 同步模式 drain-to-latest（始终丢弃堆积帧，仅渲染最新帧）
// L2: 异步模式帧跳过 - 解码时间超过 N 倍帧间隔时跳过非关键帧
static constexpr double kAsyncSkipThresholdMultiplier = 3.0;
// L3: 临界延迟 IDR 恢复 - 解码时间超过 N 倍帧间隔时丢弃 P 帧并请求 IDR
static constexpr double kCriticalLatencyMultiplier = 8.0;
static constexpr double kCriticalLatencyMinMs = 100.0;  // IDR 恢复最小阈值
static constexpr int kLatencyRecoveryMinFrames = 60;     // 启动阶段不触发
// L4: 网络抖动突发检测 - 连续 N 帧在极短间隔内到达时主动 Flush + IDR
static constexpr int kBurstFlushThreshold = 4;           // 连续突发帧数阈值
static constexpr double kBurstIntervalRatio = 0.3;       // 到达间隔 < 帧间隔 × 此比率视为突发
// L5: 异步渲染跳帧 - 输出间隔过短且延迟偏高时跳帧
// 目的：当解码器批量输出帧时，跳过中间帧只渲染最新帧，保持均匀帧间距
//
// 帧率自适应：120Hz 下 VPU 管线延迟（15-25ms）本身就远超帧间隔，
// 需要更宽松的阈值避免误丢帧。60Hz 下保持原始阈值以确保鼠标流畅。
//
// 基准阈值（适用于 ≤60fps）— 贴近原始值，确保 burst 帧被裁剪
static constexpr double kL5LatencyRatio_Base = 1.5;    // 延迟 > 帧间隔 × 此值 (60Hz: >25ms)
static constexpr double kL5IntervalRatio_Base = 0.5;   // 输出间隔 < 帧间隔 × 此值 (60Hz: <8.3ms)
// 高帧率阈值（适用于 >90fps，帧间隔 < 11ms 时管线延迟占比更大）
static constexpr double kL5LatencyRatio_HighFps = 5.0; // 120Hz: >41.7ms 才触发
static constexpr double kL5IntervalRatio_HighFps = 0.15; // 120Hz: <1.25ms 才触发
// 高帧率切换阈值
static constexpr double kL5HighFpsThreshold = 90.0;
// L5 绝对延迟下限（仅高帧率）：管线延迟低于此值时不跳帧
// 避免在快速解码器上误判正常的批量输出为堆积
static constexpr int64_t kL5AbsoluteLatencyFloorMs = 30;

// =============================================================================
// VideoDecoder 类实现
// =============================================================================

VideoDecoder::VideoDecoder() {
    memset(&stats_, 0, sizeof(stats_));
}

VideoDecoder::~VideoDecoder() {
    Cleanup();
}

const char* VideoDecoder::GetMimeType(VideoCodecType codec) const {
    switch (codec) {
        case VideoCodecType::H264:
            return OH_AVCODEC_MIMETYPE_VIDEO_AVC;
        case VideoCodecType::HEVC:
            return OH_AVCODEC_MIMETYPE_VIDEO_HEVC;
        case VideoCodecType::AV1:
            // HarmonyOS NEXT 目前不支持 AV1 硬解码
            // 未来版本可能添加 OH_AVCODEC_MIMETYPE_VIDEO_AV1
            // 暂时回退到 HEVC
            OH_LOG_WARN(LOG_APP, "AV1 not supported, falling back to HEVC");
            return OH_AVCODEC_MIMETYPE_VIDEO_HEVC;
        default:
            return OH_AVCODEC_MIMETYPE_VIDEO_AVC;
    }
}

int VideoDecoder::Init(const VideoDecoderConfig& config, OHNativeWindow* window) {
    if (decoder_ != nullptr) {
        OH_LOG_WARN(LOG_APP, "VideoDecoder already initialized, cleaning up first");
        Cleanup();
    }
    
    config_ = config;
    window_ = window;
    
    // 设置软件队列大小（用于同步模式）
    // 使用用户设置的 bufferCount，如果是 0（默认）则使用 2（最低延迟）
    if (config_.bufferCount > 0) {
        maxPendingFrames_ = static_cast<size_t>(std::clamp(config_.bufferCount, 2, 16));
    } else {
        maxPendingFrames_ = 2;  // 默认值，最低延迟
    }
    OH_LOG_INFO(LOG_APP, "{Init} Software queue size: %{public}zu", maxPendingFrames_);
    
    OH_LOG_INFO(LOG_APP, "{Init} Initializing video decoder: %{public}dx%{public}d@%.2f, codec=%{public}d, window=%{public}p",
                config_.width, config_.height, config_.fps, static_cast<int>(config_.codec), static_cast<void*>(window));
    
    // 创建视频解码器
    const char* mimeType = GetMimeType(config_.codec);
    OH_LOG_INFO(LOG_APP, "{Init} Creating decoder with mime type: %{public}s", mimeType);
    
    decoder_ = OH_VideoDecoder_CreateByMime(mimeType);
    if (decoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "{Init} Failed to create video decoder for mime type: %{public}s (may need to try H264)", mimeType);
        
        // 如果 HEVC 失败，尝试回退到 H264
        if (config_.codec == VideoCodecType::HEVC) {
            OH_LOG_INFO(LOG_APP, "{Init} HEVC failed, trying H264 fallback...");
            mimeType = "video/avc";
            decoder_ = OH_VideoDecoder_CreateByMime(mimeType);
            if (decoder_ == nullptr) {
                OH_LOG_ERROR(LOG_APP, "{Init} H264 fallback also failed");
                return -1;
            }
            OH_LOG_INFO(LOG_APP, "{Init} H264 fallback succeeded");
        } else {
            return -1;
        }
    }
    
    OH_LOG_INFO(LOG_APP, "{Init} Decoder created successfully");
    
    // 用于后续 API 调用的返回值
    int32_t ret = AV_ERR_OK;
    
    // 根据解码模式决定是否注册回调
    // 同步模式：不注册回调，在 Configure 前设置 OH_MD_KEY_ENABLE_SYNC_MODE
    // 异步模式：注册回调
    if (config_.decoderMode == DecoderMode::ASYNC) {
        OH_LOG_INFO(LOG_APP, "{Init} Async mode, registering callbacks...");
        
        // 注册回调
        OH_AVCodecCallback callback = {
            .onError = OnError,
            .onStreamChanged = OnOutputFormatChanged,
            .onNeedInputBuffer = OnInputBufferAvailable,
            .onNewOutputBuffer = OnOutputBufferAvailable
        };
        
        ret = OH_VideoDecoder_RegisterCallback(decoder_, callback, this);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "{Init} Failed to register callback: %{public}d", ret);
            OH_VideoDecoder_Destroy(decoder_);
            decoder_ = nullptr;
            return -1;
        }
    } else {
        OH_LOG_INFO(LOG_APP, "{Init} Sync mode enabled, skipping callback registration");
    }
    
    OH_LOG_INFO(LOG_APP, "{Init} Creating format...");
    
    // 配置解码器 - 使用 OH_AVFormat_CreateVideoFormat 而不是手动设置
    OH_AVFormat* format = OH_AVFormat_CreateVideoFormat(mimeType, config_.width, config_.height);
    if (format == nullptr) {
        OH_LOG_ERROR(LOG_APP, "{Init} Failed to create AVFormat");
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
        return -1;
    }
    
    OH_LOG_INFO(LOG_APP, "{Init} Format created, setting parameters...");
    
    // 设置帧率 - 这让解码器知道预期的输入速率
    // 报告 2 倍实际帧率，防止硬件 VPU 在静态内容时降频
    // 类似 Android 的 KEY_OPERATING_RATE = Short.MAX_VALUE 策略：
    // 当画面静止时，帧数据很小（可能仅几百字节），VPU 可能进入节能模式降低时钟频率。
    // 当突然出现复杂画面（如打开动画），VPU 频率提升有延迟，导致前几帧解码变慢产生卡顿。
    // 报告更高帧率可以让 VPU 保持较高的工作频率，避免静态↔动态切换时的"冷启动"卡顿。
    double reportedFps = config_.fps * 2.0;
    OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, reportedFps);
    OH_LOG_INFO(LOG_APP, "{Init} Reporting FPS %.2f to decoder (actual=%.2f, 2x to prevent VPU throttling)",
                reportedFps, config_.fps);
    
    // 预分配足够大的输入缓冲区
    // 静态内容时帧可能仅几百字节，运动开始时帧可能达到数百 KB。
    // 如果不预分配，解码器可能需要在运动开始时重新分配缓冲区，增加延迟。
    // 设置 MAX_INPUT_SIZE 确保输入 buffer 一开始就足够大。
    int maxInputSize = config_.width * config_.height * 3 / 2;  // 按 YUV420 全帧大小预估
    if (maxInputSize < 512 * 1024) maxInputSize = 512 * 1024;   // 至少 512KB
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE, maxInputSize);
    OH_LOG_INFO(LOG_APP, "{Init} Max input size set to %{public}d bytes", maxInputSize);
    
    // 低延迟模式 - 关键优化，让解码器尽快输出帧
    // 文档说明：使能低时延视频编解码的键，值类型为int32_t，1表示使能
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    
    // VRR (Variable Refresh Rate) 模式 - API 15+ (HarmonyOS)
    // 启用后解码器输出将适配可变刷新率显示，根据视频内容动态调整屏幕刷新率
    // 注意：
    // 1. 只支持硬件解码后直接送显的视频播放场景
    // 2. 屏幕整体刷新率会被调整
    // 3. 当刷新率小于视频帧率时，会丢弃部分视频帧以节省功耗
    // 4. 游戏串流场景下可能不适合（丢帧会影响体验）
    // OH_MD_KEY_VIDEO_DECODER_OUTPUT_ENABLE_VRR: 使能视频解码器输出适配VRR显示
    // 通过 dlsym 动态加载，避免 extern const char* 符号在低版本设备上链接失败
    TryLoadMediaKeys();
    if (config_.enableVrr) {
        if (key_vrr_enable != nullptr) {
            OH_AVFormat_SetIntValue(format, key_vrr_enable, 1);
            OH_LOG_INFO(LOG_APP, "{Init} VRR (Variable Refresh Rate) mode enabled for decoder output");
        } else {
            OH_LOG_INFO(LOG_APP, "{Init} VRR requested but OH_MD_KEY_VIDEO_DECODER_OUTPUT_ENABLE_VRR not available (API < 15)");
        }
    } else {
        OH_LOG_INFO(LOG_APP, "{Init} VRR mode disabled");
    }
    
    // 同步模式配置（API 20+）
    // 文档说明：使能视频解码同步模式，必须将 OH_MD_KEY_ENABLE_SYNC_MODE 配置为 1
    // 注意：同步模式在调用 Configure 接口前不能调用 RegisterCallback 接口
    // 重要：如果同步模式配置失败，必须回退到异步模式并重新注册回调
    // 
    // OH_MD_KEY_ENABLE_SYNC_MODE 通过 dlsym 动态加载（key_enable_sync_mode），
    // 避免 extern const char* 符号在低版本设备上引发链接失败
    bool syncModeConfigured = false;
    bool needAsyncFallback = false;
    
    if (config_.decoderMode == DecoderMode::SYNC) {
        // 先检查同步模式 API 是否可用（API 14+）
        if (!TryLoadSyncModeApis()) {
            OH_LOG_WARN(LOG_APP, "{Init} Sync mode APIs (QueryInputBuffer/QueryOutputBuffer) not available, "
                        "falling back to async mode");
            needAsyncFallback = true;
        }
        // 尝试启用同步模式 - OH_MD_KEY_ENABLE_SYNC_MODE 在 API 20+ 可用
        // 通过 dlsym 动态加载，避免 extern const char* 符号在低版本设备上链接失败
        else if (key_enable_sync_mode != nullptr) {
            OH_AVFormat_SetIntValue(format, key_enable_sync_mode, 1);
            syncModeConfigured = true;
            OH_LOG_INFO(LOG_APP, "{Init} Sync decode mode configured via OH_MD_KEY_ENABLE_SYNC_MODE");
        } else {
            OH_LOG_WARN(LOG_APP, "{Init} OH_MD_KEY_ENABLE_SYNC_MODE not available (API < 20), falling back to async mode");
            needAsyncFallback = true;
        }
    }
    
    // 如果同步模式未成功配置，回退到异步模式并注册回调
    if (needAsyncFallback) {
        OH_LOG_INFO(LOG_APP, "{Init} Registering async callbacks for fallback...");
        config_.decoderMode = DecoderMode::ASYNC;
        
        OH_AVCodecCallback callback = {
            .onError = OnError,
            .onStreamChanged = OnOutputFormatChanged,
            .onNeedInputBuffer = OnInputBufferAvailable,
            .onNewOutputBuffer = OnOutputBufferAvailable
        };
        
        ret = OH_VideoDecoder_RegisterCallback(decoder_, callback, this);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "{Init} Failed to register async callback after sync fallback: %{public}d", ret);
            OH_AVFormat_Destroy(format);
            OH_VideoDecoder_Destroy(decoder_);
            decoder_ = nullptr;
            return -1;
        }
        OH_LOG_INFO(LOG_APP, "{Init} Async callbacks registered successfully");
    }
    
    // 缓冲区配置优化 - 减少管线延迟
    // HarmonyOS 官方 API：
    // - OH_MD_MAX_INPUT_BUFFER_COUNT: 最大输入缓冲区个数
    // - OH_MD_MAX_OUTPUT_BUFFER_COUNT: 最大输出缓冲区个数
    // 
    // bufferCount = 0 表示使用系统默认值（不设置）
    // bufferCount = 2-8 表示指定缓冲区数量
    
    int bufferCount = config_.bufferCount;
    
    // 同步模式需要更大的 buffer 数量，因为需要手动管理 buffer
    // 如果用户没有指定（bufferCount=0），同步模式使用较大的默认值
    if (syncModeConfigured && bufferCount == 0) {
        bufferCount = 4;  // 同步模式默认 4 个 buffer
        OH_LOG_INFO(LOG_APP, "{Init} Sync mode: using default buffer count of 4");
    }
    
    if (bufferCount > 0) {
        // 限制缓冲区数量在有效范围内，完全尊重用户设置
        bufferCount = std::clamp(bufferCount, kMinBufferCount, kMaxBufferCount);
        
        OH_AVFormat_SetIntValue(format, OH_MD_MAX_INPUT_BUFFER_COUNT, bufferCount);
        OH_AVFormat_SetIntValue(format, OH_MD_MAX_OUTPUT_BUFFER_COUNT, bufferCount);
        
        // 尝试设置解码器特定的输出缓冲区数量（可能不是所有设备都支持）
        OH_AVFormat_SetIntValue(format, "video_decoder_output_buffer_count", bufferCount);
        OH_LOG_INFO(LOG_APP, "{Init} Decoder buffer count set to: %{public}d (fps=%.2f, sync=%{public}d)", 
                    bufferCount, config_.fps, syncModeConfigured ? 1 : 0);
    } else {
        // bufferCount = 0，使用系统默认值
        OH_LOG_INFO(LOG_APP, "{Init} Using system default buffer count (fps=%.2f)", config_.fps);
    }
    
    // 配置颜色范围: 0 = Limited, 1 = Full
    int32_t colorRange = (config_.colorRange == ColorRange::FULL) ? 1 : 0;
#ifdef OH_MD_KEY_RANGE_FLAG
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_RANGE_FLAG, colorRange);
#endif
    
    // 配置颜色空间标准 (OH_ColorPrimary)
    int32_t colorPrimary = kColorPrimaryBT709;
    switch (config_.colorSpace) {
        case ColorSpace::REC_601:  colorPrimary = kColorPrimaryBT601;  break;
        case ColorSpace::REC_709:  colorPrimary = kColorPrimaryBT709;  break;
        case ColorSpace::REC_2020: colorPrimary = kColorPrimaryBT2020; break;
    }
#ifdef OH_MD_KEY_COLOR_PRIMARIES
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_COLOR_PRIMARIES, colorPrimary);
#else
    OH_LOG_WARN(LOG_APP, "{Init} OH_MD_KEY_COLOR_PRIMARIES not available");
#endif
    
    // 配置传输特性 (OH_TransferCharacteristic)
    int32_t transferChar = kTransferCharSDR;
    if (config_.enableHdr) {
        switch (config_.hdrType) {
            case HdrType::HDR10:     transferChar = kTransferCharPQ;  break;
            case HdrType::HLG:      transferChar = kTransferCharHLG; break;
            default:                 transferChar = kTransferCharPQ;  break;
        }
    }
#ifdef OH_MD_KEY_TRANSFER_CHARACTERISTICS
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_TRANSFER_CHARACTERISTICS, transferChar);
#else
    OH_LOG_WARN(LOG_APP, "{Init} OH_MD_KEY_TRANSFER_CHARACTERISTICS not available");
#endif
    
    // 配置矩阵系数 (OH_MatrixCoefficient)
    int32_t matrixCoeff = kMatrixCoeffBT709;
    switch (config_.colorSpace) {
        case ColorSpace::REC_601:  matrixCoeff = kMatrixCoeffBT601;     break;
        case ColorSpace::REC_709:  matrixCoeff = kMatrixCoeffBT709;     break;
        case ColorSpace::REC_2020: matrixCoeff = kMatrixCoeffBT2020NCL; break;
    }
#ifdef OH_MD_KEY_MATRIX_COEFFICIENTS
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_MATRIX_COEFFICIENTS, matrixCoeff);
#else
    OH_LOG_WARN(LOG_APP, "{Init} OH_MD_KEY_MATRIX_COEFFICIENTS not available");
#endif
    
    // 配置 HDR Vivid 模式（Sunshine 编码端在 HLG 模式下会携带 CUVA T.35 Vivid 动态元数据）
    // 告诉解码器按 HDR Vivid 标准解析码流中的 CUVA SEI
    if (config_.enableHdr && config_.hdrType == HdrType::HLG) {
#ifdef OH_MD_KEY_VIDEO_IS_HDR_VIVID
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_IS_HDR_VIVID, 1);
        OH_LOG_INFO(LOG_APP, "{Init} HDR Vivid mode enabled for HLG stream");
#else
        OH_LOG_WARN(LOG_APP, "{Init} OH_MD_KEY_VIDEO_IS_HDR_VIVID not available");
#endif
    }
    
    OH_LOG_INFO(LOG_APP, "{Init} Configuring decoder: HDR=%{public}d, hdrType=%{public}d (0=SDR,1=HDR10,2=HLG), colorSpace=%{public}d, colorRange=%{public}d",
                config_.enableHdr ? 1 : 0, static_cast<int>(config_.hdrType), 
                static_cast<int>(config_.colorSpace), static_cast<int>(config_.colorRange));
    
    ret = OH_VideoDecoder_Configure(decoder_, format);
    OH_AVFormat_Destroy(format);
    
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "{Init} Failed to configure decoder: %{public}d", ret);
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
        return -1;
    }
    
    OH_LOG_INFO(LOG_APP, "{Init} Decoder configured, setting surface...");
    
    // 设置输出 Surface
    if (window_ != nullptr) {
        // 配置 NativeWindow 的 colorspace 和 HDR 元数据以支持 HDR
        // 这是确保 HDR 内容正确显示的关键步骤
        if (config_.enableHdr) {
            OH_LOG_INFO(LOG_APP, "{Init} Configuring NativeWindow for HDR: hdrType=%{public}d (0=SDR,1=HDR10,2=HLG), colorRange=%{public}d",
                        static_cast<int>(config_.hdrType), static_cast<int>(config_.colorRange));
            
            // HarmonyOS OH_NativeBuffer_ColorSpace 枚举 (buffer_common.h)
            // OH_COLORSPACE_BT2020_HLG_FULL = 4 (COLORPRIMARIES_BT2020 | TRANSFUNC_HLG | RANGE_FULL)
            // OH_COLORSPACE_BT2020_PQ_FULL = 5 (COLORPRIMARIES_BT2020 | TRANSFUNC_PQ | RANGE_FULL)
            // OH_COLORSPACE_BT2020_HLG_LIMIT = 9 (COLORPRIMARIES_BT2020 | TRANSFUNC_HLG | RANGE_LIMITED)
            // OH_COLORSPACE_BT2020_PQ_LIMIT = 10 (COLORPRIMARIES_BT2020 | TRANSFUNC_PQ | RANGE_LIMITED)
            
            OH_NativeBuffer_ColorSpace windowColorSpace;
            OH_NativeBuffer_MetadataType metadataType;
            bool isFullRange = (config_.colorRange == ColorRange::FULL);
            
            switch (config_.hdrType) {
                case HdrType::HLG:       // HLG with HDR Vivid
                    windowColorSpace = isFullRange ? OH_COLORSPACE_BT2020_HLG_FULL : OH_COLORSPACE_BT2020_HLG_LIMIT;
                    // 使用 OH_VIDEO_HDR_VIVID 而非 OH_VIDEO_HDR_HLG
                    // Sunshine 编码端会在 HLG 码流中携带 CUVA T.35 Vivid 动态元数据
                    // OH_VIDEO_HDR_VIVID 告知显示管线按 Vivid 标准处理色调映射
                    metadataType = OH_VIDEO_HDR_VIVID;
                    break;
                case HdrType::HDR10:      // PQ
                default:
                    windowColorSpace = isFullRange ? OH_COLORSPACE_BT2020_PQ_FULL : OH_COLORSPACE_BT2020_PQ_LIMIT;
                    metadataType = OH_VIDEO_HDR_HDR10;
                    break;
            }
            
            OH_LOG_INFO(LOG_APP, "{Init} HDR NativeWindow: colorspace=%{public}d, metadata=%{public}d, fullRange=%{public}d",
                        static_cast<int>(windowColorSpace), static_cast<int>(metadataType), isFullRange ? 1 : 0);
            
#ifdef __OHOS__
            // 1. 设置 Color Gamut（颜色域）
            int32_t colorGamut = (config_.hdrType == HdrType::HLG) ?
                NATIVEBUFFER_COLOR_GAMUT_BT2100_HLG : NATIVEBUFFER_COLOR_GAMUT_BT2100_PQ;
            int32_t gamutRet = OH_NativeWindow_NativeWindowHandleOpt(window_, SET_COLOR_GAMUT, colorGamut);
            if (gamutRet != 0) {
                OH_LOG_WARN(LOG_APP, "{Init} Failed to set color gamut: %{public}d", gamutRet);
            }
            
            // 2. 设置 HDR 元数据类型
            int32_t metaRet = OH_NativeWindow_SetMetadataValue(window_, OH_HDR_METADATA_TYPE,
                sizeof(metadataType), reinterpret_cast<uint8_t*>(&metadataType));
            if (metaRet != 0) {
                OH_LOG_WARN(LOG_APP, "{Init} Failed to set HDR metadata: %{public}d", metaRet);
            }
            
            // 3. 设置 colorspace
            int32_t csRet = OH_NativeWindow_SetColorSpace(window_, windowColorSpace);
            if (csRet != 0) {
                OH_LOG_WARN(LOG_APP, "{Init} Failed to set colorspace: %{public}d", csRet);
            }
            
            // 4. 设置 HDR 白点亮度
            float hdrWhitePointBrightness = 1.0f;
            int32_t hdrBrightRet = OH_NativeWindow_NativeWindowHandleOpt(window_, SET_HDR_WHITE_POINT_BRIGHTNESS, hdrWhitePointBrightness);
            if (hdrBrightRet != 0) {
                OH_LOG_WARN(LOG_APP, "{Init} Failed to set HDR white point: %{public}d", hdrBrightRet);
            }
            
            // 5. 设置 HDR 静态元数据（SMPTE 2086 + CTA 861.3）
            // 这些数据由 Sunshine 编码端从显示器 EDID 读取并通过 SEI 传递
            // 解码器会从码流中解析 MDCV/CLL SEI，但显示管线初始化时也需要默认值
            // 使用 BT.2020 标准色域 + 典型 HDR 显示器参数作为默认值
            OH_NativeBuffer_StaticMetadata staticMetadata = {};
            // BT.2020 色域主色坐标
            staticMetadata.smpte2086.displayPrimaryRed   = {0.708f, 0.292f};
            staticMetadata.smpte2086.displayPrimaryGreen  = {0.170f, 0.797f};
            staticMetadata.smpte2086.displayPrimaryBlue   = {0.131f, 0.046f};
            staticMetadata.smpte2086.whitePoint           = {0.3127f, 0.3290f};  // D65
            staticMetadata.smpte2086.maxLuminance         = 1000.0f;  // 典型 HDR 峰值亮度 1000 nits
            staticMetadata.smpte2086.minLuminance         = 0.001f;   // 典型最低亮度
            staticMetadata.cta861.maxContentLightLevel         = 1000.0f;
            staticMetadata.cta861.maxFrameAverageLightLevel    = 400.0f;
            
            int32_t staticMetaRet = OH_NativeWindow_SetMetadataValue(window_, OH_HDR_STATIC_METADATA,
                sizeof(staticMetadata), reinterpret_cast<uint8_t*>(&staticMetadata));
            if (staticMetaRet != 0) {
                OH_LOG_WARN(LOG_APP, "{Init} Failed to set HDR static metadata: %{public}d", staticMetaRet);
            } else {
                OH_LOG_INFO(LOG_APP, "{Init} HDR static metadata set: maxLum=1000, minLum=0.001, maxCLL=1000, maxFALL=400");
            }
#else
            OH_LOG_WARN(LOG_APP, "{Init} OH_NativeWindow HDR APIs not available on this platform");
#endif
        }
        
        ret = OH_VideoDecoder_SetSurface(decoder_, window_);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "{Init} Failed to set surface: %{public}d", ret);
            OH_VideoDecoder_Destroy(decoder_);
            decoder_ = nullptr;
            return -1;
        }
    } else {
        OH_LOG_WARN(LOG_APP, "{Init} No window set, surface rendering will not work");
    }
    
    OH_LOG_INFO(LOG_APP, "{Init} Surface set, preparing decoder...");
    
    // 准备解码器
    ret = OH_VideoDecoder_Prepare(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "{Init} Failed to prepare decoder: %{public}d", ret);
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
        return -1;
    }
    
    configured_ = true;
    OH_LOG_INFO(LOG_APP, "{Init} Video decoder initialized successfully");
    
    return 0;
}

int VideoDecoder::Start() {
    if (!configured_ || decoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Decoder not configured");
        return -1;
    }
    
    int32_t ret = OH_VideoDecoder_Start(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to start decoder: %{public}d", ret);
        return -1;
    }
    
    running_ = true;
    
    // 同步模式：启动解码线程
    if (config_.decoderMode == DecoderMode::SYNC) {
        syncDecodeRunning_ = true;
        syncDecodeThread_ = std::thread(&VideoDecoder::SyncDecodeLoop, this);
        OH_LOG_INFO(LOG_APP, "Video decoder started in SYNC mode");
    } else {
        OH_LOG_INFO(LOG_APP, "Video decoder started in ASYNC mode");
    }
    
    return 0;
}

int VideoDecoder::Stop() {
    running_ = false;
    
    // 同步模式：停止解码线程
    // 必须先 join 线程（等待 shared_lock 释放），再获取 unique_lock
    if (syncDecodeRunning_) {
        syncDecodeRunning_ = false;
        pendingFrameCond_.notify_all();
        if (syncDecodeThread_.joinable()) {
            syncDecodeThread_.join();
        }
    }
    
    // 参考官方文档：使用 unique_lock 保护 Stop 操作
    {
        std::unique_lock<std::shared_mutex> codecLock(codecMutex_);
        if (decoder_ != nullptr) {
            OH_VideoDecoder_Stop(decoder_);
        }
    }
    
    // 唤醒等待的线程（异步模式）
    inputCond_.notify_all();
    
    // 清空待解码帧队列（同步模式）
    {
        std::lock_guard<std::mutex> lock(pendingFrameMutex_);
        while (!pendingFrameQueue_.empty()) pendingFrameQueue_.pop();
    }
    
    OH_LOG_INFO(LOG_APP, "Video decoder stopped");
    return 0;
}

int VideoDecoder::Flush() {
    if (decoder_ == nullptr) {
        return -1;
    }
    
    // 参考官方文档：使用 unique_lock 保护 Flush 操作，防止解码线程并发访问
    std::unique_lock<std::shared_mutex> codecLock(codecMutex_);
    
    int32_t ret = OH_VideoDecoder_Flush(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to flush decoder: %{public}d", ret);
        return -1;
    }
    
    // 清空队列
    {
        std::lock_guard<std::mutex> lock(inputMutex_);
        while (!inputIndexQueue_.empty()) inputIndexQueue_.pop();
        while (!inputBufferQueue_.empty()) inputBufferQueue_.pop();
    }
    
    // 重新启动
    ret = OH_VideoDecoder_Start(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to restart decoder after flush: %{public}d", ret);
        return -1;
    }
    
    return 0;
}

void VideoDecoder::Cleanup() {
    Stop();
    
    if (decoder_ != nullptr) {
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
    }
    
    // 清空异步模式队列
    {
        std::lock_guard<std::mutex> lock(inputMutex_);
        while (!inputIndexQueue_.empty()) inputIndexQueue_.pop();
        while (!inputBufferQueue_.empty()) inputBufferQueue_.pop();
    }
    
    // 清空同步模式队列
    {
        std::lock_guard<std::mutex> lock(pendingFrameMutex_);
        while (!pendingFrameQueue_.empty()) pendingFrameQueue_.pop();
    }
    
    // 清空时间戳映射
    {
        std::lock_guard<std::mutex> lock(timestampMutex_);
        timestampToEnqueueTime_.clear();
    }
    
    window_ = nullptr;
    configured_ = false;
    firstFrameReceived_ = false;
    lastInstantDecodeTimeMs_ = 0;
    latencyRecoveryActive_ = false;
    lastOutputTimeMs_ = 0;
    lastFrameArrivalMs_ = 0;
    burstFrameCount_ = 0;
    lastAsyncRenderTimeMs_ = 0;
    
    OH_LOG_INFO(LOG_APP, "Video decoder cleaned up");
}

// 辅助函数：将 scatter-gather 分段写入目标缓冲区
static void CopySegmentsToBuffer(uint8_t* dest, const BufferSegment* segments, int segmentCount) {
    int offset = 0;
    for (int i = 0; i < segmentCount; i++) {
        memcpy(dest + offset, segments[i].data, segments[i].length);
        offset += segments[i].length;
    }
}

// 辅助函数：构建解码器输入缓冲区属性
static OH_AVCodecBufferAttr MakeInputBufferAttr(int32_t size, int64_t pts, VideoFrameType frameType) {
    OH_AVCodecBufferAttr attr = {0};
    attr.size = size;
    attr.offset = 0;
    attr.pts = pts;
    attr.flags = (frameType == VideoFrameType::I_FRAME) ? 
                 AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
    return attr;
}

void VideoDecoder::RecordEnqueueTimestamp(int64_t timestamp) {
    auto enqueueTimeMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    std::lock_guard<std::mutex> lock(timestampMutex_);
    timestampToEnqueueTime_[timestamp] = enqueueTimeMs;
    if (timestampToEnqueueTime_.size() > kMaxTimestampMapSize) {
        timestampToEnqueueTime_.erase(timestampToEnqueueTime_.begin());
    }
}

int VideoDecoder::SubmitDecodeUnitScatter(const BufferSegment* segments, int segmentCount,
                                           int totalSize,
                                           int frameNumber, VideoFrameType frameType,
                                           int64_t timestamp,
                                           uint16_t hostProcessingLatency) {
    if (!running_ || decoder_ == nullptr) {
        return -1;
    }
    
    // 解码器健康检查（节流：每 500ms 一次）
    // 如果解码器已失效，尽早返回错误触发上层恢复
    if (!CheckDecoderValid()) {
        OH_LOG_ERROR(LOG_APP, "Decoder invalid, requesting IDR for recovery");
        return -1;  // 触发 DR_NEED_IDR
    }
    
    // 首次调用时设置线程优先级 + 绑定大核
    SetupDecodeThreadPriority();
    
    // === L4 网络抖动突发检测（仅异步模式） ===
    // 同步模式下 L1 drain-to-latest 已足够处理突发到达，L4 的 IDR 请求反而会加重负担
    if (config_.decoderMode != DecoderMode::SYNC) {
        auto nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        int64_t lastArrival = lastFrameArrivalMs_.exchange(nowMs);
        double expectedFrameMs = 1000.0 / config_.fps;
        
        if (lastArrival > 0 && (nowMs - lastArrival) < static_cast<int64_t>(expectedFrameMs * kBurstIntervalRatio)) {
            int burst = burstFrameCount_.fetch_add(1) + 1;
            if (burst >= kBurstFlushThreshold && frameType != VideoFrameType::I_FRAME) {
                burstFrameCount_.store(0);
                // 清空软件待解码队列
                {
                    std::lock_guard<std::mutex> lock(pendingFrameMutex_);
                    int cleared = 0;
                    while (!pendingFrameQueue_.empty()) {
                        pendingFrameQueue_.pop();
                        cleared++;
                    }
                    if (cleared > 0) {
                        OH_LOG_WARN(LOG_APP, "L4 burst flush: cleared %{public}d queued frames", cleared);
                    }
                }
                latencyRecoveryActive_.store(true);
                UpdateReceivedStats(totalSize, hostProcessingLatency);
                {
                    std::lock_guard<std::mutex> lock(statsMutex_);
                    stats_.droppedFrames++;
                    stats_.droppedByL4++;
                }
                OH_LOG_WARN(LOG_APP, "L4 burst detected (%{public}d frames in <%.1fms interval), requesting IDR",
                            burst, expectedFrameMs * kBurstIntervalRatio);
                return -1;  // DR_NEED_IDR
            }
        } else {
            burstFrameCount_.store(0);
        }
    }
    
    // === L3 延迟恢复：临界延迟检查 ===
    // 当解码延迟过高时，丢弃 P 帧并触发 IDR 请求
    int recoveryResult = CheckLatencyRecovery(frameType, totalSize, hostProcessingLatency);
    if (recoveryResult < 0) {
        return recoveryResult;  // -1 = DR_NEED_IDR
    }
    
    // 同步模式：直接提交到解码器（scatter-gather 直写 AVBuffer）
    if (config_.decoderMode == DecoderMode::SYNC) {
        UpdateReceivedStats(totalSize, hostProcessingLatency);
        
        if (!firstFrameReceived_) {
            firstFrameReceived_ = true;
            OH_LOG_INFO(LOG_APP, "First video frame (scatter sync): %{public}dx%{public}d", 
                        config_.width, config_.height);
        }
        
        // 在网络回调线程中尝试直接提交：timeout=0（不阻塞），仅一次尝试
        // 参考官方文档：timeoutUs = 0 表示立即退出
        {
            std::shared_lock<std::shared_mutex> codecLock(codecMutex_);
            uint32_t inputIndex = 0;
            OH_AVErrCode ret = pfn_QueryInputBuffer(decoder_, &inputIndex, kSyncDirectSubmitTimeoutUs);
            
            if (ret == AV_ERR_OK) {
                OH_AVBuffer* inputBuffer = pfn_GetInputBuffer(decoder_, inputIndex);
                if (inputBuffer != nullptr) {
                    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(inputBuffer);
                    if (bufferAddr != nullptr) {
                        int32_t capacity = OH_AVBuffer_GetCapacity(inputBuffer);
                        if (totalSize > capacity) {
                            OH_LOG_ERROR(LOG_APP, "Scatter sync: frame too large %{public}d > %{public}d", totalSize, capacity);
                            return -1;
                        }
                        
                        // 直接将分段数据写入 AVBuffer（无中间缓冲区）
                        CopySegmentsToBuffer(bufferAddr, segments, segmentCount);
                        
                        auto attr = MakeInputBufferAttr(totalSize, timestamp, frameType);
                        OH_AVBuffer_SetBufferAttr(inputBuffer, &attr);
                        
                        RecordEnqueueTimestamp(timestamp);
                        
                        ret = OH_VideoDecoder_PushInputBuffer(decoder_, inputIndex);
                        if (ret == AV_ERR_OK) {
                            // 唤醒解码线程立即轮询输出，避免 wait_for(halfFrame) 空等
                            pendingFrameCond_.notify_one();
                            return 0;  // 直接提交成功
                        }
                    }
                }
            } else if (ret == AV_ERR_UNSUPPORT) {
                OH_LOG_ERROR(LOG_APP, "Scatter sync: AV_ERR_UNSUPPORT - sync mode not supported on this device!");
            }
            // AV_ERR_TRY_AGAIN_LATER 或其他错误：静默回退到队列
        }
        
        // 直接提交失败，回退到队列（需要合并数据）
        {
            bool hadOverflow = false;
            std::lock_guard<std::mutex> lock(pendingFrameMutex_);
            while (pendingFrameQueue_.size() >= maxPendingFrames_) {
                hadOverflow = true;
                pendingFrameQueue_.pop();
                std::lock_guard<std::mutex> statsLock(statsMutex_);
                stats_.droppedFrames++;
                stats_.droppedByQueueOverflow++;
            }
            
            PendingFrame frame;
            frame.data.resize(totalSize);
            CopySegmentsToBuffer(frame.data.data(), segments, segmentCount);
            frame.frameNumber = frameNumber;
            frame.frameType = frameType;
            frame.timestamp = timestamp;
            frame.hostProcessingLatency = hostProcessingLatency;
            
            pendingFrameQueue_.push(std::move(frame));
            pendingFrameCond_.notify_one();
            
            // 队列溢出 = 丢弃了中间 P 帧 → 后续 P 帧缺少参考帧会损坏
            // 激活恢复模式：丢弃后续 P 帧，等待 IDR 重建参考链
            if (hadOverflow && !latencyRecoveryActive_.exchange(true)) {
                LiRequestIdrFrame();
                OH_LOG_WARN(LOG_APP, "Scatter sync: queue overflow, requesting IDR recovery");
            }
        }
        
        return 0;
    }
    
    // 异步模式：scatter-gather 直写
    uint32_t inputIndex;
    OH_AVBuffer* inputBuffer = nullptr;
    
    {
        std::unique_lock<std::mutex> lock(inputMutex_);
        int timeoutMs = kMaxTimeoutMs;
        
        if (inputIndexQueue_.empty()) {
            if (!inputCond_.wait_for(lock, std::chrono::milliseconds(timeoutMs), 
                [this] { return !inputIndexQueue_.empty() || !running_; })) {
                std::lock_guard<std::mutex> statsLock(statsMutex_);
                stats_.droppedFrames++;
                stats_.droppedByTimeout++;
                return -1;
            }
        }
        
        if (!running_ || inputIndexQueue_.empty()) {
            return -1;
        }
        
        inputIndex = inputIndexQueue_.front();
        inputBuffer = inputBufferQueue_.front();
        inputIndexQueue_.pop();
        inputBufferQueue_.pop();
    }
    
    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(inputBuffer);
    if (bufferAddr == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to get input buffer address");
        return -1;
    }
    
    int32_t bufferCapacity = OH_AVBuffer_GetCapacity(inputBuffer);
    if (totalSize > bufferCapacity) {
        OH_LOG_ERROR(LOG_APP, "Frame size %{public}d > buffer capacity %{public}d", totalSize, bufferCapacity);
        return -1;
    }
    
    // 直接将分段数据写入 AVBuffer
    CopySegmentsToBuffer(bufferAddr, segments, segmentCount);
    
    auto attr = MakeInputBufferAttr(totalSize, timestamp, frameType);
    OH_AVBuffer_SetBufferAttr(inputBuffer, &attr);
    
    RecordEnqueueTimestamp(timestamp);
    
    int32_t ret = OH_VideoDecoder_PushInputBuffer(decoder_, inputIndex);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to push input buffer: %{public}d", ret);
        return -1;
    }
    
    UpdateReceivedStats(totalSize, hostProcessingLatency);
    
    if (!firstFrameReceived_) {
        firstFrameReceived_ = true;
        OH_LOG_INFO(LOG_APP, "First video frame (scatter async): %{public}dx%{public}d", config_.width, config_.height);
    }
    
    return 0;
}

int VideoDecoder::SubmitDecodeUnit(const uint8_t* data, int size, 
                                    int frameNumber, VideoFrameType frameType,
                                    int64_t timestamp,
                                    uint16_t hostProcessingLatency) {
    // 将连续数据包装为单段 scatter-gather 提交，消除与 SubmitDecodeUnitScatter 的代码重复
    BufferSegment segment;
    segment.data = data;
    segment.length = size;
    return SubmitDecodeUnitScatter(&segment, 1, size, frameNumber, frameType, timestamp, hostProcessingLatency);
}

// 更新接收帧统计（提取公共逻辑）
void VideoDecoder::UpdateReceivedStats(int size, uint16_t hostProcessingLatency) {
    std::lock_guard<std::mutex> lock(statsMutex_);
    stats_.totalFrames++;
    stats_.totalBytesReceived += size;
    
    auto currentTimeMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    
    if (stats_.lastFpsCalculationTime == 0) {
        // 初始化统计基线 - 注意：这是在增加 totalFrames 之后
        // 两个 lastCount 都设为当前值，这样后续计算的 delta 是正确的增量
        stats_.lastFpsCalculationTime = currentTimeMs;
        stats_.lastFrameCount = stats_.totalFrames;  // 基线 = 当前总帧数 (已包含第一帧)
        stats_.lastDecodedFrameCount = stats_.decodedFrames;  // 基线 = 当前解码帧数 (可能为 0)
        stats_.lastRenderedFpsCalculationTime = currentTimeMs;
        stats_.lastBytesCount = stats_.totalBytesReceived;
        stats_.lastBitrateCalculationTime = currentTimeMs;
        stats_.sessionStartTime = currentTimeMs;  // 记录会话开始时间
    } else if (currentTimeMs - stats_.lastFpsCalculationTime >= kStatsUpdateIntervalMs) {
        int64_t elapsedMs = currentTimeMs - stats_.lastFpsCalculationTime;
        
        // 计算接收帧率 (RX)
        // framesDelta = 当前总帧数 - 上个窗口结束时的帧数
        uint64_t framesDelta = stats_.totalFrames - stats_.lastFrameCount;
        stats_.currentFps = static_cast<double>(framesDelta) * 1000.0 / static_cast<double>(elapsedMs);
        stats_.lastFrameCount = stats_.totalFrames;
        
        // 计算渲染帧率 (RD) - 使用相同的时间窗口
        // decodedDelta = 当前解码帧数 - 上个窗口结束时的解码帧数
        uint64_t decodedDelta = stats_.decodedFrames - stats_.lastDecodedFrameCount;
        stats_.renderedFps = static_cast<double>(decodedDelta) * 1000.0 / static_cast<double>(elapsedMs);
        stats_.lastDecodedFrameCount = stats_.decodedFrames;
        
        // 更新公共时间基线
        stats_.lastFpsCalculationTime = currentTimeMs;
        stats_.lastRenderedFpsCalculationTime = currentTimeMs;
        
        // 计算全局平均渲染帧率（会话级别）
        if (stats_.sessionStartTime > 0) {
            int64_t sessionMs = currentTimeMs - stats_.sessionStartTime;
            if (sessionMs > 0) {
                stats_.globalAvgFps = static_cast<double>(stats_.decodedFrames) * 1000.0 / static_cast<double>(sessionMs);
            }
        }
        
        // 计算比特率
        uint64_t bytesDelta = stats_.totalBytesReceived - stats_.lastBytesCount;
        stats_.currentBitrate = static_cast<double>(bytesDelta) * 8.0 * 1000.0 / static_cast<double>(elapsedMs);
        stats_.lastBytesCount = stats_.totalBytesReceived;
        stats_.lastBitrateCalculationTime = currentTimeMs;
        
        if (stats_.framesWithHostLatency > 0) {
            stats_.avgHostProcessingLatency = stats_.totalHostProcessingLatency / stats_.framesWithHostLatency;
        }
    }
    
    if (hostProcessingLatency > 0) {
        stats_.framesWithHostLatency++;
        stats_.totalHostProcessingLatency += static_cast<double>(hostProcessingLatency) / 10.0;
    }
}

VideoDecoderStats VideoDecoder::GetStats() const {
    std::lock_guard<std::mutex> lock(statsMutex_);
    return stats_;
}

// =============================================================================
// AVCodec 回调实现
// =============================================================================

void VideoDecoder::OnError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    OH_LOG_ERROR(LOG_APP, "Decoder error: %{public}d", errorCode);
}

void VideoDecoder::OnOutputFormatChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    int32_t width = 0, height = 0;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &width);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &height);
    OH_LOG_INFO(LOG_APP, "Output format changed: %{public}dx%{public}d", width, height);
}

void VideoDecoder::OnInputBufferAvailable(OH_AVCodec* codec, uint32_t index, 
                                           OH_AVBuffer* buffer, void* userData) {
    auto* self = static_cast<VideoDecoder*>(userData);
    if (self != nullptr) {
        std::lock_guard<std::mutex> lock(self->inputMutex_);
        self->inputIndexQueue_.push(index);
        self->inputBufferQueue_.push(buffer);
        self->inputCond_.notify_one();
    }
}

void VideoDecoder::OnOutputBufferAvailable(OH_AVCodec* codec, uint32_t index,
                                            OH_AVBuffer* buffer, void* userData) {
    auto* self = static_cast<VideoDecoder*>(userData);
    if (self == nullptr) return;
    
    // 获取输出数据信息
    OH_AVCodecBufferAttr attr;
    int64_t pts = 0;
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK) {
        pts = attr.pts;
    }
    
    // 获取入队时间
    int64_t enqueueTimeMs = 0;
    {
        std::lock_guard<std::mutex> lock(self->timestampMutex_);
        auto it = self->timestampToEnqueueTime_.find(pts);
        if (it != self->timestampToEnqueueTime_.end()) {
            enqueueTimeMs = it->second;
            self->timestampToEnqueueTime_.erase(it);
        }
    }
    
    // === L2 延迟恢复：异步模式基于延迟的帧跳过 ===
    // 当解码耗时过高时，跳过非关键帧以快速追赶
    if (enqueueTimeMs > 0) {
        auto currentTimeMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        int64_t instantDecodeTimeMs = currentTimeMs - enqueueTimeMs;
        double expectedFrameTimeMs = 1000.0 / self->config_.fps;
        bool isKeyframe = (attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) != 0;
        
        // 跳过条件：解码时间 > 3倍帧间隔 且 非关键帧 且 已过启动阶段
        if (instantDecodeTimeMs > expectedFrameTimeMs * kAsyncSkipThresholdMultiplier &&
            !isKeyframe && self->stats_.decodedFrames > kLatencyRecoveryMinFrames) {
            OH_VideoDecoder_FreeOutputBuffer(codec, index);
            {
                std::lock_guard<std::mutex> lock(self->statsMutex_);
                self->stats_.droppedFrames++;
                self->stats_.droppedByL2++;
            }
            self->lastInstantDecodeTimeMs_.store(instantDecodeTimeMs);
            return;
        }
        
        // === L5 异步渲染跳帧（高帧率自适应） ===
        // 当帧输出间隔过短（解码器批量输出）且延迟偏高时，跳过中间帧
        // 高帧率（>90fps）使用更宽松的阈值，避免 VPU 正常管线延迟被误判
        int64_t lastAsyncRender = self->lastAsyncRenderTimeMs_.load();
        if (lastAsyncRender > 0 && !isKeyframe &&
            self->stats_.decodedFrames > kLatencyRecoveryMinFrames) {
            int64_t outputInterval = currentTimeMs - lastAsyncRender;
            // 根据帧率选择阈值
            double latencyRatio = (self->config_.fps > kL5HighFpsThreshold)
                ? kL5LatencyRatio_HighFps : kL5LatencyRatio_Base;
            double intervalRatio = (self->config_.fps > kL5HighFpsThreshold)
                ? kL5IntervalRatio_HighFps : kL5IntervalRatio_Base;
            // 高帧率额外条件：绝对延迟下限（避免快速解码器误判）
            bool meetsAbsoluteFloor = (self->config_.fps > kL5HighFpsThreshold)
                ? (instantDecodeTimeMs >= kL5AbsoluteLatencyFloorMs) : true;
            if (outputInterval < static_cast<int64_t>(expectedFrameTimeMs * intervalRatio) &&
                instantDecodeTimeMs > static_cast<int64_t>(expectedFrameTimeMs * latencyRatio) &&
                meetsAbsoluteFloor) {
                OH_VideoDecoder_FreeOutputBuffer(codec, index);
                {
                    std::lock_guard<std::mutex> lock(self->statsMutex_);
                    self->stats_.droppedFrames++;
                    self->stats_.droppedByL5++;
                }
                // 高帧率：更新时间戳（避免级联丢帧过度）
                // 低帧率：不更新（级联丢帧确保 burst 中只保留最新帧，保持均匀帧间距）
                if (self->config_.fps > kL5HighFpsThreshold) {
                    self->lastAsyncRenderTimeMs_.store(currentTimeMs);
                }
                return;
            }
        }
    }
    
    // 更新异步渲染时间戳
    {
        auto renderNow = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        self->lastAsyncRenderTimeMs_.store(renderNow);
    }
    
    // 更新解码统计（复用统一函数）
    self->UpdateDecodedStats(pts, enqueueTimeMs, attr.flags);
    
    // 注意：异步模式不在此处做帧率限制
    // 原因：
    // 1. 阻塞解码器回调线程会导致内部 buffer 堆积
    // 2. VSync 模式已通过 RenderOutputBufferAtTime 控制呈现时间
    // 3. 低延迟模式应尽快渲染，由显示器 VSync 自然限制
    // 帧率限制通过 SetExpectedFrameRateRange 在系统层面实现
    
    // 渲染到 Surface
    // 检查是否使用异步渲染（通过 NativeRender）
    if (g_useAsyncRender) {
        NativeRender* render = NativeRender::GetInstance();
        if (render != nullptr && render->IsSurfaceReady()) {
            // 异步渲染：将帧提交到渲染队列
            render->SubmitFrame(codec, index, pts, enqueueTimeMs);
            return;
        }
    }
    
    // 同步渲染（fallback）
    // 检查是否启用 VSync 模式
    NativeRender* render = NativeRender::GetInstance();
    if (render != nullptr && render->IsVsyncEnabled() && pfn_RenderOutputBufferAtTime != nullptr) {
        // VSync 模式：使用 RenderOutputBufferAtTime 计算呈现时间
        int64_t presentTimeNs = render->CalculatePresentTime(pts);
        pfn_RenderOutputBufferAtTime(codec, index, presentTimeNs);
    } else {
        // 低延迟模式：直接渲染
        OH_VideoDecoder_RenderOutputBuffer(codec, index);
    }
}

// =============================================================================
// 同步模式解码实现
// =============================================================================

void VideoDecoder::UpdateDecodedStats(int64_t pts, int64_t enqueueTimeMs, uint32_t flags) {
    auto currentTimeMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    
    std::lock_guard<std::mutex> lock(statsMutex_);
    stats_.decodedFrames++;
    
    if (enqueueTimeMs > 0) {
        // === 精确解码时间：排除队列等待 ===
        // 当帧突发到达时，多帧几乎同时被推入解码器，后续帧必须等待前面的帧解码完成。
        // 传统方式 currentTime - enqueueTime 会把队列等待算入"解码时间"，造成虚高。
        // 修正方式：帧真正开始解码的时刻 = max(enqueueTime, 上一帧解码完成时刻)
        int64_t lastOutput = lastOutputTimeMs_.load();
        int64_t effectiveStartMs = (lastOutput > enqueueTimeMs) ? lastOutput : enqueueTimeMs;
        int64_t decodeTimeMs = currentTimeMs - effectiveStartMs;
        
        // 同时记录端到端管线延迟（含队列等待，用于 L3 延迟恢复判断）
        int64_t pipelineLatencyMs = currentTimeMs - enqueueTimeMs;
        
        // 更新上一帧输出时间
        lastOutputTimeMs_.store(currentTimeMs);
        
        if (decodeTimeMs >= 0 && decodeTimeMs < kMaxValidDecodeTimeMs) {
            bool isKeyframe = (flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) != 0;
            
            // 瞬时解码时间使用精确值（用户可见统计）
            lastInstantDecodeTimeMs_.store(decodeTimeMs);
            
            // 累积解码时间（用于串流结束后计算全局平均值）
            stats_.totalDecodeTimeMs += static_cast<double>(decodeTimeMs);
            stats_.validDecodeFrames++;
            
            if (stats_.decodedFrames == 1) {
                stats_.averageDecodeTimeMs = static_cast<double>(decodeTimeMs);
            } else {
                double alpha = isKeyframe ? kEmaAlphaKeyframe : kEmaAlphaNormal;
                stats_.averageDecodeTimeMs = alpha * decodeTimeMs + 
                    (1.0 - alpha) * stats_.averageDecodeTimeMs;
            }
            
            if (static_cast<double>(decodeTimeMs) > stats_.maxDecodeTimeMs) {
                stats_.maxDecodeTimeMs = static_cast<double>(decodeTimeMs);
            }
        }
        
        // L3 延迟恢复使用管线延迟（含排队时间），因为它反映真实的端到端堆积
        // 注意：lastInstantDecodeTimeMs_ 已更新为精确解码时间，L3 需要用原始管线延迟
        // L3 的 CheckLatencyRecovery 直接读 lastInstantDecodeTimeMs_，
        // 但这里改用精确值后，L3 阈值也需要相应降低——因为精确解码时间更小了
        // 为保持 L3 敏感度，额外检查管线延迟是否超过临界值
        if (pipelineLatencyMs > static_cast<int64_t>(
                std::max(1000.0 / config_.fps * kCriticalLatencyMultiplier, kCriticalLatencyMinMs)) &&
            stats_.decodedFrames > kLatencyRecoveryMinFrames) {
            // 管线延迟已超临界，但精确解码时间可能正常——标记为需要恢复
            if (!latencyRecoveryActive_.load()) {
                OH_LOG_WARN(LOG_APP, "Pipeline latency %{public}lldms critical (decode=%{public}lldms), flagging recovery",
                            static_cast<long long>(pipelineLatencyMs),
                            static_cast<long long>(decodeTimeMs));
            }
        }
    } else {
        // 无 enqueueTimeMs 时也更新 lastOutputTimeMs_
        lastOutputTimeMs_.store(currentTimeMs);
    }
}

// =============================================================================
// 解码器健康检查
// 使用 OH_VideoDecoder_IsValid 检测解码器是否进入不可恢复的错误状态
// 节流：每 500ms 最多检查一次，避免 API 调用开销
// =============================================================================

bool VideoDecoder::CheckDecoderValid() {
    if (decoder_ == nullptr) {
        return false;
    }
    
    auto nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    
    // 节流：每 500ms 检查一次
    constexpr int64_t kHealthCheckIntervalMs = 500;
    int64_t lastCheck = lastHealthCheckTimeMs_.load();
    if (nowMs - lastCheck < kHealthCheckIntervalMs) {
        return true;  // 在冷却期内，假定有效
    }
    lastHealthCheckTimeMs_.store(nowMs);
    
    bool isValid = false;
    OH_AVErrCode ret = OH_VideoDecoder_IsValid(decoder_, &isValid);
    
    if (ret != AV_ERR_OK || !isValid) {
        int errCount = consecutiveErrors_.fetch_add(1) + 1;
        OH_LOG_ERROR(LOG_APP, "Decoder health check FAILED: ret=%{public}d, valid=%{public}d, consecutive=%{public}d",
                     ret, isValid ? 1 : 0, errCount);
        return false;
    }
    
    // 健康检查通过，重置错误计数
    consecutiveErrors_.store(0);
    return true;
}

// =============================================================================
// L3 延迟恢复：临界延迟 IDR 请求
// 当瞬时解码耗时过高时，丢弃当前 P 帧并返回 DR_NEED_IDR
// moonlight-common-c 收到后会：1) 请求服务器发送 IDR  2) 丢弃后续 P 帧
// 配合输出端 drain-to-latest，可在最短时间内恢复到正常延迟
// =============================================================================

int VideoDecoder::CheckLatencyRecovery(VideoFrameType frameType, int size, uint16_t hostProcessingLatency) {
    bool isIFrame = (frameType == VideoFrameType::I_FRAME);
    
    // 收到 IDR 帧时重置恢复状态
    if (isIFrame && latencyRecoveryActive_.load()) {
        latencyRecoveryActive_.store(false);
        int64_t currentLatency = lastInstantDecodeTimeMs_.load();
        OH_LOG_INFO(LOG_APP, "IDR received, latency recovery complete (current decode=%{public}lldms)",
                    static_cast<long long>(currentLatency));
    }
    
    // 仅对 P 帧触发、且要过了启动阶段
    if (isIFrame) {
        return 0;
    }
    
    // 恢复模式已激活（由 L3 临界延迟或队列溢出触发），持续丢弃 P 帧直到 IDR 到达
    // 避免向解码器提交缺少参考帧的 P 帧，那样会导致输出损坏或卡顿
    if (latencyRecoveryActive_.load()) {
        UpdateReceivedStats(size, hostProcessingLatency);
        {
            std::lock_guard<std::mutex> lock(statsMutex_);
            stats_.droppedFrames++;
            stats_.droppedByL3++;
        }
        return -1;  // DR_NEED_IDR
    }
    
    int64_t lastDecodeTime = lastInstantDecodeTimeMs_.load();
    double expectedFrameTimeMs = 1000.0 / config_.fps;
    double criticalThresholdMs = std::max(expectedFrameTimeMs * kCriticalLatencyMultiplier, kCriticalLatencyMinMs);
    
    // 检查是否已过启动阶段（避免初始化时的误触发）
    uint64_t decodedFrames;
    {
        std::lock_guard<std::mutex> lock(statsMutex_);
        decodedFrames = stats_.decodedFrames;
    }
    if (decodedFrames < static_cast<uint64_t>(kLatencyRecoveryMinFrames)) {
        return 0;
    }
    
    // 临界延迟判断
    if (lastDecodeTime > static_cast<int64_t>(criticalThresholdMs)) {
        if (!latencyRecoveryActive_.exchange(true)) {
            OH_LOG_WARN(LOG_APP, "CRITICAL decode latency %{public}lldms > %.1fms threshold, requesting IDR recovery",
                        static_cast<long long>(lastDecodeTime), criticalThresholdMs);
        }
        
        // 更新接收统计（帧被接收但被丢弃）
        UpdateReceivedStats(size, hostProcessingLatency);
        {
            std::lock_guard<std::mutex> lock(statsMutex_);
            stats_.droppedFrames++;
            stats_.droppedByL3++;
        }
        return -1;  // DR_NEED_IDR
    }
    
    return 0;
}

void VideoDecoder::SyncDecodeLoop() {
    OH_LOG_INFO(LOG_APP, "Sync decode loop started (output-focused mode), decoder=%{public}p", static_cast<void*>(decoder_));
    
    // 设置线程优先级 + 绑定大核
    SetupDecodeThreadPriority();
    OH_LOG_INFO(LOG_APP, "Sync decode thread priority set, syncRunning=%{public}d, running=%{public}d", 
                syncDecodeRunning_ ? 1 : 0, running_ ? 1 : 0);
    
    int consecutiveOutputErrors = 0;
    const int maxConsecutiveErrors = 50;
    bool firstFrameRendered = false;
    int totalQueueInputSuccess = 0;  // 从后备队列提交的帧数
    int totalOutputSuccess = 0;
    
    // 冻结检测：基于墙钟时间而非循环次数
    // 原因：当队列非空且 timeout=0 时循环极快（<0.1ms/次），
    //       循环计数 100 次可能仅 1-5ms，远不足以判断冻结。
    auto lastOutputTime = std::chrono::steady_clock::now();
    constexpr int64_t kFreezeDetectionMs = 500;  // 500ms 无输出视为冻结
    
    while (syncDecodeRunning_ && running_) {
        // ====== 优化模式：输出优先 + 批量处理后备队列 ======
        // 大部分输入已在 SubmitDecodeUnit 中直接提交
        // 这里主要处理：1. 批量处理后备队列 2. 输出解码结果
        
        // 1. 批量处理后备队列（如果有的话）- 最多处理 4 帧
        int queueProcessed = 0;
        const int maxQueueBatch = 4;
        
        while (queueProcessed < maxQueueBatch) {
            bool hasQueuedFrame = false;
            {
                std::lock_guard<std::mutex> lock(pendingFrameMutex_);
                hasQueuedFrame = !pendingFrameQueue_.empty();
            }
            
            if (!hasQueuedFrame) {
                break;  // 队列已空
            }
            
            // 有后备帧，尝试提交（注意：不持有锁时调用，避免死锁）
            int inputResult = SyncProcessInput(kSyncLoopQueryTimeoutUs);
            if (inputResult > 0) {
                totalQueueInputSuccess++;
                queueProcessed++;
            } else if (inputResult == 0) {
                // 解码器输入满了，先处理输出
                break;
            } else {
                // 错误，退出批量处理
                break;
            }
        }
        
        // 2. 处理输出 - 核心任务（优先级高于输入）
        int outputResult = SyncProcessOutput(kSyncLoopQueryTimeoutUs);
        if (outputResult > 0) {
            totalOutputSuccess++;
            consecutiveOutputErrors = 0;
            lastOutputTime = std::chrono::steady_clock::now();
            if (!firstFrameRendered) {
                firstFrameRendered = true;
                OH_LOG_INFO(LOG_APP, "Sync decode: first frame rendered!");
            }
        } else if (outputResult < 0) {
            consecutiveOutputErrors++;
        } else {
            // outputResult == 0, 无输出帧
            
            // 冻结检测（基于墙钟时间）：解码器可能进入了无产出的"僵死"状态
            // 此时音频继续播放但画面冻结，需要主动恢复
            auto timeSinceLastOutput = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - lastOutputTime).count();
            if (firstFrameRendered && timeSinceLastOutput >= kFreezeDetectionMs) {
                OH_LOG_WARN(LOG_APP, "Sync decode: no output for %{public}lldms, flushing decoder + requesting IDR",
                            static_cast<long long>(timeSinceLastOutput));
                
                // Flush 清空解码器内部缓冲 + 请求 IDR 关键帧
                // 使用 unique_lock 独占解码器操作
                {
                    std::unique_lock<std::shared_mutex> codecLock(codecMutex_);
                    OH_AVErrCode flushRet = OH_VideoDecoder_Flush(decoder_);
                    if (flushRet == AV_ERR_OK) {
                        // Flush 后必须重新 Start
                        OH_AVErrCode startRet = OH_VideoDecoder_Start(decoder_);
                        if (startRet == AV_ERR_OK) {
                            OH_LOG_INFO(LOG_APP, "Sync decode: decoder flushed and restarted, requesting IDR");
                        } else {
                            OH_LOG_ERROR(LOG_APP, "Sync decode: restart after flush failed: %{public}d", startRet);
                        }
                    } else {
                        OH_LOG_ERROR(LOG_APP, "Sync decode: flush failed: %{public}d", flushRet);
                    }
                }
                
                // 清空软件队列
                {
                    std::lock_guard<std::mutex> lock(pendingFrameMutex_);
                    while (!pendingFrameQueue_.empty()) pendingFrameQueue_.pop();
                }
                
                // 请求 IDR 关键帧
                LiRequestIdrFrame();
                
                lastOutputTime = std::chrono::steady_clock::now();
                consecutiveOutputErrors = 0;
            }
            
            // 短暂让出 CPU
            // 主路径：直接提交成功后 pendingFrameCond_ 会被 notify，立即唤醒
            // 超时只是兜底，不影响正常延迟
            std::unique_lock<std::mutex> lock(pendingFrameMutex_);
            if (pendingFrameQueue_.empty() && syncDecodeRunning_) {
                // 队列空：等待 notify 或超时（2ms 兜底轮询，确保输出不被遗漏）
                pendingFrameCond_.wait_for(lock, std::chrono::milliseconds(2));
            } else if (syncDecodeRunning_) {
                // 队列非空但解码器还没输出：短暂休眠避免空轮询烧 CPU
                // 1ms 足够让解码器推进，远短于帧间隔
                lock.unlock();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
        
        // 统计日志（每秒一次）
        static thread_local auto lastLogTime = std::chrono::steady_clock::now();
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastLogTime).count() >= 1000) {
            std::lock_guard<std::mutex> lock(pendingFrameMutex_);
            OH_LOG_INFO(LOG_APP, "Sync stats: queueIn=%{public}d, output=%{public}d, pending=%{public}zu", 
                        totalQueueInputSuccess, totalOutputSuccess, pendingFrameQueue_.size());
            lastLogTime = now;
        }
        
        // 连续输出错误检查
        if (consecutiveOutputErrors >= maxConsecutiveErrors) {
            OH_LOG_ERROR(LOG_APP, "Sync decode: too many output errors (%{public}d), exiting", 
                         consecutiveOutputErrors);
            break;
        }
        
        // 解码器健康检查（节流在 CheckDecoderValid 内部，每 500ms 一次）
        if (consecutiveOutputErrors > 5 && !CheckDecoderValid()) {
            OH_LOG_ERROR(LOG_APP, "Sync decode: decoder invalid after %{public}d errors, exiting loop",
                         consecutiveOutputErrors);
            break;
        }
    }
    
    OH_LOG_INFO(LOG_APP, "Sync decode loop exited (rendered=%{public}d, queueIn=%{public}d, output=%{public}d)", 
                firstFrameRendered, totalQueueInputSuccess, totalOutputSuccess);
}

// 返回值: 1=成功, 0=正常等待/无数据, -1=API错误
int VideoDecoder::SyncProcessInput(int64_t timeoutUs) {
    if (decoder_ == nullptr || !syncDecodeRunning_) {
        return 0;
    }
    
    // 先检查队列是否有帧（不取出）
    {
        std::lock_guard<std::mutex> lock(pendingFrameMutex_);
        if (pendingFrameQueue_.empty()) {
            return 0;  // 没有帧要处理
        }
    }
    
    // 参考官方文档：使用 shared_lock 保护解码器操作，防止 Flush/Stop 期间访问
    std::shared_lock<std::shared_mutex> codecLock(codecMutex_);
    
    // 有帧要处理，先查询输入 buffer
    uint32_t inputIndex = 0;
    OH_AVErrCode ret = pfn_QueryInputBuffer(decoder_, &inputIndex, timeoutUs);
    
    if (ret == AV_ERR_TRY_AGAIN_LATER) {
        // 没有可用的输入 buffer，下次再试
        return 0;  // 正常等待
    } else if (ret == AV_ERR_UNSUPPORT) {
        OH_LOG_ERROR(LOG_APP, "Sync QueryInputBuffer: AV_ERR_UNSUPPORT - sync mode not supported!");
        syncDecodeRunning_ = false;
        return -1;
    } else if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Sync QueryInputBuffer failed: %{public}d (0x%{public}x)", ret, ret);
        return -1;  // API 错误
    }
    
    // 获得了输入 buffer，现在取出帧
    PendingFrame frame;
    {
        std::lock_guard<std::mutex> lock(pendingFrameMutex_);
        if (pendingFrameQueue_.empty()) {
            // 理论上不应该发生，但以防万一
            return 0;
        }
        frame = std::move(pendingFrameQueue_.front());
        pendingFrameQueue_.pop();
    }
    
    // 成功获得输入 buffer，继续处理帧
    static bool firstInputLog = true;
    if (firstInputLog) {
        OH_LOG_INFO(LOG_APP, "SyncInput: first frame submitted to decoder, size=%{public}zu", frame.data.size());
        firstInputLog = false;
    }
    
    // 获取输入 buffer（使用已获得的 index）
    OH_AVBuffer* inputBuffer = pfn_GetInputBuffer(decoder_, inputIndex);
    if (inputBuffer == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Sync GetInputBuffer failed");
        return -1;  // API 错误
    }
    
    // 填充数据
    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(inputBuffer);
    if (bufferAddr == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Sync: failed to get buffer address");
        return -1;  // API 错误
    }
    
    int32_t capacity = OH_AVBuffer_GetCapacity(inputBuffer);
    if (static_cast<int>(frame.data.size()) > capacity) {
        OH_LOG_ERROR(LOG_APP, "Sync: frame size %{public}zu > capacity %{public}d", 
                     frame.data.size(), capacity);
        return -1;  // 数据错误
    }
    
    memcpy(bufferAddr, frame.data.data(), frame.data.size());
    
    // 设置 buffer 属性
    auto attr = MakeInputBufferAttr(static_cast<int32_t>(frame.data.size()), frame.timestamp, frame.frameType);
    OH_AVBuffer_SetBufferAttr(inputBuffer, &attr);
    
    // 记录入队时间
    RecordEnqueueTimestamp(frame.timestamp);
    
    // 提交输入 buffer
    ret = OH_VideoDecoder_PushInputBuffer(decoder_, inputIndex);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Sync PushInputBuffer failed: %{public}d", ret);
        return -1;  // API 错误
    }
    
    return 1;  // 成功处理了一帧
}

int VideoDecoder::SyncProcessOutput(int64_t timeoutUs) {
    if (decoder_ == nullptr || !syncDecodeRunning_) {
        return 0;  // 正常情况
    }
    
    // 参考官方文档：使用 shared_lock 保护解码器操作
    std::shared_lock<std::shared_mutex> codecLock(codecMutex_);
    
    // 使用同步 API 获取输出 buffer
    uint32_t outputIndex = 0;
    OH_AVErrCode ret = pfn_QueryOutputBuffer(decoder_, &outputIndex, timeoutUs);
    
    if (ret == AV_ERR_TRY_AGAIN_LATER) {
        // 没有输出帧可用，正常情况
        return 0;  // 正常等待
    } else if (ret == AV_ERR_STREAM_CHANGED) {
        // 流参数变化，获取新的输出格式
        OH_AVFormat* format = OH_VideoDecoder_GetOutputDescription(decoder_);
        if (format != nullptr) {
            int32_t width = 0, height = 0;
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_WIDTH, &width);
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_HEIGHT, &height);
            OH_LOG_INFO(LOG_APP, "Sync: output format changed to %{public}dx%{public}d", width, height);
            OH_AVFormat_Destroy(format);
        }
        return 0;  // 流变化不算帧输出，继续处理
    } else if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Sync QueryOutputBuffer failed: %{public}d", ret);
        return -1;  // API 错误
    }
    
    // 获取输出 buffer
    OH_AVBuffer* outputBuffer = pfn_GetOutputBuffer(decoder_, outputIndex);
    if (outputBuffer == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Sync GetOutputBuffer failed");
        return -1;  // API 错误
    }
    
    // 获取 buffer 属性
    OH_AVCodecBufferAttr attr;
    if (OH_AVBuffer_GetBufferAttr(outputBuffer, &attr) != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "Sync: failed to get buffer attr");
        memset(&attr, 0, sizeof(attr));
    }
    
    // 检查 EOS
    if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
        OH_LOG_INFO(LOG_APP, "Sync: received EOS");
        OH_VideoDecoder_FreeOutputBuffer(decoder_, outputIndex);
        return 0;  // EOS 不是错误
    }
    
    // ================================================================
    // L1: 始终渲染最新帧（drain-to-latest）
    //
    // 串流追求最低输入延迟，任何堆积帧都应被丢弃：
    //   1 帧可用 → 正常渲染（无堆积）
    //   2+ 帧可用 → 仅渲染最新帧，丢弃所有旧帧
    //
    // 代价：IDR 慢解码时 Rd FPS 瞬时下降，但端到端延迟始终最低
    // ================================================================
    
    // 收集所有可用的输出帧
    struct QueuedFrame {
        uint32_t index;
        OH_AVBuffer* buffer;
        OH_AVCodecBufferAttr attr;
    };
    std::vector<QueuedFrame> outputFrames;
    outputFrames.push_back({outputIndex, outputBuffer, attr});
    
    while (running_ && syncDecodeRunning_) {
        uint32_t nextOutputIndex = 0;
        OH_AVErrCode nextRet = pfn_QueryOutputBuffer(decoder_, &nextOutputIndex, 0);
        if (nextRet != AV_ERR_OK) {
            break;  // 没有更多可用帧
        }
        
        OH_AVBuffer* nextBuffer = pfn_GetOutputBuffer(decoder_, nextOutputIndex);
        if (nextBuffer == nullptr) {
            break;
        }
        
        OH_AVCodecBufferAttr nextAttr;
        if (OH_AVBuffer_GetBufferAttr(nextBuffer, &nextAttr) != AV_ERR_OK) {
            break;
        }
        
        // EOS 帧不参与收集
        if (nextAttr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
            OH_VideoDecoder_FreeOutputBuffer(decoder_, nextOutputIndex);
            break;
        }
        
        outputFrames.push_back({nextOutputIndex, nextBuffer, nextAttr});
    }
    
    int totalFrames = static_cast<int>(outputFrames.size());
    
    // 丢弃所有旧帧，仅保留最新帧
    if (totalFrames > 1) {
        int drainedCount = totalFrames - 1;
        for (int i = 0; i < drainedCount; i++) {
            auto& frame = outputFrames[i];
            {
                std::lock_guard<std::mutex> lock(timestampMutex_);
                timestampToEnqueueTime_.erase(frame.attr.pts);
            }
            OH_VideoDecoder_FreeOutputBuffer(decoder_, frame.index);
        }
        {
            std::lock_guard<std::mutex> lock(statsMutex_);
            stats_.droppedFrames += drainedCount;
            stats_.droppedByL1 += drainedCount;
        }
        OH_LOG_INFO(LOG_APP, "L1 drain-to-latest: skipped %{public}d frames (total=%{public}d)",
                    drainedCount, totalFrames);
    }
    
    // 渲染最新帧
    auto& latestFrame = outputFrames.back();
    int64_t pts = latestFrame.attr.pts;
    
    // 获取入队时间以计算解码延迟
    int64_t enqueueTimeMs = 0;
    {
        std::lock_guard<std::mutex> lock(timestampMutex_);
        auto it = timestampToEnqueueTime_.find(pts);
        if (it != timestampToEnqueueTime_.end()) {
            enqueueTimeMs = it->second;
            timestampToEnqueueTime_.erase(it);
        }
    }
    
    // 更新解码统计
    UpdateDecodedStats(pts, enqueueTimeMs, latestFrame.attr.flags);
    
    // 渲染帧 - 同步模式：立即渲染确保最低延迟
    ret = OH_VideoDecoder_RenderOutputBuffer(decoder_, latestFrame.index);
    if (ret != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "Sync: render failed (%{public}d), freeing buffer", ret);
        OH_VideoDecoder_FreeOutputBuffer(decoder_, latestFrame.index);
        return 0;
    }
    
    return 1;  // 成功渲染一帧
}

// =============================================================================
// 全局简化接口
// =============================================================================

namespace {
    VideoDecoder* g_videoDecoder = nullptr;
    std::mutex g_videoDecoderMutex;
    OHNativeWindow* g_savedWindow = nullptr;
    int g_savedVideoFormat = 0;
    int g_savedWidth = 0;
    int g_savedHeight = 0;
    double g_savedFps = 0.0;  // 支持小数帧率（如 59.94）
    // HDR 配置
    bool g_enableHdr = false;
    HdrType g_hdrType = HdrType::SDR;
    int g_colorSpace = 1;   // REC_709
    int g_colorRange = 0;   // Limited
    int g_bufferCount = 0;  // 系统默认
    // 同步模式配置
    bool g_syncMode = false;  // 默认异步模式
    // VRR (Variable Refresh Rate) 配置
    // 启用后解码器输出将适配可变刷新率显示
    // 注意：VRR 可能会丢帧以匹配屏幕刷新率，主要用于节能
    bool g_enableVrr = false;  // 默认禁用
}

namespace VideoDecoderInstance {

// 查询指定 MIME 类型解码器的硬件能力
// 返回: OH_AVCapability* (系统管理，无需释放), 或 nullptr 不支持
static OH_AVCapability* GetHWDecoderCapability(const char* mimeType) {
    // 优先查询硬件解码器
    OH_AVCapability* cap = OH_AVCodec_GetCapabilityByCategory(mimeType, false, HARDWARE);
    if (cap != nullptr && OH_AVCapability_IsHardware(cap)) {
        return cap;
    }
    // 回退到系统推荐解码器
    return OH_AVCodec_GetCapability(mimeType, false);
}

// 检测编解码器支持
bool IsCodecSupported(VideoCodecType codec) {
    const char* mimeType = nullptr;
    switch (codec) {
        case VideoCodecType::H264:
            mimeType = OH_AVCODEC_MIMETYPE_VIDEO_AVC;
            break;
        case VideoCodecType::HEVC:
            mimeType = OH_AVCODEC_MIMETYPE_VIDEO_HEVC;
            break;
        case VideoCodecType::AV1:
            return false;  // HarmonyOS 不支持 AV1
        default:
            return false;
    }
    
    return GetHWDecoderCapability(mimeType) != nullptr;
}

// 获取解码器能力（使用 OH_AVCapability API 查询真实硬件参数）
DecoderCapabilities GetCapabilities() {
    DecoderCapabilities caps = {};
    
    caps.supportsH264 = IsCodecSupported(VideoCodecType::H264);
    caps.supportsHEVC = IsCodecSupported(VideoCodecType::HEVC);
    caps.supportsAV1 = IsCodecSupported(VideoCodecType::AV1);
    
    // 查询实际硬件支持的最大分辨率和帧率
    // 优先用 HEVC（通常上限更高），回退 H264
    const char* probeMime = caps.supportsHEVC ? OH_AVCODEC_MIMETYPE_VIDEO_HEVC : OH_AVCODEC_MIMETYPE_VIDEO_AVC;
    OH_AVCapability* cap = GetHWDecoderCapability(probeMime);
    
    if (cap != nullptr) {
        const char* codecName = OH_AVCapability_GetName(cap);
        bool isHW = OH_AVCapability_IsHardware(cap);
        
        OH_AVRange widthRange = {0, 0};
        OH_AVRange heightRange = {0, 0};
        OH_AVRange fpsRange = {0, 0};
        
        OH_AVCapability_GetVideoWidthRange(cap, &widthRange);
        OH_AVCapability_GetVideoHeightRange(cap, &heightRange);
        OH_AVCapability_GetVideoFrameRateRange(cap, &fpsRange);
        
        caps.maxWidth = widthRange.maxVal > 0 ? widthRange.maxVal : 3840;
        caps.maxHeight = heightRange.maxVal > 0 ? heightRange.maxVal : 2160;
        caps.maxFps = fpsRange.maxVal > 0 ? fpsRange.maxVal : 60;
        
        // 检查是否真正支持低延迟特性（API 12+）
        caps.supportsLowLatency = OH_AVCapability_IsFeatureSupported(cap, VIDEO_LOW_LATENCY);
        
        // 查询具体分辨率+帧率组合的支持情况
        // 用于在设置页面精准提示用户
        caps.supports4K60 = OH_AVCapability_AreVideoSizeAndFrameRateSupported(cap, 3840, 2160, 60);
        caps.supports4K120 = OH_AVCapability_AreVideoSizeAndFrameRateSupported(cap, 3840, 2160, 120);
        caps.supports1080p120 = OH_AVCapability_AreVideoSizeAndFrameRateSupported(cap, 1920, 1080, 120);
        
        // 获取最大实例数（用于判断是否支持多解码器）
        caps.maxInstances = OH_AVCapability_GetMaxSupportedInstances(cap);
        
        OH_LOG_INFO(LOG_APP, "Decoder caps [%{public}s, HW=%{public}d]: "
                    "maxRes=%{public}dx%{public}d, maxFps=%{public}d, "
                    "lowLatency=%{public}d, 4K60=%{public}d, 4K120=%{public}d, 1080p120=%{public}d, "
                    "maxInstances=%{public}d",
                    codecName ? codecName : "unknown", isHW ? 1 : 0,
                    caps.maxWidth, caps.maxHeight, caps.maxFps,
                    caps.supportsLowLatency ? 1 : 0,
                    caps.supports4K60 ? 1 : 0, caps.supports4K120 ? 1 : 0,
                    caps.supports1080p120 ? 1 : 0,
                    caps.maxInstances);
    } else {
        // 无法查询能力，使用保守默认值
        caps.maxWidth = 3840;
        caps.maxHeight = 2160;
        caps.maxFps = 60;
        caps.supportsLowLatency = false;
        caps.supports4K60 = false;
        caps.supports4K120 = false;
        caps.supports1080p120 = false;
        caps.maxInstances = 1;
        
        OH_LOG_WARN(LOG_APP, "Failed to query decoder capability, using defaults");
    }
    
    OH_LOG_INFO(LOG_APP, "Decoder caps: H264=%{public}d, HEVC=%{public}d, AV1=%{public}d, maxRes=%{public}dx%{public}d@%{public}d",
                caps.supportsH264, caps.supportsHEVC, caps.supportsAV1,
                caps.maxWidth, caps.maxHeight, caps.maxFps);
    
    return caps;
}

bool Init(OHNativeWindow* window) {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    g_savedWindow = window;
    
    if (g_videoDecoder != nullptr) {
        delete g_videoDecoder;
        g_videoDecoder = nullptr;
    }
    
    return true;
}

// 内部版本，不加锁
int SetupInternal(int videoFormat, int width, int height, double fps) {
    g_savedVideoFormat = videoFormat;
    g_savedWidth = width;
    g_savedHeight = height;
    g_savedFps = fps;
    
    // 设置 NativeRender 的帧率配置（用于 SetExpectedFrameRateRange 优化高帧率显示）
    NativeRender* render = NativeRender::GetInstance();
    if (render != nullptr) {
        render->SetConfiguredFps(static_cast<int>(std::round(fps)));  // 四舍五入到最近整数
        OH_LOG_INFO(LOG_APP, "VideoDecoder: NativeRender configured fps set to %.2f (rounded to %d)", 
                    fps, static_cast<int>(std::round(fps)));
    }
    
    return 0;
}

int Setup(int videoFormat, int width, int height, double fps) {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    return SetupInternal(videoFormat, width, height, fps);
}

int Init(int videoFormat, int width, int height, double fps, void* window) {
    // 兼容旧调用方式
    if (window != nullptr) {
        g_savedWindow = static_cast<OHNativeWindow*>(window);
    }
    return Setup(videoFormat, width, height, fps);
}

// 辅助函数：转换帧类型 + 计算时间戳（全局包装器共用）
static void PrepareFrameSubmitParams(int frameType, int frameNumber,
                                      VideoFrameType& outType, int64_t& outTimestamp) {
    // FRAME_TYPE_IDR = 1, FRAME_TYPE_I = 2
    outType = (frameType == 1 || frameType == 2) ? VideoFrameType::I_FRAME : VideoFrameType::P_FRAME;
    double fps = (g_savedFps > 0) ? g_savedFps : 60.0;
    outTimestamp = static_cast<int64_t>(static_cast<double>(frameNumber) * 1000000.0 / fps);
}

int SubmitDecodeUnit(const uint8_t* data, int size, int frameNumber, int frameType, uint16_t hostProcessingLatency) {
    if (g_videoDecoder == nullptr) {
        return -1;
    }
    
    VideoFrameType type;
    int64_t timestamp;
    PrepareFrameSubmitParams(frameType, frameNumber, type, timestamp);
    
    return g_videoDecoder->SubmitDecodeUnit(data, size, frameNumber, type, timestamp, hostProcessingLatency);
}

int SubmitDecodeUnitScatter(const BufferSegment* segments, int segmentCount,
                            int totalSize, int frameNumber, int frameType,
                            uint16_t hostProcessingLatency) {
    if (g_videoDecoder == nullptr) {
        return -1;
    }
    
    VideoFrameType type;
    int64_t timestamp;
    PrepareFrameSubmitParams(frameType, frameNumber, type, timestamp);
    
    return g_videoDecoder->SubmitDecodeUnitScatter(segments, segmentCount, totalSize,
                                                    frameNumber, type, timestamp, hostProcessingLatency);
}

int Start() {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    if (g_savedWindow == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Start: no window set");
        return -1;
    }
    
    if (g_savedWidth == 0 || g_savedHeight == 0) {
        OH_LOG_ERROR(LOG_APP, "Start: invalid params %{public}dx%{public}d", g_savedWidth, g_savedHeight);
        return -1;
    }
    
    // 清理旧解码器
    if (g_videoDecoder != nullptr) {
        delete g_videoDecoder;
        g_videoDecoder = nullptr;
    }
    
    g_videoDecoder = new VideoDecoder();
    if (g_videoDecoder == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Start: failed to allocate VideoDecoder");
        return -1;
    }
    
    // 配置解码器
    VideoDecoderConfig config;
    config.width = g_savedWidth;
    config.height = g_savedHeight;
    config.fps = g_savedFps;
    config.enableHdr = g_enableHdr;
    config.hdrType = g_hdrType;
    config.bufferCount = g_bufferCount;
    config.decoderMode = g_syncMode ? DecoderMode::SYNC : DecoderMode::ASYNC;
    config.enableVrr = g_enableVrr;
    
    // 颜色空间
    switch (g_colorSpace) {
        case 0:  config.colorSpace = ColorSpace::REC_601; break;
        case 2:  config.colorSpace = ColorSpace::REC_2020; break;
        default: config.colorSpace = ColorSpace::REC_709; break;
    }
    config.colorRange = (g_colorRange == 1) ? ColorRange::FULL : ColorRange::LIMITED;
    
    // 编解码器类型
    if (g_savedVideoFormat & VIDEO_FORMAT_MASK_AV1) {
        config.codec = VideoCodecType::AV1;
    } else if (g_savedVideoFormat & VIDEO_FORMAT_MASK_H265) {
        config.codec = VideoCodecType::HEVC;
    } else {
        config.codec = VideoCodecType::H264;
    }
    
    OH_LOG_INFO(LOG_APP, "Starting decoder: %{public}dx%{public}d, HDR=%{public}d, hdrType=%{public}d",
                config.width, config.height, g_enableHdr ? 1 : 0, static_cast<int>(g_hdrType));
    
    // 初始化解码器
    int ret = g_videoDecoder->Init(config, g_savedWindow);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "Decoder Init failed: %{public}d", ret);
        delete g_videoDecoder;
        g_videoDecoder = nullptr;
        return ret;
    }
    
    // 启动解码器
    ret = g_videoDecoder->Start();
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "Decoder Start failed: %{public}d", ret);
        delete g_videoDecoder;
        g_videoDecoder = nullptr;
        return ret;
    }
    
    return 0;
}

int Stop() {
    if (g_videoDecoder == nullptr) {
        return -1;
    }
    return g_videoDecoder->Stop();
}

void Cleanup() {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    if (g_videoDecoder != nullptr) {
        delete g_videoDecoder;
        g_videoDecoder = nullptr;
    }
    
    // 保留 HDR 配置，整个串流会话期间不变
}

void SetHdrConfig(bool enableHdr, int hdrType, int colorSpace, int colorRange) {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    OH_LOG_INFO(LOG_APP, "SetHdrConfig: HDR=%{public}d, type=%{public}d, cs=%{public}d, cr=%{public}d",
                enableHdr ? 1 : 0, hdrType, colorSpace, colorRange);
    
    g_enableHdr = enableHdr;
    switch (hdrType) {
        case 1:  g_hdrType = HdrType::HDR10; break;
        case 2:  g_hdrType = HdrType::HLG; break;
        default: g_hdrType = HdrType::SDR; break;
    }
    g_colorSpace = colorSpace;
    g_colorRange = colorRange;
}

void ResetHdrConfig() {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    g_enableHdr = false;
    g_hdrType = HdrType::SDR;
    g_colorSpace = 1;   // REC_709
    g_colorRange = 0;   // LIMITED
}

void SetBufferCount(int count) {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    // 限制有效范围: 0 (系统默认) 或 2-8
    if (count < 0) count = 0;
    if (count == 1) count = kMinBufferCount;
    if (count > kMaxBufferCount) count = kMaxBufferCount;
    
    g_bufferCount = count;
}

void SetSyncMode(bool syncMode) {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    g_syncMode = syncMode;
    OH_LOG_INFO(LOG_APP, "SetSyncMode: %{public}s", syncMode ? "SYNC (low latency)" : "ASYNC (default)");
}

void SetVrrEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    g_enableVrr = enabled;
    OH_LOG_INFO(LOG_APP, "SetVrrEnabled: %{public}s", enabled ? "ON" : "OFF");
}

void SetPreciseFps(double fps) {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    g_savedFps = fps;
    OH_LOG_INFO(LOG_APP, "SetPreciseFps: %.2f FPS", fps);
}

bool IsSyncMode() {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    return g_syncMode;
}

VideoDecoderStats GetStats() {
    if (g_videoDecoder != nullptr) {
        return g_videoDecoder->GetStats();
    }
    return VideoDecoderStats{};
}

void Resume() {
    OH_LOG_INFO(LOG_APP, "VideoDecoderInstance::Resume - 从后台恢复解码器");
    
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    if (g_videoDecoder == nullptr) {
        OH_LOG_WARN(LOG_APP, "Resume: 解码器实例不存在");
        return;
    }
    
    // 后台期间解码器可能处于以下状态之一：
    // 1. 仍在运行但输出 Surface 被冻结 → 输入缓冲区可能耗尽
    // 2. 遇到错误停止 → 需要重启
    // 3. 正常运行但画面卡在最后一帧
    //
    // 统一处理：Flush 清空内部队列 + 重启编解码器 + 请求 IDR 关键帧
    int ret = g_videoDecoder->Flush();
    if (ret == 0) {
        OH_LOG_INFO(LOG_APP, "Resume: 解码器 Flush 成功，请求 IDR 关键帧");
        // 请求服务器发送新的关键帧，让解码器从干净状态开始
        LiRequestIdrFrame();
    } else {
        OH_LOG_WARN(LOG_APP, "Resume: Flush 失败 (ret=%{public}d)，尝试 Start", ret);
        // Flush 失败（可能解码器已停止），尝试直接 Start
        int startRet = g_videoDecoder->Start();
        if (startRet == 0) {
            OH_LOG_INFO(LOG_APP, "Resume: 解码器 Start 成功，请求 IDR 关键帧");
            LiRequestIdrFrame();
        } else {
            OH_LOG_ERROR(LOG_APP, "Resume: 解码器恢复失败 (start ret=%{public}d)", startRet);
        }
    }
}

} // namespace VideoDecoderInstance
