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
 * @file opus_libopus.h
 * @brief libopus 直接调用的 Opus 解码器
 * 
 * 使用 libopus 原生 API 进行 Opus 解码
 * 优势：原生 PLC（丢包补偿）、同步调用零延迟、代码简洁
 */

#ifndef OPUS_LIBOPUS_H
#define OPUS_LIBOPUS_H

extern "C" {
#include "moonlight-common-c/src/Limelight.h"
}

/**
 * 全局 Opus 解码器实例
 */
namespace MoonlightOpusDecoder {
    /**
     * 初始化解码器
     * @param opusConfig Opus 多流配置（采样率、通道数、流数、mapping 等）
     * @return 0 成功，负数失败
     */
    int Init(POPUS_MULTISTREAM_CONFIGURATION opusConfig);
    
    /**
     * 解码 Opus 数据
     * @param opusData 输入 Opus 数据（NULL 表示丢包，触发 PLC）
     * @param opusLength 数据长度
     * @param pcmOut 输出 PCM 缓冲区（调用者分配）
     * @param maxSamples 最大采样数（per channel）
     * @return 解码的采样数（per channel），负数表示失败
     */
    int Decode(const unsigned char* opusData, int opusLength,
               short* pcmOut, int maxSamples);
    
    /**
     * 清理解码器
     */
    void Cleanup();
    
    /**
     * 获取通道数
     */
    int GetChannelCount();
    
    /**
     * 获取每帧采样数
     */
    int GetSamplesPerFrame();
}

#endif // OPUS_LIBOPUS_H
