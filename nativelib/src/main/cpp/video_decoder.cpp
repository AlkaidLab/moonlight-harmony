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
#include <qos/qos.h>

#define LOG_TAG "VideoDecoder"

// 是否启用异步渲染（通过 NativeRender）
// 启用后可利用 SetExpectedFrameRateRange 优化高帧率显示
static bool g_useAsyncRender = true;

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
// 输入超时：尝试获取输入 buffer 的等待时间，较短以保持低延迟
static constexpr int64_t kSyncInputTimeoutUs = 8000;   // 8ms - 允许更长等待以避免队列堆积
// 输出超时：等待解码输出的时间，稍长以确保能获取到帧
static constexpr int64_t kSyncOutputTimeoutUs = 5000;  // 5ms（约 120fps 半帧多）
// 直接提交失败时的最大重试次数
static constexpr int kMaxDirectSubmitRetries = 5;  // 增加重试次数

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
    // 直接报告实际帧率，让系统进行适当的资源调度
    // 注意：高帧率（如 120fps）可能触发系统特殊调度策略，这可能是期望的行为
    OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, config_.fps);
    OH_LOG_INFO(LOG_APP, "{Init} Reporting actual FPS %.2f to decoder", config_.fps);
    
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
    if (config_.enableVrr) {
        if (OH_MD_KEY_VIDEO_DECODER_OUTPUT_ENABLE_VRR != nullptr) {
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_DECODER_OUTPUT_ENABLE_VRR, 1);
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
    // OH_MD_KEY_ENABLE_SYNC_MODE 是 extern const char* 而不是宏，
    // 需要在运行时检查而不是编译时 #ifdef
    bool syncModeConfigured = false;
    bool needAsyncFallback = false;
    
    if (config_.decoderMode == DecoderMode::SYNC) {
        // 尝试启用同步模式 - OH_MD_KEY_ENABLE_SYNC_MODE 在 API 20+ 可用
        // 由于 availability 属性，如果 API < 20，符号地址为 nullptr
        if (OH_MD_KEY_ENABLE_SYNC_MODE != nullptr) {
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_ENABLE_SYNC_MODE, 1);
            syncModeConfigured = true;
            OH_LOG_INFO(LOG_APP, "{Init} Sync decode mode configured via OH_MD_KEY_ENABLE_SYNC_MODE");
        } else {
            OH_LOG_WARN(LOG_APP, "{Init} OH_MD_KEY_ENABLE_SYNC_MODE is nullptr (API < 20), falling back to async mode");
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
            case HdrType::HDR_VIVID: transferChar = kTransferCharHLG; break;
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
    
    // 配置 HDR Vivid 模式（对于 HLG 传输函数）
    if (config_.enableHdr && config_.hdrType == HdrType::HDR_VIVID) {
#ifdef OH_MD_KEY_VIDEO_IS_HDR_VIVID
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_IS_HDR_VIVID, 1);
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
                case HdrType::HDR_VIVID:  // HLG
                    windowColorSpace = isFullRange ? OH_COLORSPACE_BT2020_HLG_FULL : OH_COLORSPACE_BT2020_HLG_LIMIT;
                    metadataType = OH_VIDEO_HDR_HLG;
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
            int32_t colorGamut = (config_.hdrType == HdrType::HDR_VIVID) ?
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
    if (syncDecodeRunning_) {
        syncDecodeRunning_ = false;
        pendingFrameCond_.notify_all();
        if (syncDecodeThread_.joinable()) {
            syncDecodeThread_.join();
        }
    }
    
    if (decoder_ != nullptr) {
        OH_VideoDecoder_Stop(decoder_);
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
    
    OH_LOG_INFO(LOG_APP, "Video decoder cleaned up");
}

int VideoDecoder::SubmitDecodeUnit(const uint8_t* data, int size, 
                                    int frameNumber, VideoFrameType frameType,
                                    int64_t timestamp,
                                    uint16_t hostProcessingLatency) {
    if (!running_ || decoder_ == nullptr) {
        return -1;
    }
    
    // 首次调用时设置当前线程的 QoS 等级为高优先级
    static thread_local bool qosSet = false;
    if (!qosSet) {
        int ret = OH_QoS_SetThreadQoS(QOS_DEADLINE_REQUEST);
        if (ret == 0) {
            OH_LOG_INFO(LOG_APP, "Set decode thread QoS to DEADLINE_REQUEST");
        } else {
            ret = OH_QoS_SetThreadQoS(QOS_USER_INITIATED);
            if (ret == 0) {
                OH_LOG_INFO(LOG_APP, "Set decode thread QoS to USER_INITIATED");
            }
        }
        qosSet = true;
    }
    
    // 同步模式：直接提交到解码器（伪无队列模式）
    // 核心思路：尽量在网络回调线程中直接提交，减少队列延迟
    if (config_.decoderMode == DecoderMode::SYNC) {
        // 更新接收帧统计
        UpdateReceivedStats(size, hostProcessingLatency);
        
        if (!firstFrameReceived_) {
            firstFrameReceived_ = true;
            OH_LOG_INFO(LOG_APP, "First video frame (sync direct): %{public}dx%{public}d, syncRunning=%{public}d", 
                        config_.width, config_.height, syncDecodeRunning_ ? 1 : 0);
        }
        
        // 尝试直接提交到解码器
        // 注意：使用 running_ 而不是 syncDecodeRunning_，因为后者只在解码线程使用
        int retryCount = 0;
        while (retryCount < kMaxDirectSubmitRetries && running_) {
            uint32_t inputIndex = 0;
            OH_AVErrCode ret = OH_VideoDecoder_QueryInputBuffer(decoder_, &inputIndex, kSyncInputTimeoutUs);
            
            if (ret == AV_ERR_OK) {
                // 获得了输入 buffer，直接填充并提交
                OH_AVBuffer* inputBuffer = OH_VideoDecoder_GetInputBuffer(decoder_, inputIndex);
                if (inputBuffer == nullptr) {
                    OH_LOG_ERROR(LOG_APP, "Sync direct: GetInputBuffer failed");
                    retryCount++;
                    continue;
                }
                
                uint8_t* bufferAddr = OH_AVBuffer_GetAddr(inputBuffer);
                if (bufferAddr == nullptr) {
                    OH_LOG_ERROR(LOG_APP, "Sync direct: GetAddr failed");
                    retryCount++;
                    continue;
                }
                
                int32_t capacity = OH_AVBuffer_GetCapacity(inputBuffer);
                if (size > capacity) {
                    OH_LOG_ERROR(LOG_APP, "Sync direct: frame too large %{public}d > %{public}d", size, capacity);
                    return -1;
                }
                
                memcpy(bufferAddr, data, size);
                
                // 设置 buffer 属性
                OH_AVCodecBufferAttr attr = {0};
                attr.size = size;
                attr.offset = 0;
                attr.pts = timestamp;
                attr.flags = (frameType == VideoFrameType::I_FRAME) ? 
                             AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
                
                OH_AVBuffer_SetBufferAttr(inputBuffer, &attr);
                
                // 记录入队时间
                auto enqueueTimeMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now().time_since_epoch()).count();
                {
                    std::lock_guard<std::mutex> lock(timestampMutex_);
                    timestampToEnqueueTime_[timestamp] = enqueueTimeMs;
                    if (timestampToEnqueueTime_.size() > kMaxTimestampMapSize) {
                        timestampToEnqueueTime_.erase(timestampToEnqueueTime_.begin());
                    }
                }
                
                // 提交到解码器
                ret = OH_VideoDecoder_PushInputBuffer(decoder_, inputIndex);
                if (ret == AV_ERR_OK) {
                    // 直接提交成功
                    static int directSubmitCount = 0;
                    if (++directSubmitCount % 300 == 1) {
                        OH_LOG_INFO(LOG_APP, "Sync direct submit #%{public}d (frame %{public}d)", 
                                    directSubmitCount, frameNumber);
                    }
                    return 0;
                } else {
                    OH_LOG_WARN(LOG_APP, "Sync direct: PushInputBuffer failed %{public}d", ret);
                    retryCount++;
                }
            } else if (ret == AV_ERR_TRY_AGAIN_LATER) {
                // 解码器忙，重试
                retryCount++;
                static int tryAgainCount = 0;
                if (++tryAgainCount % 100 == 1) {
                    OH_LOG_DEBUG(LOG_APP, "Sync direct: TRY_AGAIN #%{public}d", tryAgainCount);
                }
            } else if (ret == AV_ERR_UNSUPPORT) {
                // 同步模式不支持
                OH_LOG_ERROR(LOG_APP, "Sync direct: AV_ERR_UNSUPPORT - sync mode not supported on this device!");
                // 回退到队列模式
                break;
            } else {
                // 其他错误
                OH_LOG_ERROR(LOG_APP, "Sync direct: QueryInputBuffer error %{public}d", ret);
                break;
            }
        }
        
        // 直接提交失败，使用极小队列作为后备
        // 这里只保留 1-2 帧的缓冲
        {
            std::lock_guard<std::mutex> lock(pendingFrameMutex_);
            
            // 队列满时丢弃最老的帧（保留最新帧以保持低延迟）
            while (pendingFrameQueue_.size() >= maxPendingFrames_) {
                pendingFrameQueue_.pop();
                std::lock_guard<std::mutex> statsLock(statsMutex_);
                stats_.droppedFrames++;
            }
            
            PendingFrame frame;
            frame.data.assign(data, data + size);
            frame.frameNumber = frameNumber;
            frame.frameType = frameType;
            frame.timestamp = timestamp;
            frame.hostProcessingLatency = hostProcessingLatency;
            
            pendingFrameQueue_.push(std::move(frame));
            pendingFrameCond_.notify_one();
            
            static int fallbackCount = 0;
            if (++fallbackCount % 100 == 1) {
                OH_LOG_INFO(LOG_APP, "Sync fallback to queue #%{public}d (queueSize=%{public}zu)", 
                            fallbackCount, pendingFrameQueue_.size());
            }
        }
        
        return 0;
    }
    
    // 异步模式：原有逻辑
    auto startTime = std::chrono::high_resolution_clock::now();
    
    // 获取输入缓冲区
    uint32_t inputIndex;
    OH_AVBuffer* inputBuffer = nullptr;
    
    {
        std::unique_lock<std::mutex> lock(inputMutex_);
        // 使用固定超时值，高帧率下也能保证缓冲区获取成功
        int timeoutMs = kMaxTimeoutMs;
        
        if (inputIndexQueue_.empty()) {
            if (!inputCond_.wait_for(lock, std::chrono::milliseconds(timeoutMs), 
                [this] { return !inputIndexQueue_.empty() || !running_; })) {
                if (config_.fps > kHighFpsThreshold) {
                    OH_LOG_DEBUG(LOG_APP, "Buffer timeout, dropping frame %{public}d", frameNumber);
                } else {
                    OH_LOG_WARN(LOG_APP, "Buffer timeout, dropping frame %{public}d", frameNumber);
                }
                std::lock_guard<std::mutex> statsLock(statsMutex_);
                stats_.droppedFrames++;
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
    
    // 填充输入数据
    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(inputBuffer);
    if (bufferAddr == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to get input buffer address");
        return -1;
    }
    
    int32_t bufferCapacity = OH_AVBuffer_GetCapacity(inputBuffer);
    if (size > bufferCapacity) {
        OH_LOG_ERROR(LOG_APP, "Frame size %{public}d > buffer capacity %{public}d", size, bufferCapacity);
        return -1;
    }
    
    memcpy(bufferAddr, data, size);
    
    // 设置缓冲区属性
    OH_AVCodecBufferAttr attr = {0};
    attr.size = size;
    attr.offset = 0;
    attr.pts = timestamp;
    
    if (frameType == VideoFrameType::I_FRAME) {
        attr.flags = AVCODEC_BUFFER_FLAGS_SYNC_FRAME;
    } else {
        attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
    }
    
    OH_AVBuffer_SetBufferAttr(inputBuffer, &attr);
    
    // 记录入队时间
    auto enqueueTimeMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    {
        std::lock_guard<std::mutex> lock(timestampMutex_);
        timestampToEnqueueTime_[timestamp] = enqueueTimeMs;
        if (timestampToEnqueueTime_.size() > kMaxTimestampMapSize) {
            timestampToEnqueueTime_.erase(timestampToEnqueueTime_.begin());
        }
    }
    
    // 提交输入缓冲区
    int32_t ret = OH_VideoDecoder_PushInputBuffer(decoder_, inputIndex);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to push input buffer: %{public}d", ret);
        return -1;
    }
    
    // 更新接收帧统计
    UpdateReceivedStats(size, hostProcessingLatency);
    
    if (!firstFrameReceived_) {
        firstFrameReceived_ = true;
        OH_LOG_INFO(LOG_APP, "First video frame: %{public}dx%{public}d", config_.width, config_.height);
    }
    
    return 0;
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
    if (render != nullptr && render->IsVsyncEnabled()) {
        // VSync 模式：使用 RenderOutputBufferAtTime 计算呈现时间
        int64_t presentTimeNs = render->CalculatePresentTime(pts);
        OH_VideoDecoder_RenderOutputBufferAtTime(codec, index, presentTimeNs);
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
        int64_t decodeTimeMs = currentTimeMs - enqueueTimeMs;
        if (decodeTimeMs >= 0 && decodeTimeMs < kMaxValidDecodeTimeMs) {
            bool isKeyframe = (flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) != 0;
            
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
    }
}

void VideoDecoder::SyncDecodeLoop() {
    OH_LOG_INFO(LOG_APP, "Sync decode loop started (output-focused mode), decoder=%{public}p", static_cast<void*>(decoder_));
    
    // 设置线程 QoS 为高优先级
    int qosRet = OH_QoS_SetThreadQoS(QOS_DEADLINE_REQUEST);
    if (qosRet != 0) {
        OH_QoS_SetThreadQoS(QOS_USER_INITIATED);
    }
    OH_LOG_INFO(LOG_APP, "Sync decode thread QoS set, syncRunning=%{public}d, running=%{public}d", 
                syncDecodeRunning_ ? 1 : 0, running_ ? 1 : 0);
    
    int consecutiveOutputErrors = 0;
    const int maxConsecutiveErrors = 50;
    bool firstFrameRendered = false;
    int totalQueueInputSuccess = 0;  // 从后备队列提交的帧数
    int totalOutputSuccess = 0;
    
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
            int inputResult = SyncProcessInput(kSyncInputTimeoutUs);
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
        int outputResult = SyncProcessOutput(kSyncOutputTimeoutUs);
        if (outputResult > 0) {
            totalOutputSuccess++;
            consecutiveOutputErrors = 0;
            if (!firstFrameRendered) {
                firstFrameRendered = true;
                OH_LOG_INFO(LOG_APP, "Sync decode: first frame rendered!");
            }
        } else if (outputResult < 0) {
            consecutiveOutputErrors++;
        } else {
            // outputResult == 0, 无输出帧，短暂让出 CPU
            // 使用条件变量等待，或在收到新帧时被唤醒
            std::unique_lock<std::mutex> lock(pendingFrameMutex_);
            if (pendingFrameQueue_.empty() && syncDecodeRunning_) {
                // 等待新帧到达或超时（约半帧时间 @120fps）
                pendingFrameCond_.wait_for(lock, std::chrono::microseconds(4000));
            }
        }
        
        // 统计日志（每秒一次）
        static auto lastLogTime = std::chrono::steady_clock::now();
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
    
    // 有帧要处理，先查询输入 buffer
    uint32_t inputIndex = 0;
    OH_AVErrCode ret = OH_VideoDecoder_QueryInputBuffer(decoder_, &inputIndex, timeoutUs);
    
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
    OH_AVBuffer* inputBuffer = OH_VideoDecoder_GetInputBuffer(decoder_, inputIndex);
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
    OH_AVCodecBufferAttr attr = {0};
    attr.size = static_cast<int32_t>(frame.data.size());
    attr.offset = 0;
    attr.pts = frame.timestamp;
    attr.flags = (frame.frameType == VideoFrameType::I_FRAME) ? 
                 AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
    
    OH_AVBuffer_SetBufferAttr(inputBuffer, &attr);
    
    // 记录入队时间
    auto enqueueTimeMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    {
        std::lock_guard<std::mutex> lock(timestampMutex_);
        timestampToEnqueueTime_[frame.timestamp] = enqueueTimeMs;
        if (timestampToEnqueueTime_.size() > kMaxTimestampMapSize) {
            timestampToEnqueueTime_.erase(timestampToEnqueueTime_.begin());
        }
    }
    
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
    
    // 使用同步 API 获取输出 buffer
    uint32_t outputIndex = 0;
    OH_AVErrCode ret = OH_VideoDecoder_QueryOutputBuffer(decoder_, &outputIndex, timeoutUs);
    
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
    OH_AVBuffer* outputBuffer = OH_VideoDecoder_GetOutputBuffer(decoder_, outputIndex);
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
    
    int64_t pts = attr.pts;
    
    // 检查 EOS
    if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
        OH_LOG_INFO(LOG_APP, "Sync: received EOS");
        OH_VideoDecoder_FreeOutputBuffer(decoder_, outputIndex);
        return 0;  // EOS 不是错误
    }
    
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
    UpdateDecodedStats(pts, enqueueTimeMs, attr.flags);
    
    // 注意：同步模式追求最低延迟，不做软件帧率限制
    // 帧率限制通过 SetExpectedFrameRateRange 在系统层面实现
    
    // 渲染帧 - 同步模式：始终使用立即渲染以确保最低延迟和 buffer 快速释放
    // 注意：不使用 RenderOutputBufferAtTime，因为定时渲染会占用 buffer 直到呈现时间
    // 这可能导致解码器内部 buffer 耗尽，进而阻塞输入
    ret = OH_VideoDecoder_RenderOutputBuffer(decoder_, outputIndex);
    if (ret != AV_ERR_OK) {
        // 如果渲染失败，必须释放 buffer，否则解码器会卡住
        OH_LOG_WARN(LOG_APP, "Sync: render failed (%{public}d), freeing buffer", ret);
        OH_VideoDecoder_FreeOutputBuffer(decoder_, outputIndex);
        return 0;  // buffer 被释放但未成功渲染
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
    
    // 尝试创建解码器
    OH_AVCodec* testDecoder = OH_VideoDecoder_CreateByMime(mimeType);
    if (testDecoder != nullptr) {
        OH_VideoDecoder_Destroy(testDecoder);
        return true;
    }
    return false;
}

// 获取解码器能力
DecoderCapabilities GetCapabilities() {
    DecoderCapabilities caps = {};
    
    caps.supportsH264 = IsCodecSupported(VideoCodecType::H264);
    caps.supportsHEVC = IsCodecSupported(VideoCodecType::HEVC);
    caps.supportsAV1 = IsCodecSupported(VideoCodecType::AV1);
    
    // 默认最大分辨率（大多数设备支持 4K）
    caps.maxWidth = 3840;
    caps.maxHeight = 2160;
    caps.maxFps = 60;
    
    OH_LOG_INFO(LOG_APP, "Decoder caps: H264=%{public}d, HEVC=%{public}d, AV1=%{public}d", 
                caps.supportsH264, caps.supportsHEVC, caps.supportsAV1);
    
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

int SubmitDecodeUnit(const uint8_t* data, int size, int frameNumber, int frameType, uint16_t hostProcessingLatency) {
    if (g_videoDecoder == nullptr) {
        return -1;
    }
    
    // FRAME_TYPE_IDR = 1, FRAME_TYPE_I = 2
    VideoFrameType type = (frameType == 1 || frameType == 2) ? VideoFrameType::I_FRAME : VideoFrameType::P_FRAME;
    
    // 计算时间戳（基于帧号，假设 60fps）
    int64_t timestamp = static_cast<int64_t>(frameNumber) * 1000000LL / 60;
    
    return g_videoDecoder->SubmitDecodeUnit(data, size, frameNumber, type, timestamp, hostProcessingLatency);
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
        case 2:  g_hdrType = HdrType::HDR_VIVID; break;
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
    
    // 检查当前状态并尝试恢复
    // 重新启动解码器（如果已暂停）
    int ret = g_videoDecoder->Start();
    if (ret == 0) {
        OH_LOG_INFO(LOG_APP, "Resume: 解码器恢复成功");
    } else {
        OH_LOG_WARN(LOG_APP, "Resume: 解码器恢复可能已处于运行状态 (ret=%{public}d)", ret);
    }
}

} // namespace VideoDecoderInstance
