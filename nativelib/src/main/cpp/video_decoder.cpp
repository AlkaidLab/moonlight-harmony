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
#include "hdr_vivid_metadata_scanner.h"
#include "native_render.h"
#include "gl_post_processor.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <time.h>
#include <dlfcn.h>
#include <sched.h>
#include <unistd.h>
#include <fstream>
#include <mutex>
#include <vector>
#include <qos/qos.h>

// moonlight-common-c API (用于 IDR 帧请求)
extern "C" {
    void LiRequestIdrFrame(void);
}

#define LOG_TAG "VideoDecoder"

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
typedef OH_AVBuffer* (*PFN_OH_VideoDecoder_GetInputBuffer)(OH_AVCodec*, uint32_t);
typedef OH_AVBuffer* (*PFN_OH_VideoDecoder_GetOutputBuffer)(OH_AVCodec*, uint32_t);

static PFN_OH_VideoDecoder_QueryInputBuffer  pfn_QueryInputBuffer = nullptr;
static PFN_OH_VideoDecoder_QueryOutputBuffer pfn_QueryOutputBuffer = nullptr;
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

// AV1 MIME (API 23+) must be loaded dynamically so older runtimes can still load this module.
static const char* key_mime_video_av1 = nullptr;
static std::once_flag g_codecMimeKeysOnce;

static void LoadCodecMimeKeys() {
    const char** pAv1 = (const char**)dlsym(RTLD_DEFAULT, "OH_AVCODEC_MIMETYPE_VIDEO_AV1");
    if (pAv1 != nullptr) key_mime_video_av1 = *pAv1;

    if (pAv1 == nullptr) {
        static void* codecbaseHandle = dlopen("libnative_media_codecbase.so", RTLD_NOW);
        if (codecbaseHandle != nullptr) {
            pAv1 = (const char**)dlsym(codecbaseHandle, "OH_AVCODEC_MIMETYPE_VIDEO_AV1");
            if (pAv1 != nullptr) key_mime_video_av1 = *pAv1;
        }
    }

    OH_LOG_INFO(LOG_APP, "Codec MIME availability: AV1=%{public}s",
                key_mime_video_av1 ? key_mime_video_av1 : "N/A");
}

static const char* TryLoadAv1MimeType() {
    std::call_once(g_codecMimeKeysOnce, LoadCodecMimeKeys);
    return key_mime_video_av1;
}

namespace {
    Smpte2086Metadata g_hdrStaticMetadata = {};
    bool g_hasHdrStaticMetadata = false;
    std::mutex g_hdrStaticMetadataMutex;
}

static OH_NativeBuffer_StaticMetadata BuildDefaultHdrStaticMetadata() {
    OH_NativeBuffer_StaticMetadata staticMetadata = {};
    staticMetadata.smpte2086.displayPrimaryRed   = {0.708f, 0.292f};
    staticMetadata.smpte2086.displayPrimaryGreen = {0.170f, 0.797f};
    staticMetadata.smpte2086.displayPrimaryBlue  = {0.131f, 0.046f};
    staticMetadata.smpte2086.whitePoint          = {0.3127f, 0.3290f};
    staticMetadata.smpte2086.maxLuminance        = 1000.0f;
    staticMetadata.smpte2086.minLuminance        = 0.001f;
    staticMetadata.cta861.maxContentLightLevel       = 1000.0f;
    staticMetadata.cta861.maxFrameAverageLightLevel  = 400.0f;
    return staticMetadata;
}

static OH_NativeBuffer_StaticMetadata ToNativeHdrStaticMetadata(const Smpte2086Metadata& metadata) {
    OH_NativeBuffer_StaticMetadata staticMetadata = {};
    staticMetadata.smpte2086.displayPrimaryRed   = {metadata.redX, metadata.redY};
    staticMetadata.smpte2086.displayPrimaryGreen = {metadata.greenX, metadata.greenY};
    staticMetadata.smpte2086.displayPrimaryBlue  = {metadata.blueX, metadata.blueY};
    staticMetadata.smpte2086.whitePoint          = {metadata.whiteX, metadata.whiteY};
    staticMetadata.smpte2086.maxLuminance        = metadata.maxLuminance;
    staticMetadata.smpte2086.minLuminance        = metadata.minLuminance;
    staticMetadata.cta861.maxContentLightLevel      = metadata.maxContentLightLevel;
    staticMetadata.cta861.maxFrameAverageLightLevel = metadata.maxFrameAverageLightLevel;
    return staticMetadata;
}

// 查询指定 MIME 类型解码器的硬件能力
// 返回: OH_AVCapability* (系统管理，无需释放), 或 nullptr 不支持
static OH_AVCapability* GetHWDecoderCapability(const char* mimeType) {
    if (mimeType == nullptr) {
        return nullptr;
    }

    OH_AVCapability* cap = OH_AVCodec_GetCapabilityByCategory(mimeType, false, HARDWARE);
    if (cap != nullptr && OH_AVCapability_IsHardware(cap)) {
        return cap;
    }
    return nullptr;
}

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
                "QueryOutputBuffer=%{public}s, GetInputBuffer=%{public}s, GetOutputBuffer=%{public}s",
                pfn_QueryInputBuffer ? "YES" : "NO",
                pfn_QueryOutputBuffer ? "YES" : "NO",
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
static constexpr int kAutoBufferCount = 2;      // 自动模式下，默认统一使用 2
static constexpr int kHighFpsThreshold = 60;    // 高帧率阈值
static constexpr int kHighFpsMaxBuffers = 4;    // 高帧率时最大缓冲区数

// 超时配置
static constexpr int kMinTimeoutMs = 50;        // 最小等待超时 (ms) - 增加以支持高帧率
static constexpr int kMaxTimeoutMs = 100;       // 最大等待超时 (ms) - 增加以支持高帧率

// 统计配置
static constexpr int64_t kStatsUpdateIntervalMs = 1000;  // 统计更新间隔
static constexpr int64_t kSyncLogIntervalMs = 10000;
static constexpr uint32_t kHdrVividProbeDecodeUnits = 300;

static int64_t GetSteadyTimeMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

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
static constexpr int64_t kLatencyRecoveryTimeoutMs = 1000; // drop-until-IDR 超时兜底：IDR 久未到达则恢复提交，避免长时间冻结
static constexpr int kCriticalPipelineFramesBeforeRecovery = 3;
// L4: 网络抖动突发检测 - 连续 N 帧在极短间隔内到达时主动 Flush + IDR
static constexpr int kBurstFlushThreshold = 4;           // 连续突发帧数阈值（@基准帧率）
static constexpr double kBurstBaselineFps = 60.0;        // 突发计数阈值的基准帧率
// 高刷下帧间隔本就极短，设备侧的正常补发很容易凑出连续短间隔。
// 按刷新率线性放宽触发计数，使"需要相同绝对积压时长(≈基准帧率下 kBurstFlushThreshold 帧)"
// 才触发，避免高刷误触：burstThreshold = max(基准, round(基准 × fps / 基准帧率))。
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

static int ResolveEffectiveBufferCount(int requestedCount, DecoderMode mode) {
    if (requestedCount > 0) {
        return std::clamp(requestedCount, kMinBufferCount, kMaxBufferCount);
    }
    (void)mode;
    return kAutoBufferCount;
}

// =============================================================================
// VideoDecoder 类实现
// =============================================================================

VideoDecoder::VideoDecoder() = default;

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
            return TryLoadAv1MimeType();
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
    hdrVividProbeDecodeUnits_.store(0, std::memory_order_relaxed);
    hdrVividProbeActive_.store(
        (config.codec == VideoCodecType::HEVC ||
         config.codec == VideoCodecType::AV1) &&
        config.enableHdr,
        std::memory_order_relaxed);
    hdrVividDetected_.store(false, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(windowMetadataMutex_);
        window_ = window;
        hasAppliedHdrMetadataType_ = false;
    }
    render_ = NativeRender::GetInstance();
    
    OH_LOG_INFO(LOG_APP, "{Init} Initializing video decoder: %{public}dx%{public}d@%.2f, codec=%{public}d, window=%{public}p",
                config_.width, config_.height, config_.fps, static_cast<int>(config_.codec), static_cast<void*>(window));
    
    // 创建视频解码器
    const char* mimeType = GetMimeType(config_.codec);
    if (mimeType == nullptr) {
        OH_LOG_ERROR(LOG_APP, "{Init} Decoder MIME unavailable for codec=%{public}d",
                     static_cast<int>(config_.codec));
        return -1;
    }
    OH_AVCapability* hwCapability = GetHWDecoderCapability(mimeType);
    if (hwCapability == nullptr) {
        OH_LOG_ERROR(LOG_APP, "{Init} No hardware decoder capability for mime type: %{public}s", mimeType);
        return -1;
    }
    const char* decoderName = OH_AVCapability_GetName(hwCapability);
    if (decoderName == nullptr || decoderName[0] == '\0') {
        OH_LOG_ERROR(LOG_APP, "{Init} Hardware decoder name unavailable for mime type: %{public}s", mimeType);
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "{Init} Creating hardware decoder: %{public}s (mime=%{public}s)",
                decoderName, mimeType);

    decoder_ = OH_VideoDecoder_CreateByName(decoderName);
    if (decoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "{Init} Failed to create hardware decoder: %{public}s", decoderName);
        return -1;
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
    
    // 统一解析解码队列深度：同一个设置在同步/异步模式下都先解析成一个有效值。
    // 自动模式默认统一为 2；同步模式下再同时作用于
    // 1) 软件 pending queue 上限
    // 2) 解码器 input/output buffer 请求值
    // 0 表示自动：默认统一解析为 2。
    int effectiveBufferCount = ResolveEffectiveBufferCount(config_.bufferCount, config_.decoderMode);
    maxPendingFrames_ = static_cast<size_t>(effectiveBufferCount > 0 ? effectiveBufferCount : kMinBufferCount);
    OH_LOG_INFO(LOG_APP, "{Init} Queue depth resolved: requested=%{public}d, effective=%{public}d, mode=%{public}s, softwareQueue=%{public}zu",
                config_.bufferCount, effectiveBufferCount,
                config_.decoderMode == DecoderMode::SYNC ? "SYNC" : "ASYNC",
                maxPendingFrames_);

    // 缓冲区配置优化 - 减少管线延迟
    // HarmonyOS 官方 API：
    // - OH_MD_MAX_INPUT_BUFFER_COUNT: 最大输入缓冲区个数
    // - OH_MD_MAX_OUTPUT_BUFFER_COUNT: 最大输出缓冲区个数
    //
    // effectiveBufferCount == 0 表示保持系统默认值（不设置）
    // effectiveBufferCount > 0 表示使用统一解析后的队列深度
    if (effectiveBufferCount > 0) {
        OH_AVFormat_SetIntValue(format, OH_MD_MAX_INPUT_BUFFER_COUNT, effectiveBufferCount);
        OH_AVFormat_SetIntValue(format, OH_MD_MAX_OUTPUT_BUFFER_COUNT, effectiveBufferCount);
        
#ifdef MOONLIGHT_ENABLE_PRIVATE_AVCODEC_KEYS
        OH_AVFormat_SetIntValue(format, "video_decoder_output_buffer_count", effectiveBufferCount);
#endif
        OH_LOG_INFO(LOG_APP, "{Init} Decoder buffer request set to: %{public}d (fps=%.2f, mode=%{public}s)", 
                    effectiveBufferCount, config_.fps,
                    config_.decoderMode == DecoderMode::SYNC ? "SYNC" : "ASYNC");
    } else {
        OH_LOG_INFO(LOG_APP, "{Init} Using system default decoder buffer count (fps=%.2f, mode=%{public}s)",
                    config_.fps, config_.decoderMode == DecoderMode::SYNC ? "SYNC" : "ASYNC");
    }
    
    // Configure decoder color metadata explicitly. These keys are exported
    // const char* symbols (not preprocessor macros), so they must not be
    // guarded with #ifdef.
    //
    // 颜色范围: 0 = Limited, 1 = Full
    int32_t colorRange = (config_.colorRange == ColorRange::FULL) ? 1 : 0;
    const bool colorRangeSet = OH_AVFormat_SetIntValue(format, OH_MD_KEY_RANGE_FLAG, colorRange);
    
    // 配置颜色空间标准 (OH_ColorPrimary)
    int32_t colorPrimary = kColorPrimaryBT709;
    switch (config_.colorSpace) {
        case ColorSpace::REC_601:  colorPrimary = kColorPrimaryBT601;  break;
        case ColorSpace::REC_709:  colorPrimary = kColorPrimaryBT709;  break;
        case ColorSpace::REC_2020: colorPrimary = kColorPrimaryBT2020; break;
    }
    const bool colorPrimarySet = OH_AVFormat_SetIntValue(format, OH_MD_KEY_COLOR_PRIMARIES, colorPrimary);
    
    // 配置传输特性 (OH_TransferCharacteristic)
    int32_t transferChar = kTransferCharSDR;
    if (config_.enableHdr) {
        switch (config_.hdrType) {
            case HdrType::HDR10:     transferChar = kTransferCharPQ;  break;
            case HdrType::HLG:      transferChar = kTransferCharHLG; break;
            default:                 transferChar = kTransferCharPQ;  break;
        }
    }
    const bool transferCharSet = OH_AVFormat_SetIntValue(format, OH_MD_KEY_TRANSFER_CHARACTERISTICS, transferChar);
    
    // 配置矩阵系数 (OH_MatrixCoefficient)
    int32_t matrixCoeff = kMatrixCoeffBT709;
    switch (config_.colorSpace) {
        case ColorSpace::REC_601:  matrixCoeff = kMatrixCoeffBT601;     break;
        case ColorSpace::REC_709:  matrixCoeff = kMatrixCoeffBT709;     break;
        case ColorSpace::REC_2020: matrixCoeff = kMatrixCoeffBT2020NCL; break;
    }
    const bool matrixCoeffSet = OH_AVFormat_SetIntValue(format, OH_MD_KEY_MATRIX_COEFFICIENTS, matrixCoeff);
    
    OH_LOG_INFO(LOG_APP,
                "{Init} Decoder color metadata: range=%{public}d (set=%{public}d), "
                "primaries=%{public}d (set=%{public}d), transfer=%{public}d (set=%{public}d), "
                "matrix=%{public}d (set=%{public}d)",
                colorRange, colorRangeSet ? 1 : 0,
                colorPrimary, colorPrimarySet ? 1 : 0,
                transferChar, transferCharSet ? 1 : 0,
                matrixCoeff, matrixCoeffSet ? 1 : 0);

    if (!colorRangeSet || !colorPrimarySet || !transferCharSet || !matrixCoeffSet) {
        OH_LOG_WARN(LOG_APP, "{Init} Failed to set one or more decoder color metadata fields");
    }

    // HDR Vivid is signalled by CUVA metadata preserved in the elementary
    // stream. OH_MD_KEY_VIDEO_IS_HDR_VIVID describes a media-file track and is
    // only supported by demuxers/muxers, so it is not a decoder Configure key.
    if (config_.enableHdr) {
        OH_LOG_INFO(LOG_APP,
                    "{Init} CUVA metadata remains in-band; no client-side HDR Vivid override");
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
            bool isFullRange = (config_.colorRange == ColorRange::FULL);
            
            switch (config_.hdrType) {
                case HdrType::HLG:
                    windowColorSpace = isFullRange ? OH_COLORSPACE_BT2020_HLG_FULL : OH_COLORSPACE_BT2020_HLG_LIMIT;
                    break;
                case HdrType::HDR10:      // PQ
                default:
                    windowColorSpace = isFullRange ? OH_COLORSPACE_BT2020_PQ_FULL : OH_COLORSPACE_BT2020_PQ_LIMIT;
                    break;
            }
            OH_LOG_INFO(LOG_APP, "{Init} HDR NativeWindow: colorspace=%{public}d, fullRange=%{public}d",
                        static_cast<int>(windowColorSpace), isFullRange ? 1 : 0);
            
#ifdef __OHOS__
            // 1. 设置 Color Gamut（颜色域）
            int32_t colorGamut = (config_.hdrType == HdrType::HLG) ?
                NATIVEBUFFER_COLOR_GAMUT_BT2100_HLG : NATIVEBUFFER_COLOR_GAMUT_BT2100_PQ;
            int32_t gamutRet = OH_NativeWindow_NativeWindowHandleOpt(window_, SET_COLOR_GAMUT, colorGamut);
            if (gamutRet != 0) {
                OH_LOG_WARN(LOG_APP, "{Init} Failed to set color gamut: %{public}d", gamutRet);
            }

            // 先写入基础 HDR 类型，覆盖同一 Surface 上一会话可能遗留的 Vivid。
            // 如果后续从输出格式或 CUVA 码流检测到 Vivid，再切换类型。
            const OH_NativeBuffer_MetadataType baseMetadataType =
                config_.hdrType == HdrType::HLG ? OH_VIDEO_HDR_HLG : OH_VIDEO_HDR_HDR10;
            SetNativeWindowHdrMetadataType(baseMetadataType, "session baseline");

            // 2. 设置 colorspace
            int32_t csRet = OH_NativeWindow_SetColorSpace(window_, windowColorSpace);
            if (csRet != 0) {
                OH_LOG_WARN(LOG_APP, "{Init} Failed to set colorspace: %{public}d", csRet);
            }
            
            // 3. 设置 HDR 白点亮度
            float hdrWhitePointBrightness = 1.0f;
            int32_t hdrBrightRet = OH_NativeWindow_NativeWindowHandleOpt(window_, SET_HDR_WHITE_POINT_BRIGHTNESS, hdrWhitePointBrightness);
            if (hdrBrightRet != 0) {
                OH_LOG_WARN(LOG_APP, "{Init} Failed to set HDR white point: %{public}d", hdrBrightRet);
            }
            
            // 4. 设置 HDR 静态元数据（SMPTE 2086 + CTA 861.3）
            // Sunshine 会通过控制流传递主机显示器/内容元数据；缺失时才使用 BT.2020 默认值。
            OH_NativeBuffer_StaticMetadata staticMetadata;
            bool hasHostHdrStaticMetadata = false;
            {
                std::lock_guard<std::mutex> lock(g_hdrStaticMetadataMutex);
                if (g_hasHdrStaticMetadata) {
                    staticMetadata = ToNativeHdrStaticMetadata(g_hdrStaticMetadata);
                    hasHostHdrStaticMetadata = true;
                } else {
                    staticMetadata = BuildDefaultHdrStaticMetadata();
                }
            }

            if (hasHostHdrStaticMetadata) {
                OH_LOG_INFO(LOG_APP, "{Init} Using host HDR static metadata: maxLum=%.3f, minLum=%.4f, maxCLL=%.3f, maxFALL=%.3f",
                            staticMetadata.smpte2086.maxLuminance,
                            staticMetadata.smpte2086.minLuminance,
                            staticMetadata.cta861.maxContentLightLevel,
                            staticMetadata.cta861.maxFrameAverageLightLevel);
            } else {
                OH_LOG_INFO(LOG_APP, "{Init} Host HDR metadata unavailable, using BT.2020 fallback static metadata");
            }

            int32_t staticMetaRet = OH_NativeWindow_SetMetadataValue(window_, OH_HDR_STATIC_METADATA,
                sizeof(staticMetadata), reinterpret_cast<uint8_t*>(&staticMetadata));
            if (staticMetaRet != 0) {
                OH_LOG_WARN(LOG_APP, "{Init} Failed to set HDR static metadata: %{public}d", staticMetaRet);
            } else {
                OH_LOG_INFO(LOG_APP, "{Init} HDR static metadata set");
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
    
    render_->ResetPresentationClock();
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
    if (render_ != nullptr) {
        render_->ResetPresentationClock();
    }
    
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
    // Flush/Stop/Reset/Destroy 期间不应操作之前回调获取到的 buffer
    {
        std::unique_lock<std::shared_mutex> codecLock(codecMutex_);
        if (decoder_ != nullptr) {
            OH_VideoDecoder_Stop(decoder_);
        }
        
        // 在 unique_lock 保护下清空异步输入队列，确保不会有线程正在使用这些 buffer
        {
            std::lock_guard<std::mutex> lock(inputMutex_);
            while (!inputIndexQueue_.empty()) inputIndexQueue_.pop();
            while (!inputBufferQueue_.empty()) inputBufferQueue_.pop();
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

    if (render_ != nullptr) {
        render_->ResetPresentationClock();
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
    
    // 清空时间戳环
    {
        std::lock_guard<std::mutex> lock(timestampMutex_);
        timestampEntries_.fill({});
        timestampWriteIndex_ = 0;
    }
    
    {
        std::lock_guard<std::mutex> lock(windowMetadataMutex_);
        window_ = nullptr;
        hasAppliedHdrMetadataType_ = false;
    }
    configured_ = false;
    firstFrameReceived_ = false;
    lastInstantDecodeTimeMs_ = 0;
    latencyRecoveryActive_ = false;
    lastOutputTimeMs_ = 0;
    lastFrameArrivalMs_ = 0;
    burstFrameCount_ = 0;
    lastAsyncRenderTimeMs_ = 0;
    lastAsyncOutputTimeMs_ = 0;
    consecutiveCriticalPipelineFrames_ = 0;
    hdrVividProbeDecodeUnits_.store(0, std::memory_order_relaxed);
    hdrVividProbeActive_.store(false, std::memory_order_relaxed);
    hdrVividDetected_.store(false, std::memory_order_relaxed);
    
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

class PresentationTargetGuard {
public:
    PresentationTargetGuard(NativeRender* render, int64_t pts)
        : render_(render) {
        if (render_ != nullptr) {
            target_ = render_->PreparePresentationFrame(pts);
        }
    }

    PresentationTargetGuard(
            NativeRender* render, PresentationTargetHandle target)
        : render_(render), target_(target) {}

    ~PresentationTargetGuard() {
        if (render_ != nullptr && target_ && !committed_) {
            render_->DiscardPresentationFrame(target_);
        }
    }

    void Commit() { committed_ = true; }
    PresentationTargetHandle GetTarget() const { return target_; }

    PresentationTargetGuard(const PresentationTargetGuard&) = delete;
    PresentationTargetGuard& operator=(const PresentationTargetGuard&) = delete;

private:
    NativeRender* render_ = nullptr;
    PresentationTargetHandle target_;
    bool committed_ = false;
};

void VideoDecoder::RecordEnqueueTimestamp(int64_t timestamp) {
    const int64_t enqueueTimeMs = GetSteadyTimeMs();
    std::lock_guard<std::mutex> lock(timestampMutex_);

    TimestampEntry& entry = timestampEntries_[timestampWriteIndex_];
    entry.pts = timestamp;
    entry.enqueueTimeMs = enqueueTimeMs;
    entry.valid = true;
    timestampWriteIndex_ = (timestampWriteIndex_ + 1) % timestampEntries_.size();
}

int64_t VideoDecoder::TakeEnqueueTimestamp(int64_t timestamp) {
    std::lock_guard<std::mutex> lock(timestampMutex_);

    // Search newest-first so a repeated PTS resolves to the latest submission.
    for (size_t offset = 0; offset < timestampEntries_.size(); ++offset) {
        const size_t index =
            (timestampWriteIndex_ + timestampEntries_.size() - 1 - offset) % timestampEntries_.size();
        TimestampEntry& entry = timestampEntries_[index];
        if (entry.valid && entry.pts == timestamp) {
            entry.valid = false;
            return entry.enqueueTimeMs;
        }
    }
    return 0;
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

    if (hdrVividProbeActive_.load(std::memory_order_relaxed)) {
        const uint32_t probeIndex = hdrVividProbeDecodeUnits_.fetch_add(
            1, std::memory_order_relaxed);
        if (probeIndex < kHdrVividProbeDecodeUnits) {
            if (probeIndex + 1 == kHdrVividProbeDecodeUnits) {
                hdrVividProbeActive_.store(false, std::memory_order_relaxed);
            }
            const HdrVividBitstreamFormat bitstreamFormat =
                config_.codec == VideoCodecType::AV1 ?
                    HdrVividBitstreamFormat::AV1_LOW_OVERHEAD_OBU :
                    HdrVividBitstreamFormat::HEVC_ANNEX_B;
            HdrVividMetadataScanner scanner(bitstreamFormat);
            for (int index = 0; index < segmentCount; ++index) {
                if (scanner.Scan(segments[index].data,
                                 static_cast<size_t>(segments[index].length))) {
                    break;
                }
            }
            if (scanner.Finish()) {
                hdrVividDetected_.store(true, std::memory_order_relaxed);
                hdrVividProbeActive_.store(false, std::memory_order_relaxed);
                SetNativeWindowHdrMetadataType(OH_VIDEO_HDR_VIVID, "CUVA bitstream");
                OH_LOG_INFO(LOG_APP,
                            "HDR Vivid CUVA dynamic metadata detected in %{public}s",
                            config_.codec == VideoCodecType::AV1 ?
                                "AV1 Metadata OBU" : "HEVC SEI");
            }
        } else {
            hdrVividProbeActive_.store(false, std::memory_order_relaxed);
        }
    }
    
    // === L4 网络抖动突发检测（仅异步模式） ===
    // 同步模式下 L1 drain-to-latest 已足够处理突发到达，L4 的 IDR 请求反而会加重负担
    if (config_.decoderMode != DecoderMode::SYNC &&
        !render_->IsHostPacedPresentationActive()) {
        const int64_t nowMs = GetSteadyTimeMs();
        int64_t lastArrival = lastFrameArrivalMs_.exchange(nowMs);
        double expectedFrameMs = 1000.0 / config_.fps;
        
        // 按刷新率放宽 L4 触发计数：高刷下帧间隔短，正常的设备侧补发易凑出连续短间隔，
        // 故要求更多连续突发帧（绝对积压时长保持 ≈ 基准帧率下 kBurstFlushThreshold 帧）才触发。
        int burstThreshold = std::max(kBurstFlushThreshold,
            static_cast<int>(kBurstFlushThreshold * config_.fps / kBurstBaselineFps + 0.5));
        
        if (lastArrival > 0 &&
            (nowMs - lastArrival) < static_cast<int64_t>(expectedFrameMs * kBurstIntervalRatio)) {
            int burst = burstFrameCount_.fetch_add(1) + 1;
            if (burst >= burstThreshold && frameType != VideoFrameType::I_FRAME) {
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
                render_->ResetPresentationClock();
                latencyRecoveryActive_.store(true);
                UpdateReceivedStats(totalSize, frameNumber, hostProcessingLatency);
                RecordDroppedFrames(DropReason::L4);
                OH_LOG_WARN(LOG_APP, "L4 burst detected (%{public}d/%{public}d frames in <%.1fms interval @%.0ffps), requesting IDR",
                            burst, burstThreshold, expectedFrameMs * kBurstIntervalRatio, config_.fps);
                return -1;  // DR_NEED_IDR
            }
        } else {
            burstFrameCount_.store(0);
        }
    }
    
    // === L3 延迟恢复：临界延迟检查 ===
    // 当解码延迟过高时，丢弃 P 帧并触发 IDR 请求
    int recoveryResult = CheckLatencyRecovery(
        frameType, totalSize, frameNumber, hostProcessingLatency);
    if (recoveryResult < 0) {
        return recoveryResult;  // -1 = DR_NEED_IDR
    }

    PresentationTargetGuard presentationTarget(render_, timestamp);

    // 同步模式：直接提交到解码器（scatter-gather 直写 AVBuffer）
    if (config_.decoderMode == DecoderMode::SYNC) {
        UpdateReceivedStats(totalSize, frameNumber, hostProcessingLatency);
        
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
                            presentationTarget.Commit();
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
            uint64_t overflowCount = 0;
            std::lock_guard<std::mutex> lock(pendingFrameMutex_);
            while (pendingFrameQueue_.size() >= maxPendingFrames_) {
                render_->DiscardPresentationFrame(
                    pendingFrameQueue_.front().presentationTarget);
                pendingFrameQueue_.pop();
                overflowCount++;
            }
            if (overflowCount > 0) {
                RecordDroppedFrames(DropReason::QUEUE_OVERFLOW, overflowCount);
            }
            
            PendingFrame frame;
            frame.data.resize(totalSize);
            CopySegmentsToBuffer(frame.data.data(), segments, segmentCount);
            frame.frameNumber = frameNumber;
            frame.frameType = frameType;
            frame.timestamp = timestamp;
            frame.hostProcessingLatency = hostProcessingLatency;
            frame.presentationTarget = presentationTarget.GetTarget();
            
            pendingFrameQueue_.push(std::move(frame));
            pendingFrameCond_.notify_one();
            presentationTarget.Commit();
            
            // 队列溢出 = 丢弃了中间 P 帧 → 后续 P 帧缺少参考帧会损坏
            // 激活恢复模式：丢弃后续 P 帧，等待 IDR 重建参考链
            if (overflowCount > 0 && !latencyRecoveryActive_.exchange(true)) {
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
                RecordDroppedFrames(DropReason::TIMEOUT);
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
    
    // 参考官方文档：使用 shared_lock 保护 buffer 操作，防止 Flush/Stop 期间访问已失效的 buffer
    // Flush/Stop 持有 unique_lock 时会等待此 shared_lock 释放，确保 buffer 操作完整性
    std::shared_lock<std::shared_mutex> codecLock(codecMutex_);
    
    // Flush/Stop 可能在等待 inputMutex_ 释放后、获取 codecMutex_ 前已经执行，
    // 此时之前回调传入的 buffer 已失效，需检查解码器状态
    if (!running_ || decoder_ == nullptr) {
        return -1;
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

    presentationTarget.Commit();

    UpdateReceivedStats(totalSize, frameNumber, hostProcessingLatency);
    
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
void VideoDecoder::UpdateReceivedStats(int size, int frameNumber, uint16_t hostProcessingLatency) {
    const int64_t currentTimeMs = GetSteadyTimeMs();
    std::lock_guard<std::mutex> lock(statsMutex_);
    stats_.totalFrames++;
    stats_.totalBytesReceived += size;
    
    // 帧号跳跃检测：如果帧号不连续，说明网络丢包导致帧丢失
    // 对齐 Android MediaCodecDecoderRenderer.submitDecodeUnit() 的丢包统计逻辑
    if (stats_.lastFrameNumber != 0 && frameNumber != stats_.lastFrameNumber
        && frameNumber != stats_.lastFrameNumber + 1) {
        int lost = frameNumber - stats_.lastFrameNumber - 1;
        if (lost > 0) {
            stats_.framesLost += lost;
            stats_.totalFrames += lost;
        }
    }
    stats_.lastFrameNumber = frameNumber;
    receivedFrameRate_.Record(currentTimeMs, stats_.totalFrames);
    
    // Keep the live overlay responsive to recovery instead of letting old
    // high-latency frames affect the value for the rest of the session.
    if (recentHostLatencyWindowStartTimeMs_ == 0) {
        recentHostLatencyWindowStartTimeMs_ = currentTimeMs;
    } else if (currentTimeMs - recentHostLatencyWindowStartTimeMs_ >= kStatsUpdateIntervalMs) {
        stats_.recentHostProcessingLatency = 0.0;
        recentHostLatencyWindowFrames_ = 0;
        recentHostLatencyWindowTotalMs_ = 0.0;
        recentHostLatencyWindowStartTimeMs_ = currentTimeMs;
    }

    if (hostProcessingLatency > 0) {
        double hostLatencyMs = static_cast<double>(hostProcessingLatency) / 10.0;
        stats_.framesWithHostLatency++;
        stats_.totalHostProcessingLatency += hostLatencyMs;
        recentHostLatencyWindowFrames_++;
        recentHostLatencyWindowTotalMs_ += hostLatencyMs;
        stats_.recentHostProcessingLatency = recentHostLatencyWindowTotalMs_ /
            static_cast<double>(recentHostLatencyWindowFrames_);
    }
    
    if (stats_.lastStatsCalculationTime == 0) {
        stats_.lastStatsCalculationTime = currentTimeMs;
        stats_.lastBytesCount = stats_.totalBytesReceived;
        stats_.lastBitrateCalculationTime = currentTimeMs;
        stats_.sessionStartTime = currentTimeMs;  // 记录会话开始时间
    } else if (currentTimeMs - stats_.lastStatsCalculationTime >=
               kStatsUpdateIntervalMs) {
        const int64_t elapsedMs =
            currentTimeMs - stats_.lastStatsCalculationTime;
        stats_.lastStatsCalculationTime = currentTimeMs;

        // 计算比特率
        const uint64_t bytesDelta =
            stats_.totalBytesReceived - stats_.lastBytesCount;
        stats_.currentBitrate = static_cast<double>(bytesDelta) * 8.0 *
            1000.0 / static_cast<double>(elapsedMs);
        stats_.lastBytesCount = stats_.totalBytesReceived;
        stats_.lastBitrateCalculationTime = currentTimeMs;
        
        if (stats_.framesWithHostLatency > 0) {
            stats_.avgHostProcessingLatency = stats_.totalHostProcessingLatency / stats_.framesWithHostLatency;
        }
    }
    
}

VideoDecoderStats VideoDecoder::GetStats() const {
    const int64_t currentTimeMs = GetSteadyTimeMs();
    VideoDecoderStats snapshot;
    {
        std::lock_guard<std::mutex> lock(statsMutex_);
        snapshot = stats_;
        snapshot.currentFps = receivedFrameRate_.GetRate(currentTimeMs);
        codecOutputFrameRate_.Record(
            currentTimeMs, codecOutputFrames_.load(std::memory_order_relaxed));
        snapshot.codecOutputFps = codecOutputFrameRate_.GetRate(currentTimeMs);
        renderedFrameRate_.Record(
            currentTimeMs, decodedFrames_.load(std::memory_order_relaxed));
        snapshot.renderedFps = renderedFrameRate_.GetRate(currentTimeMs);
    }

    snapshot.codecOutputFrames = codecOutputFrames_.load(std::memory_order_relaxed);
    snapshot.decodedFrames = decodedFrames_.load(std::memory_order_relaxed);
    snapshot.droppedFrames = droppedFrames_.load(std::memory_order_relaxed);
    snapshot.droppedByL1 = droppedByL1_.load(std::memory_order_relaxed);
    snapshot.droppedByL2 = droppedByL2_.load(std::memory_order_relaxed);
    snapshot.droppedByL3 = droppedByL3_.load(std::memory_order_relaxed);
    snapshot.droppedByL4 = droppedByL4_.load(std::memory_order_relaxed);
    snapshot.droppedByL5 = droppedByL5_.load(std::memory_order_relaxed);
    snapshot.droppedByQueueOverflow = droppedByQueueOverflow_.load(std::memory_order_relaxed);
    snapshot.droppedByTimeout = droppedByTimeout_.load(std::memory_order_relaxed);
    snapshot.syncDrainEvents = syncDrainEvents_.load(std::memory_order_relaxed);
    snapshot.syncDrainFrames = syncDrainFrames_.load(std::memory_order_relaxed);
    snapshot.syncDecode = config_.decoderMode == DecoderMode::SYNC;
    snapshot.hdrVivid = hdrVividDetected_.load(std::memory_order_relaxed);
    if (render_ != nullptr) {
        snapshot.hostPacedPresentationActive =
            render_->IsHostPacedPresentationActive();
        snapshot.presentation = render_->GetTwoStepPresentationStats();
    }
    if (snapshot.sessionStartTime > 0 &&
        currentTimeMs > snapshot.sessionStartTime) {
        snapshot.globalAvgFps =
            static_cast<double>(snapshot.decodedFrames) * 1000.0 /
            static_cast<double>(currentTimeMs - snapshot.sessionStartTime);
    }
    {
        std::lock_guard<std::mutex> lock(decodeStatsMutex_);
        snapshot.totalDecodeTimeMs = static_cast<double>(decodeTotalTimeMs_);
        snapshot.validDecodeFrames = decodeValidFrames_;
        snapshot.averageDecodeTimeMs = decodeAverageTimeMs_;
        snapshot.maxDecodeTimeMs = static_cast<double>(decodeMaxTimeMs_);
    }
    return snapshot;
}

void VideoDecoder::RecordDroppedFrames(DropReason reason, uint64_t count) {
    droppedFrames_.fetch_add(count, std::memory_order_relaxed);
    switch (reason) {
        case DropReason::L1:
            droppedByL1_.fetch_add(count, std::memory_order_relaxed);
            break;
        case DropReason::L2:
            droppedByL2_.fetch_add(count, std::memory_order_relaxed);
            break;
        case DropReason::L3:
            droppedByL3_.fetch_add(count, std::memory_order_relaxed);
            break;
        case DropReason::L4:
            droppedByL4_.fetch_add(count, std::memory_order_relaxed);
            break;
        case DropReason::L5:
            droppedByL5_.fetch_add(count, std::memory_order_relaxed);
            break;
        case DropReason::QUEUE_OVERFLOW:
            droppedByQueueOverflow_.fetch_add(count, std::memory_order_relaxed);
            break;
        case DropReason::TIMEOUT:
            droppedByTimeout_.fetch_add(count, std::memory_order_relaxed);
            break;
        case DropReason::PRESENTATION:
            break;
    }
}

// =============================================================================
// AVCodec 回调实现
// =============================================================================

void VideoDecoder::SetNativeWindowHdrMetadataType(
        OH_NativeBuffer_MetadataType metadataType, const char* source) {
#ifdef __OHOS__
    std::lock_guard<std::mutex> lock(windowMetadataMutex_);
    if (window_ == nullptr ||
        (hasAppliedHdrMetadataType_ && appliedHdrMetadataType_ == metadataType)) {
        return;
    }

    OH_NativeBuffer_MetadataType value = metadataType;
    const int32_t ret = OH_NativeWindow_SetMetadataValue(
        window_, OH_HDR_METADATA_TYPE, sizeof(value), reinterpret_cast<uint8_t*>(&value));
    if (ret != 0) {
        OH_LOG_WARN(LOG_APP,
                    "Failed to set HDR metadata type=%{public}d from %{public}s: %{public}d",
                    static_cast<int>(metadataType), source, ret);
        return;
    }

    appliedHdrMetadataType_ = metadataType;
    hasAppliedHdrMetadataType_ = true;
    OH_LOG_INFO(LOG_APP, "HDR metadata type=%{public}d applied from %{public}s",
                static_cast<int>(metadataType), source);
#else
    (void)metadataType;
    (void)source;
#endif
}

void VideoDecoder::ApplyOutputHdrMetadata(OH_AVFormat* format) {
    if (!config_.enableHdr || format == nullptr) {
        return;
    }

    int32_t vividFlag = 0;
    if (OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_IS_HDR_VIVID, &vividFlag) &&
        vividFlag != 0) {
        hdrVividDetected_.store(true, std::memory_order_relaxed);
    }

    int32_t transferChar = config_.hdrType == HdrType::HLG ?
        kTransferCharHLG : kTransferCharPQ;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_TRANSFER_CHARACTERISTICS, &transferChar);

    OH_NativeBuffer_MetadataType metadataType;
    if (hdrVividDetected_.load(std::memory_order_relaxed)) {
        metadataType = OH_VIDEO_HDR_VIVID;
    } else if (transferChar == kTransferCharHLG) {
        metadataType = OH_VIDEO_HDR_HLG;
    } else {
        metadataType = OH_VIDEO_HDR_HDR10;
    }
    SetNativeWindowHdrMetadataType(metadataType, "decoder output format");
}

void VideoDecoder::OnError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    OH_LOG_ERROR(LOG_APP, "Decoder error: %{public}d", errorCode);
}

void VideoDecoder::OnOutputFormatChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    // 参考官方文档：从 OnStreamChanged 回调的 format 中获取输出侧的视频宽高
    // 使用 OH_MD_KEY_VIDEO_PIC_WIDTH/HEIGHT（实际图像尺寸），
    // 而不是 OH_MD_KEY_WIDTH/HEIGHT（编码参数尺寸，可能包含对齐填充）
    int32_t width = 0, height = 0;
    if (!OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_WIDTH, &width) ||
        !OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_HEIGHT, &height)) {
        // 回退：如果输出侧字段不可用（旧版本 API），使用编码参数尺寸
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &width);
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &height);
    }
    OH_LOG_INFO(LOG_APP, "Output format changed: %{public}dx%{public}d", width, height);

    auto* self = static_cast<VideoDecoder*>(userData);
    if (self != nullptr) {
        self->ApplyOutputHdrMetadata(format);
    }
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
    OH_AVCodecBufferAttr attr = {};
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "Async: failed to get output buffer attr");
        OH_VideoDecoder_FreeOutputBuffer(codec, index);
        return;
    }
    const int64_t pts = attr.pts;

    if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
        self->render_->DiscardPresentationFrame(pts);
        OH_VideoDecoder_FreeOutputBuffer(codec, index);
        return;
    }

    const int64_t outputTimeMs = GetSteadyTimeMs();
    
    // 获取入队时间
    const int64_t enqueueTimeMs = self->TakeEnqueueTimestamp(pts);
    
    // === L2 延迟恢复：异步模式基于延迟的帧跳过 ===
    // 当解码耗时过高时，跳过非关键帧以快速追赶
    const bool hostPaced = self->render_->IsHostPacedPresentationActive();
    if (enqueueTimeMs > 0 && !hostPaced) {
        // 记录回调到达时间（用于 L5 输出间隔检测，排除渲染处理开销的抖动）
        int64_t prevOutputTimeMs = self->lastAsyncOutputTimeMs_.exchange(outputTimeMs);
        int64_t instantDecodeTimeMs = outputTimeMs - enqueueTimeMs;
        double expectedFrameTimeMs = 1000.0 / self->config_.fps;
        bool isKeyframe = (attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) != 0;
        
        // 跳过条件：解码时间 > 3倍帧间隔 且 非关键帧 且 已过启动阶段
        if (instantDecodeTimeMs > expectedFrameTimeMs * kAsyncSkipThresholdMultiplier &&
            !isKeyframe &&
            self->codecOutputFrames_.load(std::memory_order_relaxed) > kLatencyRecoveryMinFrames) {
            OH_VideoDecoder_FreeOutputBuffer(codec, index);
            self->RecordDroppedFrames(DropReason::L2);
            // 注意：不要把含排队等待的管线延迟 instantDecodeTimeMs 写入 lastInstantDecodeTimeMs_。
            // 该字段是 L3 临界延迟判据的输入，应只反映"真实解码耗时"（剔除队列等待）。
            // 若在此写入管线延迟，会让 L3 把网络抖动/积压误判为解码卡顿而触发 IDR（L2→L3 串扰）。
            // 此处丢弃的帧未真正解码，没有精确解码时间，保留上一帧的良好值即可。
            return;
        }
        
        // === L5 异步渲染跳帧（高帧率自适应） ===
        // 当帧输出间隔过短（解码器批量输出）且延迟偏高时，跳过中间帧
        // 高帧率（>90fps）使用更宽松的阈值，避免 VPU 正常管线延迟被误判
        // 使用回调到达间隔（而非渲染完成间隔），排除 GL 后处理/锁竞争等开销的抖动
        if (prevOutputTimeMs > 0 && !isKeyframe &&
            self->codecOutputFrames_.load(std::memory_order_relaxed) > kLatencyRecoveryMinFrames) {
            int64_t outputInterval = outputTimeMs - prevOutputTimeMs;
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
                self->RecordDroppedFrames(DropReason::L5);
                // 低帧率：回退 outputTime（级联丢帧确保 burst 中只保留最新帧）
                // 高帧率：保持当前值不回退（避免级联丢帧过度）
                if (self->config_.fps <= kL5HighFpsThreshold) {
                    self->lastAsyncOutputTimeMs_.store(prevOutputTimeMs);
                }
                return;
            }
        }
    }
    
    // 更新异步渲染时间戳
    self->lastAsyncRenderTimeMs_.store(outputTimeMs);
    
    // 注意：异步模式不在此处做帧率限制
    // 原因：
    // 1. 阻塞解码器回调线程会导致内部 buffer 堆积
    // 2. VSync 模式已通过 RenderOutputBufferAtTime 控制呈现时间
    // 3. 低延迟模式应尽快渲染，由显示器 VSync 自然限制
    // 帧率限制通过 SetExpectedFrameRateRange 在系统层面实现
    
    self->SubmitDecodedFrame(codec, index, attr, enqueueTimeMs, outputTimeMs);
}

// =============================================================================
// 同步模式解码实现
// =============================================================================

void VideoDecoder::SubmitDecodedFrame(OH_AVCodec* codec, uint32_t index,
                                      const OH_AVCodecBufferAttr& attr,
                                      int64_t enqueueTimeMs, int64_t outputTimeMs) {
    NativeRender::DecodedFrame decodedFrame;
    decodedFrame.codec = codec;
    decodedFrame.bufferIndex = index;
    decodedFrame.ptsUs = attr.pts;

    // SubmitFrame owns the output buffer for every result. Keep presentation
    // accounting and the ownership contract identical for all decoder modes.
    const NativeRender::FrameSubmitResult result = render_->SubmitFrame(decodedFrame);
    UpdateDecodedStats(enqueueTimeMs, attr.flags, outputTimeMs, result.presented);
    if (!result.presented) {
        RecordDroppedFrames(DropReason::PRESENTATION);
    }
    if (result.status != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "Submit decoded frame failed: %{public}d, pts=%{public}lld",
                    result.status, static_cast<long long>(attr.pts));
    }
}

void VideoDecoder::UpdateDecodedStats(int64_t enqueueTimeMs, uint32_t flags,
                                      int64_t currentTimeMs, bool presented) {
    const uint64_t outputFrames =
        codecOutputFrames_.fetch_add(1, std::memory_order_relaxed) + 1;
    if (presented) {
        decodedFrames_.fetch_add(1, std::memory_order_relaxed);
    }
    
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
            
            // Output callbacks share this small accumulator but no longer
            // contend with receive statistics or UI snapshot reads per frame.
            std::lock_guard<std::mutex> lock(decodeStatsMutex_);
            decodeTotalTimeMs_ += static_cast<uint64_t>(decodeTimeMs);
            decodeValidFrames_++;

            if (decodeValidFrames_ == 1) {
                decodeAverageTimeMs_ = static_cast<double>(decodeTimeMs);
            } else {
                const double alpha = isKeyframe ? kEmaAlphaKeyframe : kEmaAlphaNormal;
                decodeAverageTimeMs_ = alpha * decodeTimeMs +
                    (1.0 - alpha) * decodeAverageTimeMs_;
            }

            if (decodeTimeMs > decodeMaxTimeMs_) {
                decodeMaxTimeMs_ = decodeTimeMs;
            }
        }
        
        // L3 延迟恢复使用管线延迟（含排队时间），因为它反映真实的端到端堆积
        // 注意：lastInstantDecodeTimeMs_ 已更新为精确解码时间，L3 需要用原始管线延迟
        // L3 的 CheckLatencyRecovery 直接读 lastInstantDecodeTimeMs_，
        // 但这里改用精确值后，L3 阈值也需要相应降低——因为精确解码时间更小了
        // 为保持 L3 敏感度，额外检查管线延迟是否超过临界值
        if (pipelineLatencyMs > static_cast<int64_t>(
                std::max(1000.0 / config_.fps * kCriticalLatencyMultiplier, kCriticalLatencyMinMs)) &&
            outputFrames > kLatencyRecoveryMinFrames) {
            // Require a short run of critical samples. A single queue spike is
            // common during transport jitter and must not turn into an IDR
            // recovery freeze by itself.
            const int criticalFrames =
                consecutiveCriticalPipelineFrames_.fetch_add(
                    1, std::memory_order_relaxed) + 1;
            constexpr int64_t kPipelineWarningIntervalMs = 5000;
            const int64_t lastWarningMs =
                lastPipelineWarningTimeMs_.load(std::memory_order_relaxed);
            if (criticalFrames >= kCriticalPipelineFramesBeforeRecovery &&
                !latencyRecoveryActive_.load()) {
                bool expected = false;
                if (latencyRecoveryActive_.compare_exchange_strong(expected, true) &&
                    (lastWarningMs == 0 ||
                     currentTimeMs - lastWarningMs >= kPipelineWarningIntervalMs)) {
                    lastPipelineWarningTimeMs_.store(currentTimeMs, std::memory_order_relaxed);
                    OH_LOG_WARN(LOG_APP, "Pipeline latency %{public}lldms critical for %{public}d frames (decode=%{public}lldms), flagging recovery",
                                static_cast<long long>(pipelineLatencyMs),
                                criticalFrames,
                                static_cast<long long>(decodeTimeMs));
                }
            }
        } else {
            consecutiveCriticalPipelineFrames_.store(0, std::memory_order_relaxed);
        }
    } else {
        // 无 enqueueTimeMs 时也更新 lastOutputTimeMs_
        lastOutputTimeMs_.store(currentTimeMs);
        consecutiveCriticalPipelineFrames_.store(0, std::memory_order_relaxed);
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
    
    const int64_t currentTimeMs = GetSteadyTimeMs();
    
    // 节流：每 500ms 检查一次
    constexpr int64_t kHealthCheckIntervalMs = 500;
    int64_t lastCheck = lastHealthCheckTimeMs_.load();
    if (currentTimeMs - lastCheck < kHealthCheckIntervalMs) {
        return true;  // 在冷却期内，假定有效
    }
    lastHealthCheckTimeMs_.store(currentTimeMs);
    
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

int VideoDecoder::CheckLatencyRecovery(VideoFrameType frameType, int size, int frameNumber,
                                       uint16_t hostProcessingLatency) {
    bool isIFrame = (frameType == VideoFrameType::I_FRAME);
    if (isIFrame) {
        consecutiveCriticalPipelineFrames_.store(0, std::memory_order_relaxed);
    }
    
    // 收到 IDR 帧时重置恢复状态
    if (isIFrame && latencyRecoveryActive_.load()) {
        latencyRecoveryActive_.store(false);
        latencyRecoveryStartMs_.store(0);
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
        const int64_t currentTimeMs = GetSteadyTimeMs();
        int64_t startMs = latencyRecoveryStartMs_.load();
        if (startMs == 0) {
            latencyRecoveryStartMs_.store(currentTimeMs);
            startMs = currentTimeMs;
        }
        // 超时兜底：IDR 久未到达（可能请求或 IDR 本身在弱网下丢失），
        // 若继续盲丢所有 P 帧会造成长时间冻结。超时后恢复正常提交并补发一次 IDR 请求，
        // 宁可短暂出现参考链断裂的瑕疵，也不要长冻结。
        if (currentTimeMs - startMs > kLatencyRecoveryTimeoutMs) {
            latencyRecoveryActive_.store(false);
            latencyRecoveryStartMs_.store(0);
            // 重置陈旧的解码耗时读数：恢复期间无新解码，lastInstantDecodeTimeMs_ 仍是触发时的高值，
            // 若不清零，下方 L3 判定会立即用陈旧值再次触发，形成"丢 1s→放 1 帧→再丢"的抖动循环。
            lastInstantDecodeTimeMs_.store(0);
            LiRequestIdrFrame();
            OH_LOG_WARN(LOG_APP, "Latency recovery timeout (%{public}lldms), resuming submit and re-requesting IDR",
                        static_cast<long long>(currentTimeMs - startMs));
            // 不丢弃当前帧，落到下方正常处理逻辑
        } else {
            UpdateReceivedStats(size, frameNumber, hostProcessingLatency);
            RecordDroppedFrames(DropReason::L3);
            return -1;  // DR_NEED_IDR
        }
    }
    
    int64_t lastDecodeTime = lastInstantDecodeTimeMs_.load();
    double expectedFrameTimeMs = 1000.0 / config_.fps;
    double criticalThresholdMs = std::max(expectedFrameTimeMs * kCriticalLatencyMultiplier, kCriticalLatencyMinMs);
    
    // 检查是否已过启动阶段（避免初始化时的误触发）
    const uint64_t outputFrames = codecOutputFrames_.load(std::memory_order_relaxed);
    if (outputFrames < static_cast<uint64_t>(kLatencyRecoveryMinFrames)) {
        return 0;
    }
    
    // 临界延迟判断
    if (lastDecodeTime > static_cast<int64_t>(criticalThresholdMs)) {
        if (!latencyRecoveryActive_.exchange(true)) {
            OH_LOG_WARN(LOG_APP, "CRITICAL decode latency %{public}lldms > %.1fms threshold, requesting IDR recovery",
                        static_cast<long long>(lastDecodeTime), criticalThresholdMs);
        }
        
        // 更新接收统计（帧被接收但被丢弃）
        UpdateReceivedStats(size, frameNumber, hostProcessingLatency);
        RecordDroppedFrames(DropReason::L3);
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
    syncDrainEventsSinceLog_ = 0;
    syncDrainFramesSinceLog_ = 0;
    auto lastLogTime = std::chrono::steady_clock::now();
    
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
                render_->ResetPresentationClock();
                
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
        
        // Aggregate diagnostics off the congested path.
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastLogTime).count() >=
            kSyncLogIntervalMs) {
            size_t pendingFrames = 0;
            {
                std::lock_guard<std::mutex> lock(pendingFrameMutex_);
                pendingFrames = pendingFrameQueue_.size();
            }
            OH_LOG_INFO(LOG_APP,
                "Sync stats: queueIn=%{public}d, output=%{public}d, pending=%{public}zu, drainEvents=%{public}lld, drainFrames=%{public}lld",
                totalQueueInputSuccess, totalOutputSuccess, pendingFrames,
                static_cast<long long>(syncDrainEventsSinceLog_),
                static_cast<long long>(syncDrainFramesSinceLog_));
            syncDrainEventsSinceLog_ = 0;
            syncDrainFramesSinceLog_ = 0;
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
    PresentationTargetGuard presentationTarget(
        render_, frame.presentationTarget);
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

    presentationTarget.Commit();

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
            ApplyOutputHdrMetadata(format);
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
        OH_VideoDecoder_FreeOutputBuffer(decoder_, outputIndex);
        return -1;  // API 错误
    }
    
    // 获取 buffer 属性
    OH_AVCodecBufferAttr attr = {};
    if (OH_AVBuffer_GetBufferAttr(outputBuffer, &attr) != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "Sync: failed to get buffer attr");
        OH_VideoDecoder_FreeOutputBuffer(decoder_, outputIndex);
        return 0;
    }
    
    // 检查 EOS
    if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
        OH_LOG_INFO(LOG_APP, "Sync: received EOS");
        render_->DiscardPresentationFrame(attr.pts);
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
    
    struct QueuedFrame {
        uint32_t index;
        OH_AVCodecBufferAttr attr;
    };
    // Collect a bounded snapshot without releasing slots while querying. If a
    // released slot were reused immediately, an unbounded drain could chase the
    // decoder indefinitely and postpone presentation.
    static constexpr size_t kMaxDrainBatch = 32;
    std::array<QueuedFrame, kMaxDrainBatch> outputFrames;
    size_t totalFrames = 1;
    outputFrames[0] = {outputIndex, attr};

    while (running_ && syncDecodeRunning_ && totalFrames < outputFrames.size()) {
        uint32_t nextOutputIndex = 0;
        OH_AVErrCode nextRet = pfn_QueryOutputBuffer(decoder_, &nextOutputIndex, 0);
        if (nextRet != AV_ERR_OK) {
            break;  // 没有更多可用帧
        }
        
        OH_AVBuffer* nextBuffer = pfn_GetOutputBuffer(decoder_, nextOutputIndex);
        if (nextBuffer == nullptr) {
            OH_VideoDecoder_FreeOutputBuffer(decoder_, nextOutputIndex);
            break;
        }
        
        OH_AVCodecBufferAttr nextAttr;
        if (OH_AVBuffer_GetBufferAttr(nextBuffer, &nextAttr) != AV_ERR_OK) {
            OH_VideoDecoder_FreeOutputBuffer(decoder_, nextOutputIndex);
            break;
        }
        
        // EOS 帧不参与收集
        if (nextAttr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
            render_->DiscardPresentationFrame(nextAttr.pts);
            OH_VideoDecoder_FreeOutputBuffer(decoder_, nextOutputIndex);
            break;
        }
        
        outputFrames[totalFrames++] = {nextOutputIndex, nextAttr};
    }

    if (totalFrames > 1) {
        const uint64_t drainedCount = totalFrames - 1;
        for (size_t i = 0; i < drainedCount; ++i) {
            TakeEnqueueTimestamp(outputFrames[i].attr.pts);
            render_->DiscardPresentationFrame(outputFrames[i].attr.pts);
            OH_VideoDecoder_FreeOutputBuffer(decoder_, outputFrames[i].index);
        }
        RecordDroppedFrames(DropReason::L1, drainedCount);
        syncDrainEventsSinceLog_++;
        syncDrainFramesSinceLog_ += drainedCount;
        syncDrainEvents_.fetch_add(1, std::memory_order_relaxed);
        syncDrainFrames_.fetch_add(drainedCount, std::memory_order_relaxed);
    }

    const QueuedFrame& latestFrame = outputFrames[totalFrames - 1];
    const uint32_t latestIndex = latestFrame.index;
    const OH_AVCodecBufferAttr& latestAttr = latestFrame.attr;
    const int64_t pts = latestAttr.pts;
    const int64_t enqueueTimeMs = TakeEnqueueTimestamp(pts);
    const int64_t outputTimeMs = GetSteadyTimeMs();
    
    // Step 2 consumes only the newest decoded frame and looks up the target
    // prepared before decode. Drained targets are removed above.
    SubmitDecodedFrame(decoder_, latestIndex, latestAttr,
                       enqueueTimeMs, outputTimeMs);

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
    // SDR→HDR 配置
    bool g_sdrToHdr = false;
    float g_sdrToHdrPeakNits = 500.0f;
    float g_sdrToHdrSaturation = 1.3f;
    float g_sdrToHdrContrast = 1.0f;
}

namespace VideoDecoderInstance {
    // 超分辨率配置（跨实例保留，需外部可见）
    int g_upscaleMode = 0;       // UpscaleMode enum value
    float g_upscaleSharpness = 0.5f;
    // 暗区增强
    bool g_ditherEnabled = false;
}

namespace VideoDecoderInstance {

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
            mimeType = TryLoadAv1MimeType();
            break;
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
        render->SetConfiguredFps(fps);
        OH_LOG_INFO(LOG_APP, "VideoDecoder: NativeRender configured fps set to %.3f", fps);
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

// Convert frame type and preserve common-c host PTS for both decoder modes.
static void PrepareFrameSubmitParams(int frameType, int frameNumber, int64_t presentationTimeUs,
                                      VideoFrameType& outType, int64_t& outTimestamp) {
    // FRAME_TYPE_IDR = 1, FRAME_TYPE_I = 2
    outType = (frameType == 1 || frameType == 2) ? VideoFrameType::I_FRAME : VideoFrameType::P_FRAME;
    if (presentationTimeUs >= 0) {
        outTimestamp = presentationTimeUs;
    } else {
        double fps = (g_savedFps > 0) ? g_savedFps : 60.0;
        outTimestamp = static_cast<int64_t>(static_cast<double>(frameNumber) * 1000000.0 / fps);
    }
}

int SubmitDecodeUnit(const uint8_t* data, int size, int frameNumber, int frameType,
                     uint16_t hostProcessingLatency, int64_t presentationTimeUs) {
    if (g_videoDecoder == nullptr) {
        return -1;
    }
    
    VideoFrameType type;
    int64_t timestamp;
    PrepareFrameSubmitParams(frameType, frameNumber, presentationTimeUs, type, timestamp);
    
    return g_videoDecoder->SubmitDecodeUnit(data, size, frameNumber, type, timestamp, hostProcessingLatency);
}

int SubmitDecodeUnitScatter(const BufferSegment* segments, int segmentCount,
                            int totalSize, int frameNumber, int frameType,
                            uint16_t hostProcessingLatency, int64_t presentationTimeUs) {
    if (g_videoDecoder == nullptr) {
        return -1;
    }
    
    VideoFrameType type;
    int64_t timestamp;
    PrepareFrameSubmitParams(frameType, frameNumber, presentationTimeUs, type, timestamp);
    
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
    
    // 后处理管线：如果启用，初始化 GL 管线并使用代理 window
    OHNativeWindow* decoderWindow = g_savedWindow;
    GLPostProcessor* postProc = GLPostProcessor::GetInstance();
    // 从全局状态恢复所有后处理设置（实例在 Cleanup 中被销毁重建）
    postProc->SetSdrToHdr(g_sdrToHdr, g_sdrToHdrPeakNits, g_sdrToHdrSaturation, g_sdrToHdrContrast);
    postProc->SetDitherEnabled(g_ditherEnabled);
    postProc->SetUpscaleMode(static_cast<UpscaleMode>(g_upscaleMode));
    postProc->SetUpscaleSharpness(g_upscaleSharpness);
    OH_LOG_INFO(LOG_APP, "PostProc check: IsActive=%{public}d sdrToHdr=%{public}d dither=%{public}d upscaleMode=%{public}d",
                 postProc->IsActive() ? 1 : 0, postProc->IsSdrToHdr() ? 1 : 0,
                 g_ditherEnabled ? 1 : 0, g_upscaleMode);
    if (postProc->IsActive()) {
        // 设置 HDR 模式
        switch (g_hdrType) {
            case HdrType::HDR10:
                postProc->SetHdrMode(PostProcessHdrMode::PQ);
                break;
            case HdrType::HLG:
                postProc->SetHdrMode(PostProcessHdrMode::HLG);
                break;
            default:
                postProc->SetHdrMode(PostProcessHdrMode::SDR);
                break;
        }
        
        // 获取屏幕输出分辨率（超分辨率时使用）
        NativeRender* renderForUpscale = NativeRender::GetInstance();
        uint32_t outW = renderForUpscale ? static_cast<uint32_t>(renderForUpscale->GetSurfaceWidth()) : 0;
        uint32_t outH = renderForUpscale ? static_cast<uint32_t>(renderForUpscale->GetSurfaceHeight()) : 0;

        if (postProc->Init(g_savedWindow, config.width, config.height, outW, outH) == 0) {
            decoderWindow = postProc->GetDecoderWindow();
        } else {
            OH_LOG_WARN(LOG_APP, "Post-processing init failed, using direct rendering");
            postProc->SetDitherEnabled(false);
        }
    }
    
    // 初始化解码器
    int ret = g_videoDecoder->Init(config, decoderWindow);
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
    
    // 清理后处理管线
    GLPostProcessor::ReleaseInstance();
    
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

void SetHdrStaticMetadata(const Smpte2086Metadata* metadata) {
    std::lock_guard<std::mutex> lock(g_hdrStaticMetadataMutex);

    if (metadata == nullptr) {
        g_hasHdrStaticMetadata = false;
        g_hdrStaticMetadata = {};
        OH_LOG_INFO(LOG_APP, "SetHdrStaticMetadata: cleared");
        return;
    }

    g_hdrStaticMetadata = *metadata;
    g_hasHdrStaticMetadata = true;
    OH_LOG_INFO(LOG_APP, "SetHdrStaticMetadata: maxLum=%.3f, minLum=%.4f, maxCLL=%.3f, maxFALL=%.3f",
                metadata->maxLuminance, metadata->minLuminance,
                metadata->maxContentLightLevel, metadata->maxFrameAverageLightLevel);
}

void ResetHdrConfig() {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    g_enableHdr = false;
    g_hdrType = HdrType::SDR;
    g_colorSpace = 1;   // REC_709
    g_colorRange = 0;   // LIMITED
    {
        std::lock_guard<std::mutex> metadataLock(g_hdrStaticMetadataMutex);
        g_hasHdrStaticMetadata = false;
        g_hdrStaticMetadata = {};
    }
}

void SetBufferCount(int count) {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    // 限制有效范围: 0 (自动) 或 2-8
    if (count < 0) count = 0;
    if (count == 1) count = kMinBufferCount;
    if (count > kMaxBufferCount) count = kMaxBufferCount;
    
    g_bufferCount = count;
    OH_LOG_INFO(LOG_APP, "SetBufferCount: requested=%{public}d (%{public}s)",
                count, count == 0 ? "AUTO" : "MANUAL");
}

void SetSyncMode(bool syncMode) {
    std::lock_guard<std::mutex> lock(g_videoDecoderMutex);
    
    g_syncMode = syncMode;
    OH_LOG_INFO(LOG_APP, "SetSyncMode: %{public}s", syncMode ? "SYNC (ultra-low-latency, drain-to-latest)" : "ASYNC (default)");
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

void SetPostProcessEnabled(bool enabled) {
    g_ditherEnabled = enabled;
    GLPostProcessor* postProc = GLPostProcessor::GetInstance();
    postProc->SetDitherEnabled(enabled);
    OH_LOG_INFO(LOG_APP, "SetPostProcessEnabled: %{public}s", enabled ? "ON" : "OFF");
}

void SetUpscaleConfig(int mode, float sharpness) {
    g_upscaleMode = mode;
    g_upscaleSharpness = sharpness;
}

void SetSdrToHdr(bool enabled, float peakNits, float saturation, float contrast) {
    g_sdrToHdr = enabled;
    g_sdrToHdrPeakNits = peakNits;
    g_sdrToHdrSaturation = saturation;
    g_sdrToHdrContrast = contrast;
    OH_LOG_INFO(LOG_APP, "SetSdrToHdr: %{public}s peakNits=%.0f saturation=%.2f contrast=%.2f", enabled ? "ON" : "OFF", peakNits, saturation, contrast);
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
