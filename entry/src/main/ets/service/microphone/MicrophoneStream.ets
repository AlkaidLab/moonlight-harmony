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
 * 麦克风数据流
 * 整合麦克风捕获、Opus 编码和网络发送
 *
 * 重要：根据 HarmonyOS 官方文档，readData 回调中不应执行耗时任务
 * 因此采用异步队列模式：
 * 1. readData 回调只将数据加入队列（非阻塞）
 * 2. 单独的处理循环负责 Opus 编码和网络发送
 */
import { MoonBridge, MoonBridgeClass } from '../MoonBridge';
import { MicrophoneConfig, MicrophoneState, MicrophoneStateListener } from './MicrophoneConfig';
import { MicrophoneCapturer, MicrophoneDataCallback } from './MicrophoneCapturer';

const TAG = '[MicStream]';

// 音频帧队列项
interface AudioFrame {
  data: ArrayBuffer;
  length: number;
  timestamp: number;
}

/**
 * 预分配的缓冲池
 * 避免在高频回调中频繁创建 ArrayBuffer 导致 GC 压力
 */
class BufferPool {
  private pool: ArrayBuffer[] = [];
  private readonly bufferSize: number;
  private readonly maxPoolSize: number;

  constructor(bufferSize: number, initialSize: number, maxPoolSize: number) {
    this.bufferSize = bufferSize;
    this.maxPoolSize = maxPoolSize;
    // 预分配缓冲区
    for (let i = 0; i < initialSize; i++) {
      this.pool.push(new ArrayBuffer(bufferSize));
    }
  }

  /**
   * 获取一个缓冲区（从池中取出或新建）
   */
  acquire(): ArrayBuffer {
    if (this.pool.length > 0) {
      return this.pool.pop()!;
    }
    // 池为空时创建新的
    return new ArrayBuffer(this.bufferSize);
  }

  /**
   * 归还缓冲区到池中
   */
  release(buffer: ArrayBuffer): void {
    if (this.pool.length < this.maxPoolSize) {
      this.pool.push(buffer);
    }
    // 超出池大小的缓冲区会被 GC 回收
  }
}

/**
 * 麦克风数据流
 * 负责协调音频捕获、Opus 编码和网络发送
 *
 * 采用生产者-消费者模式：
 * - 生产者：AudioCapturer readData 回调（高优先级线程）
 * - 消费者：processQueue 处理循环（异步执行）
 */
export class MicrophoneStream implements MicrophoneDataCallback {
  private moonBridge: MoonBridgeClass;
  private capturer: MicrophoneCapturer | null = null;
  private encoderHandle: number = 0;
  private running: boolean = false;
  private paused: boolean = false;
  private hostRequested: boolean = false;

  // 状态监听器
  private stateListener: MicrophoneStateListener | null = null;

  // 异步处理队列
  private frameQueue: AudioFrame[] = [];
  private readonly MAX_QUEUE_SIZE = 50;  // 最大队列长度（约1秒的数据）
  private processingPromise: Promise<void> | null = null;
  private queueSignal: (() => void) | null = null;

  // 缓冲池 - 预分配缓冲区避免频繁 GC
  private bufferPool: BufferPool;

  // 统计信息
  private packetsSent: number = 0;
  private packetsDropped: number = 0;
  private framesQueued: number = 0;
  private framesDroppedQueue: number = 0;
  private lastLogTime: number = 0;
  
  constructor(moonBridge: MoonBridgeClass) {
    this.moonBridge = moonBridge;
    // 预分配 60 个缓冲区（约1秒的数据量），最大池大小 100
    this.bufferPool = new BufferPool(MicrophoneConfig.BYTES_PER_FRAME, 60, 100);
    console.info(TAG, '初始化麦克风流');
  }
  
  /**
   * 设置状态监听器
   */
  setStateListener(listener: MicrophoneStateListener): void {
    this.stateListener = listener;
  }
  
  /**
   * 检查主机是否请求了麦克风
   */
  isMicrophoneAvailable(): boolean {
    return this.moonBridge.isMicrophoneRequested();
  }
  
  /**
   * 是否正在运行
   */
  isRunning(): boolean {
    return this.running && !this.paused;
  }
  
  /**
   * 启动麦克风流
   */
  async start(): Promise<boolean> {
    if (this.running) {
      console.info(TAG, '麦克风流已在运行');
      return true;
    }
    
    // 检查主机是否请求了麦克风
    if (!this.moonBridge.isMicrophoneRequested()) {
      console.info(TAG, '主机未请求麦克风');
      return false;
    }
    
    this.hostRequested = true;
    
    // 记录加密状态
    if (this.moonBridge.isMicrophoneEncryptionEnabled()) {
      console.info(TAG, '麦克风加密已启用');
    }
    
    return this.startMicrophoneCapture();
  }
  
  /**
   * 启动麦克风捕获
   */
  private async startMicrophoneCapture(): Promise<boolean> {
    if (this.running) {
      return true;
    }
    
    try {
      // 获取麦克风端口
      const micPort = this.moonBridge.getMicPortNumber();
      if (micPort === 0) {
        console.warn(TAG, '未获取到麦克风端口');
      } else {
        console.info(TAG, `使用麦克风端口: ${micPort}`);
      }
      
      // 创建 Opus 编码器
      const bitrate = MicrophoneConfig.getOpusBitrate();
      this.encoderHandle = this.moonBridge.opusEncoderCreate(
        MicrophoneConfig.SAMPLE_RATE,
        MicrophoneConfig.CHANNELS,
        bitrate
      );
      
      if (this.encoderHandle === 0) {
        console.error(TAG, '创建 Opus 编码器失败');
        this.notifyError('创建 Opus 编码器失败');
        return false;
      }
      
      console.info(TAG, `Opus 编码器已创建: bitrate=${bitrate}`);
      
      // 创建麦克风捕获器
      this.capturer = new MicrophoneCapturer(this);
      
      if (!await this.capturer.start()) {
        console.error(TAG, '启动麦克风捕获失败');
        this.cleanup();
        this.notifyError('启动麦克风捕获失败');
        return false;
      }
      
      this.running = true;
      this.paused = false;
      this.packetsSent = 0;
      this.packetsDropped = 0;
      this.framesQueued = 0;
      this.framesDroppedQueue = 0;
      this.lastLogTime = Date.now();

      // 启动异步处理循环
      this.startProcessingLoop();

      this.notifyStateChanged(MicrophoneState.CAPTURING);
      console.info(TAG, '麦克风流已启动（异步队列模式）');
      
      return true;
      
    } catch (error) {
      console.error(TAG, `启动麦克风捕获失败: ${error}`);
      this.cleanup();
      this.notifyError(`启动麦克风捕获失败: ${error}`);
      return false;
    }
  }
  
  /**
   * MicrophoneDataCallback 实现
   * 当有音频数据时调用（在 AudioCapturer 的 readData 回调线程中）
   *
   * 重要：此方法必须快速返回，不能执行耗时操作！
   * 根据 HarmonyOS 文档："readData 方法所在的线程中，不建议执行耗时任务"
   */
  onMicrophoneData(data: ArrayBuffer, length: number): void {
    if (!this.running || this.paused) {
      return;
    }

    // 快速检查队列是否已满
    if (this.frameQueue.length >= this.MAX_QUEUE_SIZE) {
      // 队列已满，丢弃最旧的帧并归还缓冲区
      const droppedFrame = this.frameQueue.shift();
      if (droppedFrame) {
        this.bufferPool.release(droppedFrame.data);
      }
      this.framesDroppedQueue++;
    }

    // 从缓冲池获取缓冲区并复制数据（避免频繁的 new ArrayBuffer）
    const pooledBuffer = this.bufferPool.acquire();
    const srcView = new Uint8Array(data);
    const dstView = new Uint8Array(pooledBuffer);
    dstView.set(srcView.subarray(0, length));

    this.frameQueue.push({
      data: pooledBuffer,
      length: length,
      timestamp: Date.now()
    });
    this.framesQueued++;

    // 通知处理循环有新数据
    if (this.queueSignal) {
      this.queueSignal();
    }
  }

  /**
   * 启动异步处理循环
   */
  private startProcessingLoop(): void {
    if (this.processingPromise !== null) {
      return;
    }

    this.processingPromise = this.processQueueLoop();
  }

  /**
   * 异步处理循环
   * 从队列中取出数据，执行 Opus 编码和网络发送
   *
   * 重要：此循环必须能够快速响应暂停和停止请求
   * 以便在停止 AudioCapturer 前完成所有编码操作
   */
  private async processQueueLoop(): Promise<void> {
    console.info(TAG, '处理循环已启动');

    while (this.running) {
      // 处理暂停状态：立即响应，不处理任何数据
      if (this.paused) {
        // 快速等待，以便及时响应恢复或停止请求
        await this.waitForData(20);
        continue;
      }

      // 等待数据或超时
      if (this.frameQueue.length === 0) {
        await this.waitForData(100);  // 最多等待 100ms
        continue;
      }

      // 再次检查状态（等待期间可能已暂停）
      if (!this.running || this.paused) {
        continue;
      }

      // 取出一帧数据
      const frame = this.frameQueue.shift();
      if (!frame) {
        continue;
      }

      // 执行编码和发送（耗时操作，在异步循环中执行）
      this.encodeAndSend(frame);

      // 归还缓冲区到池中
      this.bufferPool.release(frame.data);
    }

    // 清理剩余队列中的缓冲区
    while (this.frameQueue.length > 0) {
      const frame = this.frameQueue.shift();
      if (frame) {
        this.bufferPool.release(frame.data);
      }
    }

    console.info(TAG, '处理循环已停止');
  }

  /**
   * 等待新数据到达
   */
  private waitForData(timeoutMs: number): Promise<void> {
    return new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        this.queueSignal = null;
        resolve();
      }, timeoutMs);

      this.queueSignal = () => {
        clearTimeout(timer);
        this.queueSignal = null;
        resolve();
      };
    });
  }

  /**
   * 编码并发送音频帧
   *
   * 重要：在调用 NAPI 函数前检查运行状态
   * 避免在停止过程中调用编码器
   */
  private encodeAndSend(frame: AudioFrame): void {
    // 严格检查：必须正在运行、未暂停、编码器有效
    if (!this.running || this.paused || this.encoderHandle === 0) {
      return;
    }

    // 验证 frame.data 是有效的 ArrayBuffer
    if (!(frame.data instanceof ArrayBuffer) || frame.data.byteLength === 0) {
      console.warn(TAG, `无效的音频帧数据: length=${frame.data?.byteLength ?? 0}`);
      this.packetsDropped++;
      return;
    }

    try {
      // 再次检查状态（在调用 NAPI 前）
      if (!this.running || this.paused || this.encoderHandle === 0) {
        return;
      }

      // 保存编码器句柄到局部变量（避免竞态条件）
      const encoderHandle = this.encoderHandle;
      if (encoderHandle === 0) {
        return;
      }

      // 编码为 Opus（同步 NAPI 调用）
      let opusData: ArrayBuffer | undefined = undefined;
      try {
        opusData = this.moonBridge.opusEncoderEncode(encoderHandle, frame.data);
      } catch (encodeError) {
        console.error(TAG, `Opus 编码调用失败: ${encodeError}`);
        this.packetsDropped++;
        return;
      }

      // 编码后再次检查状态（编码期间可能已被停止）
      if (!this.running || this.paused || this.encoderHandle === 0) {
        return;
      }

      if (opusData === undefined || opusData.byteLength === 0) {
        this.packetsDropped++;
        return;
      }

      // 发送到主机（同步 NAPI 调用）
      let ret = -1;
      try {
        ret = this.moonBridge.sendMicrophoneOpusData(opusData);
      } catch (sendError) {
        console.error(TAG, `发送麦克风数据失败: ${sendError}`);
        this.packetsDropped++;
        return;
      }

      if (ret >= 0) {
        this.packetsSent++;
      } else {
        this.packetsDropped++;
      }

      // 定期记录统计信息
      this.logStatistics();

    } catch (error) {
      console.error(TAG, `处理音频数据失败: ${error}`);
      this.packetsDropped++;
    }
  }

  /**
   * 记录统计信息
   */
  private logStatistics(): void {
    const now = Date.now();
    if (now - this.lastLogTime >= 10000) { // 每 10 秒
      const elapsed = (now - this.lastLogTime) / 1000;
      console.info(TAG,
        `麦克风统计: 已发送=${this.packetsSent}, 编码丢弃=${this.packetsDropped}, ` +
        `队列丢弃=${this.framesDroppedQueue}, 队列长度=${this.frameQueue.length}, ` +
        `速率=${(this.packetsSent / elapsed).toFixed(1)} pps`);
      this.packetsSent = 0;
      this.packetsDropped = 0;
      this.framesDroppedQueue = 0;
      this.lastLogTime = now;
    }
  }
  
  /**
   * 暂停麦克风流
   *
   * 重要：必须先暂停编码处理，再停止 AudioCapturer
   * 否则在 NAPI 调用期间停止 AudioCapturer 可能导致崩溃
   */
  async pause(): Promise<void> {
    if (!this.running || this.paused) {
      return;
    }

    console.info(TAG, '暂停麦克风流开始');

    // 1. 首先设置暂停标志，停止处理新数据
    this.paused = true;

    // 2. 等待处理循环检测到暂停状态并停止编码
    //    给处理循环一点时间完成当前正在进行的编码操作
    await this.waitForProcessingPause(200);

    // 3. 清空待处理队列（避免恢复时处理过期数据）
    const queuedFrames = this.frameQueue.length;
    this.frameQueue = [];
    if (queuedFrames > 0) {
      console.info(TAG, `已清空 ${queuedFrames} 个待处理帧`);
    }

    // 4. 最后停止 AudioCapturer
    if (this.capturer) {
      await this.capturer.pause();
    }

    this.notifyStateChanged(MicrophoneState.PAUSED);
    console.info(TAG, '麦克风流已暂停');
  }

  /**
   * 等待处理循环暂停
   * 确保没有正在进行的编码操作
   */
  private async waitForProcessingPause(timeoutMs: number): Promise<void> {
    const startTime = Date.now();
    const checkInterval = 10; // 10ms 检查一次

    while (Date.now() - startTime < timeoutMs) {
      // 唤醒处理循环让它检查暂停状态
      if (this.queueSignal) {
        this.queueSignal();
      }

      // 等待一小段时间
      await new Promise<void>((resolve) => setTimeout(resolve, checkInterval));

      // 如果队列为空且没有正在进行的处理，可以安全退出
      if (this.frameQueue.length === 0) {
        break;
      }
    }
  }
  
  /**
   * 恢复麦克风流
   */
  async resume(): Promise<void> {
    if (!this.running || !this.paused) {
      return;
    }
    
    if (this.capturer) {
      await this.capturer.resume();
    }
    
    this.paused = false;
    this.notifyStateChanged(MicrophoneState.CAPTURING);
    console.info(TAG, '麦克风流已恢复');
  }
  
  /**
   * 切换麦克风状态（暂停/恢复）
   */
  async toggle(): Promise<boolean> {
    if (!this.running) {
      // 如果未运行，尝试启动
      return this.start();
    }
    
    if (this.paused) {
      await this.resume();
    } else {
      await this.pause();
    }
    
    return !this.paused;
  }
  
  /**
   * 停止麦克风流
   *
   * 重要：必须按正确顺序停止各组件
   * 1. 先停止处理循环（停止调用 NAPI 编码函数）
   * 2. 再停止 AudioCapturer（避免在 NAPI 调用期间触发状态回调）
   * 3. 最后销毁编码器
   */
  async stop(): Promise<void> {
    if (!this.running) {
      return;
    }

    console.info(TAG, '停止麦克风流开始');

    // 1. 标记为非运行状态，停止处理循环
    this.running = false;
    this.paused = false;

    // 2. 唤醒处理循环让它退出
    if (this.queueSignal) {
      this.queueSignal();
    }

    // 3. 等待处理循环完成（包括任何正在进行的编码操作）
    if (this.processingPromise) {
      try {
        await this.processingPromise;
      } catch (error) {
        console.warn(TAG, `等待处理循环完成时出错: ${error}`);
      }
      this.processingPromise = null;
    }

    // 4. 清空队列
    this.frameQueue = [];

    // 5. 现在安全地停止和释放 AudioCapturer
    if (this.capturer) {
      try {
        await this.capturer.release();
      } catch (error) {
        console.warn(TAG, `释放 AudioCapturer 时出错: ${error}`);
      }
      this.capturer = null;
    }

    // 6. 最后销毁编码器
    if (this.encoderHandle !== 0) {
      this.moonBridge.opusEncoderDestroy(this.encoderHandle);
      this.encoderHandle = 0;
    }

    this.notifyStateChanged(MicrophoneState.STOPPED);
    console.info(TAG, '麦克风流已停止');
  }

  /**
   * 清理资源（内部使用，在初始化失败时调用）
   */
  private async cleanup(): Promise<void> {
    // 停止捕获
    if (this.capturer) {
      try {
        await this.capturer.release();
      } catch (error) {
        console.warn(TAG, `清理时释放 AudioCapturer 出错: ${error}`);
      }
      this.capturer = null;
    }

    // 清空队列
    this.frameQueue = [];

    // 销毁编码器
    if (this.encoderHandle !== 0) {
      this.moonBridge.opusEncoderDestroy(this.encoderHandle);
      this.encoderHandle = 0;
    }

    this.running = false;
    this.paused = false;
  }
  
  /**
   * 通知状态变更
   */
  private notifyStateChanged(state: MicrophoneState): void {
    if (this.stateListener) {
      this.stateListener.onMicrophoneStateChanged(state);
    }
  }
  
  /**
   * 通知错误
   */
  private notifyError(error: string): void {
    if (this.stateListener) {
      this.stateListener.onMicrophoneError(error);
    }
  }
}
