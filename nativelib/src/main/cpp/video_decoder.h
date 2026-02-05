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
 * @file video_decoder.h
 * @brief HarmonyOS AVCodec 视频解码器
 * 
 * 使用 HarmonyOS 原生 AVCodec API 进行 H.264/HEVC 视频解码
 * 支持硬件加速解码到 Surface
 */

#ifndef VIDEO_DECODER_H
#define VIDEO_DECODER_H

#include <cstdint>
#include <mutex>
#include <queue>
#include <thread>
#include <atomic>
#include <condition_variable>
#include <unordered_map>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <native_window/external_window.h>
#include <native_buffer/native_buffer.h>
#include <hilog/log.h>

/**
 * 视频帧类型
 */
enum class VideoFrameType {
    UNKNOWN = 0,
    I_FRAME = 1,    // 关键帧
    P_FRAME = 2,    // 预测帧
    B_FRAME = 3     // 双向预测帧
};

/**
 * 视频编码格式
 */
enum class VideoCodecType {
    H264 = 0,
    HEVC = 1,       // H.265
    AV1 = 2
};

/**
 * 颜色空间定义（与 moonlight-common-c 一致）
 */
enum class ColorSpace {
    REC_601 = 0,
    REC_709 = 1,
    REC_2020 = 2
};

/**
 * 颜色范围定义
 */
enum class ColorRange {
    LIMITED = 0,
    FULL = 1
};

/**
 * HDR 类型定义
 */
enum class HdrType {
    SDR = 0,        // 标准动态范围
    HDR10 = 1,      // HDR10 (PQ 传输特性)
    HDR_VIVID = 2   // HDR Vivid (HLG 传输特性，支持动态元数据)
};

/**
 * 解码器工作模式
 */
enum class DecoderMode {
    ASYNC = 0,    // 异步模式：使用回调获取 buffer (默认，兼容性好)
    SYNC = 1      // 同步模式：主动轮询 buffer (API 20+，低延迟)
};

/**
 * 解码器配置
 */
struct VideoDecoderConfig {
    int width;
    int height;
    double fps;           // 帧率（支持小数，如 59.94）
    VideoCodecType codec;
    bool enableHdr;
    HdrType hdrType;      // HDR 类型
    ColorSpace colorSpace;
    ColorRange colorRange;
    int bufferCount;      // 解码器缓冲区数量 (0=系统默认，2-8=指定数量)
    bool enableVsync;     // 启用垂直同步（使用 RenderOutputBufferAtTime）
    DecoderMode decoderMode;  // 解码器工作模式 (同步/异步)
    bool enableVrr;       // VRR (Variable Refresh Rate) 可变刷新率模式
                          // 启用后解码器输出将适配可变刷新率显示
                          // 注意：VRR 可能会丢帧以匹配屏幕刷新率，主要用于节能
};

/**
 * VSync 渲染模式
 */
enum class VsyncMode {
    OFF = 0,      // 关闭：立即渲染 (最低延迟，可能撕裂)
    ON = 1,       // 开启：使用 RenderOutputBufferAtTime 进行精确帧呈现
    AUTO = 2      // 自动：根据帧率决定 (高帧率时关闭以降低延迟)
};

/**
 * 解码统计信息
 */
struct VideoDecoderStats {
    uint64_t totalFrames;        // 接收到的帧数
    uint64_t decodedFrames;      // 解码完成的帧数（渲染的帧）
    uint64_t droppedFrames;
    double averageDecodeTimeMs;
    double maxDecodeTimeMs;
    // 用于接收 FPS 计算
    uint64_t lastFrameCount;
    int64_t lastFpsCalculationTime;  // 毫秒
    double currentFps;           // 接收帧率 (Rx)
    // 用于渲染 FPS 计算
    uint64_t lastDecodedFrameCount;
    int64_t lastRenderedFpsCalculationTime;
    double renderedFps;          // 渲染帧率 (Rd)
    // 用于码率计算
    uint64_t totalBytesReceived;
    uint64_t lastBytesCount;
    int64_t lastBitrateCalculationTime;
    double currentBitrate;  // bps
    // 主机处理延迟统计（来自服务器）
    uint64_t framesWithHostLatency;      // 有主机延迟数据的帧数
    double totalHostProcessingLatency;   // 累计主机处理延迟（ms）
    double avgHostProcessingLatency;     // 平均主机处理延迟（ms）
};

/**
 * AVCodec 视频解码器封装类
 */
class VideoDecoder {
public:
    VideoDecoder();
    ~VideoDecoder();
    
    /**
     * 初始化解码器
     * @param config 解码器配置
     * @param window 渲染窗口（来自 XComponent）
     * @return 0 成功，负数失败
     */
    int Init(const VideoDecoderConfig& config, OHNativeWindow* window);
    
    /**
     * 提交解码单元（视频帧数据）
     * @param data 帧数据
     * @param size 数据大小
     * @param frameNumber 帧号
     * @param frameType 帧类型
     * @param timestamp 时间戳（微秒）
     * @param hostProcessingLatency 主机处理延迟（1/10 ms 单位），0 表示无效
     * @return 0 成功，负数失败
     */
    int SubmitDecodeUnit(const uint8_t* data, int size, 
                          int frameNumber, VideoFrameType frameType,
                          int64_t timestamp,
                          uint16_t hostProcessingLatency = 0);
    
    /**
     * 启动解码器
     */
    int Start();
    
    /**
     * 停止解码器
     */
    int Stop();
    
    /**
     * 清理解码器
     */
    void Cleanup();
    
    /**
     * 刷新解码器（清空缓冲区）
     */
    int Flush();
    
    /**
     * 获取解码统计信息
     */
    VideoDecoderStats GetStats() const;
    
    /**
     * 检查是否已初始化
     */
    bool IsInitialized() const { return decoder_ != nullptr; }
    
    /**
     * 检查是否正在运行
     */
    bool IsRunning() const { return running_; }

private:
    // AVCodec 回调
    static void OnError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void OnOutputFormatChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void OnInputBufferAvailable(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* data, void* userData);
    static void OnOutputBufferAvailable(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* data, void* userData);
    
    // 获取 MIME 类型
    const char* GetMimeType(VideoCodecType codec) const;
    
    // 同步模式解码循环
    void SyncDecodeLoop();
    
    // 同步模式输入处理
    // 返回值: 1=成功, 0=正常等待/无数据, -1=API错误
    int SyncProcessInput(int64_t timeoutUs);
    
    // 同步模式输出处理
    // 返回值: 1=成功, 0=正常等待/无数据, -1=API错误
    int SyncProcessOutput(int64_t timeoutUs);
    
    // 更新接收帧统计
    void UpdateReceivedStats(int size, uint16_t hostProcessingLatency);
    
    // 更新解码帧统计
    void UpdateDecodedStats(int64_t pts, int64_t enqueueTimeMs, uint32_t flags);
    
    // 解码器实例
    OH_AVCodec* decoder_ = nullptr;
    
    // 渲染窗口
    OHNativeWindow* window_ = nullptr;
    
    // 配置
    VideoDecoderConfig config_;
    
    // 输入缓冲区队列（异步模式使用）
    std::mutex inputMutex_;
    std::condition_variable inputCond_;
    std::queue<uint32_t> inputIndexQueue_;
    std::queue<OH_AVBuffer*> inputBufferQueue_;
    
    // 同步模式使用的待解码帧队列
    struct PendingFrame {
        std::vector<uint8_t> data;
        int frameNumber;
        VideoFrameType frameType;
        int64_t timestamp;
        uint16_t hostProcessingLatency;
    };
    std::mutex pendingFrameMutex_;
    std::condition_variable pendingFrameCond_;
    std::queue<PendingFrame> pendingFrameQueue_;
    // 动态队列大小，根据用户设置的 bufferCount 决定
    // 如果用户设置为 0（默认），使用 2（最低延迟）；否则使用用户设置值
    size_t maxPendingFrames_{2};  // 由 Init() 根据 config_.bufferCount 设置
    
    // 同步模式解码线程
    std::thread syncDecodeThread_;
    std::atomic<bool> syncDecodeRunning_{false};
    
    // 帧率限制相关
    std::chrono::steady_clock::time_point lastFrameTime_;
    int64_t frameIntervalUs_{0};  // 目标帧间隔（微秒），0 表示不限制
    
    // 帧时间戳到入队时间的映射（用于计算解码时间）
    std::mutex timestampMutex_;
    std::unordered_map<int64_t, int64_t> timestampToEnqueueTime_;
    
    // 统计信息
    mutable std::mutex statsMutex_;
    VideoDecoderStats stats_;
    
    // 运行状态
    std::atomic<bool> running_{false};
    std::atomic<bool> configured_{false};
    
    // 首帧标志
    std::atomic<bool> firstFrameReceived_{false};
};

/**
 * 解码器能力信息
 */
struct DecoderCapabilities {
    bool supportsH264;
    bool supportsHEVC;
    bool supportsAV1;
    int maxWidth;
    int maxHeight;
    int maxFps;
};

/**
 * 全局视频解码器实例（简化接口）
 */
namespace VideoDecoderInstance {
    /**
     * 检测解码器能力
     */
    DecoderCapabilities GetCapabilities();
    
    /**
     * 检测是否支持指定的编解码器
     */
    bool IsCodecSupported(VideoCodecType codec);
    
    /**
     * 初始化解码器（从 moonlight-common-c 回调调用，不带 window）
     * @param fps 帧率（支持小数，如 59.94）
     */
    int Init(int videoFormat, int width, int height, double fps, void* window);
    
    /**
     * 初始化解码器（从 NAPI 调用，带 OHNativeWindow）
     */
    bool Init(OHNativeWindow* window);
    
    /**
     * 设置视频参数（从 moonlight-common-c 回调调用）
     * @param fps 帧率（支持小数，如 59.94）
     */
    int Setup(int videoFormat, int width, int height, double fps);
    
    /**
     * 设置 HDR 配置
     * @param enableHdr 是否启用 HDR
     * @param hdrType HDR 类型 (0=SDR, 1=HDR10, 2=HDR_VIVID)
     * @param colorSpace 颜色空间 (0=REC_601, 1=REC_709, 2=REC_2020)
     * @param colorRange 颜色范围 (0=Limited, 1=Full)
     */
    void SetHdrConfig(bool enableHdr, int hdrType, int colorSpace, int colorRange);
    
    /**
     * 重置 HDR 配置到默认值 (SDR)
     * 在串流会话完全结束时调用，而不是在解码器重建时调用
     */
    void ResetHdrConfig();
    
    /**
     * 设置解码器缓冲区数量
     * @param count 缓冲区数量 (0=系统默认值，2-8=指定数量)
     */
    void SetBufferCount(int count);
    
    /**
     * 设置解码器工作模式
     * @param syncMode 是否使用同步模式 (true=同步模式，低延迟; false=异步模式，默认)
     * 同步模式需要 API 20+，使用主动轮询代替回调，可减少约 1-3ms 延迟
     */
    void SetSyncMode(bool syncMode);
    
    /**
     * 设置 VRR (Variable Refresh Rate) 可变刷新率模式
     * @param enabled 是否启用 VRR
     * 
     * 启用后解码器输出将适配可变刷新率显示，根据视频内容动态调整屏幕刷新率。
     * 
     * 注意：
     * 1. 只支持硬件解码后直接送显的场景
     * 2. 当刷新率小于视频帧率时，会丢弃部分视频帧以节省功耗
     * 3. 游戏串流场景下可能不适合（丢帧会影响体验）
     * 4. 需要 API 15+ (HarmonyOS) 支持
     */
    void SetVrrEnabled(bool enabled);
    
    /**
     * 设置精确帧率（支持小数，如 59.94）
     * 用于帧率限制功能精确计算帧间隔
     * @param fps 精确帧率
     */
    void SetPreciseFps(double fps);
    
    /**
     * 获取当前解码器模式
     */
    bool IsSyncMode();
    
    /**
     * 提交解码单元
     * @param hostProcessingLatency 主机处理延迟（1/10 ms 单位）
     */
    int SubmitDecodeUnit(const uint8_t* data, int size, int frameNumber, int frameType, uint16_t hostProcessingLatency = 0);
    
    /**
     * 启动解码器
     */
    int Start();
    
    /**
     * 停止解码器
     */
    int Stop();
    
    /**
     * 清理解码器
     */
    void Cleanup();
    
    /**
     * 获取统计信息
     */
    VideoDecoderStats GetStats();
    
    /**
     * 从后台恢复解码器
     * 当应用从后台切回前台时调用
     */
    void Resume();
}

#endif // VIDEO_DECODER_H