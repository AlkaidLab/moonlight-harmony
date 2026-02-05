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
 * 麦克风捕获器
 * 使用 HarmonyOS AudioCapturer API 捕获 PCM 音频数据
 */
import { audio } from '@kit.AudioKit';
import { MicrophoneConfig, MicrophoneState } from './MicrophoneConfig';

const TAG = '[MicCapturer]';

/**
 * 麦克风数据回调接口
 */
export interface MicrophoneDataCallback {
  /**
   * 当有音频数据可用时调用
   * @param data PCM 音频数据
   * @param length 数据长度
   */
  onMicrophoneData(data: ArrayBuffer, length: number): void;
}

/**
 * 麦克风捕获器
 * 负责从系统麦克风捕获 PCM 音频数据
 */
export class MicrophoneCapturer {
  private audioCapturer: audio.AudioCapturer | null = null;
  private dataCallback: MicrophoneDataCallback | null = null;
  private running: boolean = false;
  private state: MicrophoneState = MicrophoneState.STOPPED;
  
  // 帧缓冲区 - 用于累积完整的 Opus 帧
  private frameBuffer: ArrayBuffer;
  private frameBufferView: Uint8Array;
  private frameBufferPos: number = 0;
  
  // 统计信息
  private frameCount: number = 0;
  private lastLogTime: number = 0;
  
  constructor(callback: MicrophoneDataCallback) {
    this.dataCallback = callback;
    // 初始化帧缓冲区
    this.frameBuffer = new ArrayBuffer(MicrophoneConfig.BYTES_PER_FRAME);
    this.frameBufferView = new Uint8Array(this.frameBuffer);
  }
  
  /**
   * 获取当前状态
   */
  getState(): MicrophoneState {
    return this.state;
  }
  
  /**
   * 是否正在运行
   */
  isRunning(): boolean {
    return this.running;
  }
  
  /**
   * 启动麦克风捕获
   */
  async start(): Promise<boolean> {
    if (this.running) {
      console.info(TAG, '麦克风捕获已在运行');
      return true;
    }
    
    this.state = MicrophoneState.INITIALIZING;
    
    try {
      // 配置 AudioCapturer
      const audioStreamInfo: audio.AudioStreamInfo = {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      };
      
      const audioCapturerInfo: audio.AudioCapturerInfo = {
        // 使用 VOICE_COMMUNICATION 以获得更好的回声消除效果
        source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION,
        capturerFlags: 0
      };
      
      const audioCapturerOptions: audio.AudioCapturerOptions = {
        streamInfo: audioStreamInfo,
        capturerInfo: audioCapturerInfo
      };
      
      console.info(TAG, `创建 AudioCapturer: 采样率=${MicrophoneConfig.SAMPLE_RATE}, 通道=${MicrophoneConfig.CHANNELS}`);
      
      // 创建 AudioCapturer
      this.audioCapturer = await audio.createAudioCapturer(audioCapturerOptions);
      
      if (!this.audioCapturer) {
        console.error(TAG, '创建 AudioCapturer 失败');
        this.state = MicrophoneState.ERROR;
        return false;
      }
      
      // 设置回调
      this.audioCapturer.on('readData', (buffer: ArrayBuffer) => {
        this.processAudioData(buffer);
      });
      
      // 监听状态变化
      this.audioCapturer.on('stateChange', (state: audio.AudioState) => {
        console.info(TAG, `AudioCapturer 状态变化: ${state}`);
      });
      
      // 启动捕获
      await this.audioCapturer.start();
      
      this.running = true;
      this.state = MicrophoneState.CAPTURING;
      this.frameCount = 0;
      this.lastLogTime = Date.now();
      
      console.info(TAG, '麦克风捕获已启动');
      return true;
      
    } catch (error) {
      console.error(TAG, `启动麦克风捕获失败: ${error}`);
      this.state = MicrophoneState.ERROR;
      await this.release();
      return false;
    }
  }
  
  /**
   * 处理音频数据
   * 累积数据直到达到完整的 Opus 帧大小
   */
  private processAudioData(buffer: ArrayBuffer): void {
    if (!this.running || !this.dataCallback) {
      return;
    }
    
    const data = new Uint8Array(buffer);
    let dataOffset = 0;
    let remainingBytes = data.length;
    
    while (remainingBytes > 0) {
      // 计算当前帧还需要多少字节
      const bytesNeeded = MicrophoneConfig.BYTES_PER_FRAME - this.frameBufferPos;
      const bytesToCopy = Math.min(remainingBytes, bytesNeeded);
      
      // 复制数据到帧缓冲区
      this.frameBufferView.set(
        data.subarray(dataOffset, dataOffset + bytesToCopy),
        this.frameBufferPos
      );
      this.frameBufferPos += bytesToCopy;
      dataOffset += bytesToCopy;
      remainingBytes -= bytesToCopy;
      
      // 如果帧缓冲区满了，发送完整的帧
      if (this.frameBufferPos >= MicrophoneConfig.BYTES_PER_FRAME) {
        // 发送帧数据
        this.dataCallback.onMicrophoneData(
          this.frameBuffer.slice(0),  // 复制一份避免并发问题
          MicrophoneConfig.BYTES_PER_FRAME
        );
        
        // 重置缓冲区
        this.frameBufferPos = 0;
        this.frameCount++;
        
        // 每 5 秒记录一次统计信息
        const now = Date.now();
        if (now - this.lastLogTime >= 5000) {
          const elapsed = (now - this.lastLogTime) / 1000;
          const fps = this.frameCount / elapsed;
          console.info(TAG, `麦克风统计: ${this.frameCount} 帧, ${fps.toFixed(1)} fps`);
          this.frameCount = 0;
          this.lastLogTime = now;
        }
      }
    }
  }
  
  /**
   * 暂停捕获
   */
  async pause(): Promise<void> {
    if (this.audioCapturer && this.state === MicrophoneState.CAPTURING) {
      try {
        await this.audioCapturer.stop();
        this.state = MicrophoneState.PAUSED;
        console.info(TAG, '麦克风捕获已暂停');
      } catch (error) {
        console.error(TAG, `暂停麦克风捕获失败: ${error}`);
      }
    }
  }
  
  /**
   * 恢复捕获
   */
  async resume(): Promise<void> {
    if (this.audioCapturer && this.state === MicrophoneState.PAUSED) {
      try {
        await this.audioCapturer.start();
        this.state = MicrophoneState.CAPTURING;
        console.info(TAG, '麦克风捕获已恢复');
      } catch (error) {
        console.error(TAG, `恢复麦克风捕获失败: ${error}`);
      }
    }
  }
  
  /**
   * 停止捕获
   */
  async stop(): Promise<void> {
    this.running = false;
    
    if (this.audioCapturer) {
      try {
        await this.audioCapturer.stop();
      } catch (error) {
        console.warn(TAG, `停止 AudioCapturer 时出错: ${error}`);
      }
    }
    
    this.state = MicrophoneState.STOPPED;
    this.frameBufferPos = 0;
    console.info(TAG, '麦克风捕获已停止');
  }
  
  /**
   * 释放资源
   */
  async release(): Promise<void> {
    await this.stop();
    
    if (this.audioCapturer) {
      try {
        await this.audioCapturer.release();
      } catch (error) {
        console.warn(TAG, `释放 AudioCapturer 时出错: ${error}`);
      }
      this.audioCapturer = null;
    }
    
    this.dataCallback = null;
    console.info(TAG, '麦克风捕获器已释放');
  }
}
