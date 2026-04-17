/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { promptAction } from '@kit.ArkUI';

/**
 * Toast 队列：串行化 promptAction.showToast，避免多个初始化 toast 同时触发时
 * 相互覆盖（HarmonyOS 的 Toast 连续调用会替换前一个，用户只能看到最后一个）。
 *
 * 用法：ToastQueue.show({ message: 'xxx', duration: 2000 });
 */

interface QueuedToast {
  message: string;
  duration: number;
}

export class ToastQueue {
  private static queue: QueuedToast[] = [];
  private static running: boolean = false;
  /** 相邻两条 toast 之间的最小间隔，给上一条留出淡出时间 */
  private static readonly GAP_MS: number = 300;
  /** 队列最大长度，防止极端场景无限堆积 */
  private static readonly MAX_QUEUE: number = 8;

  static show(options: { message: string; duration?: number }): void {
    const message = options.message;
    if (!message) return;
    const duration = options.duration && options.duration > 0 ? options.duration : 1500;

    // 去重：如果队尾已有同样消息，跳过
    const tail = ToastQueue.queue[ToastQueue.queue.length - 1];
    if (tail && tail.message === message) return;

    if (ToastQueue.queue.length >= ToastQueue.MAX_QUEUE) {
      // 丢弃最旧的等待项，避免拖延主要提示
      ToastQueue.queue.shift();
    }
    ToastQueue.queue.push({ message, duration });
    if (!ToastQueue.running) {
      ToastQueue.pump();
    }
  }

  private static pump(): void {
    const next = ToastQueue.queue.shift();
    if (!next) {
      ToastQueue.running = false;
      return;
    }
    ToastQueue.running = true;
    try {
      promptAction.showToast({ message: next.message, duration: next.duration });
    } catch (e) {
      console.warn(`ToastQueue: showToast failed: ${e}`);
    }
    setTimeout(() => ToastQueue.pump(), next.duration + ToastQueue.GAP_MS);
  }

  /** 清空队列（仅清待播队列，不能关闭当前正在显示的 toast）*/
  static clear(): void {
    ToastQueue.queue = [];
  }
}
