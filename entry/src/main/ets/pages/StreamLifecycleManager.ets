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
 * 串流页面生命周期管理器
 *
 * 封装应用前后台状态、屏幕旋转、连接终止、延迟统计等生命周期逻辑，
 * 从 StreamPage 中解耦以降低单文件复杂度。
 */
import { display, promptAction } from '@kit.ArkUI';
import { StreamViewModel } from '../viewmodel/StreamViewModel';
import { StreamWindowManager } from '../service/StreamWindowManager';
import { AppStateService, AppState } from '../service/AppStateService';

/**
 * StreamPage 需要实现的回调接口
 * 用于将 UI 相关操作（@State 更新、路由跳转）委托回 StreamPage
 */
export interface LifecycleCallbacks {
  /** 更新 XComponent 尺寸（@State 变量） */
  updateXComponentSize: (width: Length, height: Length) => void;
  /** 停止串流并返回菜单页 */
  stopStreaming: () => void;
}

export class StreamLifecycleManager {
  // ── 外部依赖 ──
  private viewModel: StreamViewModel | null = null;
  private windowManager: StreamWindowManager | null = null;
  private callbacks: LifecycleCallbacks | null = null;

  // ── 应用状态相关 ──
  private appStateService: AppStateService = AppStateService.getInstance();
  private appStateListener: ((state: AppState) => void) | null = null;
  private wasInBackground: boolean = false;

  // ── 屏幕方向变化监听相关 ──
  private displayChangeCallback: ((displayId: number) => void) | null = null;
  private lastDisplayOrientation: boolean | null = null; // null=未初始化, true=横屏, false=竖屏

  // ── 延迟统计 ──
  private latencyToastEnabled: boolean = false;

  /**
   * 初始化依赖项
   */
  initialize(viewModel: StreamViewModel, windowManager: StreamWindowManager | null,
    callbacks: LifecycleCallbacks): void {
    this.viewModel = viewModel;
    this.windowManager = windowManager;
    this.callbacks = callbacks;
  }

  /**
   * 设置是否启用延迟统计 Toast
   */
  setLatencyToastEnabled(enabled: boolean): void {
    this.latencyToastEnabled = enabled;
  }

  // ==================== 应用前后台状态 ====================

  /**
   * 注册应用前后台状态监听
   */
  registerAppStateListener(): void {
    this.appStateListener = (state: AppState) => {
      if (state === AppState.BACKGROUND) {
        console.info('[StreamPage] 应用进入后台');
        this.wasInBackground = true;
      } else if (state === AppState.FOREGROUND && this.wasInBackground) {
        console.info('[StreamPage] 应用从后台恢复');
        this.wasInBackground = false;
        this.handleAppResume();
      }
    };
    this.appStateService.addListener(this.appStateListener);
  }

  /**
   * 取消应用状态监听
   */
  unregisterAppStateListener(): void {
    if (this.appStateListener) {
      this.appStateService.removeListener(this.appStateListener);
      this.appStateListener = null;
    }
  }

  // ==================== 屏幕旋转 ====================

  /**
   * 注册屏幕方向变化监听
   * 使用 display.on('change') 监听屏幕变化
   */
  registerDisplayChangeListener(): void {
    try {
      this.displayChangeCallback = (displayId: number): void => {
        this.handleDisplayChange(displayId);
      };
      display.on('change', this.displayChangeCallback);
      console.info('[StreamPage] 已注册屏幕方向变化监听');
    } catch (err) {
      console.warn('[StreamPage] 注册屏幕方向监听失败:', err);
    }
  }

  /**
   * 取消屏幕方向变化监听
   */
  unregisterDisplayChangeListener(): void {
    if (this.displayChangeCallback) {
      try {
        display.off('change', this.displayChangeCallback);
        console.info('[StreamPage] 已取消屏幕方向变化监听');
      } catch (err) {
        console.warn('[StreamPage] 取消屏幕方向监听失败:', err);
      }
      this.displayChangeCallback = null;
    }
  }

  /**
   * 处理屏幕变化事件
   * @param displayId 发生变化的显示器 ID
   */
  private handleDisplayChange(displayId: number): void {
    // 只处理连接状态
    if (!this.viewModel?.isConnected) {
      return;
    }

    try {
      const displayInfo = display.getDefaultDisplaySync();
      const isLandscape = displayInfo.width > displayInfo.height;

      // 只有方向真正变化时才处理
      if (this.lastDisplayOrientation !== null && this.lastDisplayOrientation === isLandscape) {
        return;
      }

      console.info(`[StreamPage] 屏幕方向变化: ${isLandscape ? '横屏' : '竖屏'}, displayId=${displayId}`);
      this.lastDisplayOrientation = isLandscape;

      // 通知 ViewModel 处理旋转
      this.viewModel?.handleRotationChange(isLandscape);

      // 更新屏幕尺寸
      this.updateScreenSizeAfterRotation();
    } catch (err) {
      console.warn('[StreamPage] 处理屏幕变化失败:', err);
    }
  }

  /**
   * 屏幕旋转后更新尺寸
   */
  async updateScreenSizeAfterRotation(): Promise<void> {
    try {
      const screenSize = await this.windowManager?.updateScreenSize();
      if (screenSize) {
        if (this.viewModel) {
          this.viewModel.displayInfo.screenWidth = screenSize.width;
          this.viewModel.displayInfo.screenHeight = screenSize.height;
        }

        // 重新计算 XComponent 尺寸
        const xComponentSize = this.windowManager?.calculateXComponentSize(
          this.viewModel?.displayInfo.stretchVideo ?? false
        );
        if (xComponentSize) {
          this.callbacks?.updateXComponentSize(xComponentSize.width, xComponentSize.height);
        }
      }
    } catch (err) {
      console.warn('[StreamPage] 更新屏幕尺寸失败:', err);
    }
  }

  /**
   * 处理服务端分辨率变化（屏幕旋转/分辨率改变）
   * 更新窗口管理器的串流分辨率并重新计算 XComponent 尺寸
   */
  async handleServerResolutionChanged(width: number, height: number): Promise<void> {
    console.info(`[StreamPage] 服务端分辨率变化: ${width}x${height}`);

    // 更新窗口管理器的串流分辨率
    this.windowManager?.setStreamResolution(width, height);

    // 重新配置窗口方向（可能会触发屏幕旋转）
    await this.windowManager?.configureOrientation();

    // 更新屏幕尺寸（等待旋转完成后获取正确的屏幕尺寸）
    const screenSize = await this.windowManager?.updateScreenSize();
    if (screenSize && this.viewModel) {
      this.viewModel.displayInfo.screenWidth = screenSize.width;
      this.viewModel.displayInfo.screenHeight = screenSize.height;
    }

    // 重新计算 XComponent 尺寸以避免画面拉伸
    const xComponentSize = this.windowManager?.calculateXComponentSize(
      this.viewModel?.displayInfo.stretchVideo ?? false
    );
    if (xComponentSize) {
      this.callbacks?.updateXComponentSize(xComponentSize.width, xComponentSize.height);
      console.info(`[StreamPage] XComponent 尺寸更新: ${JSON.stringify(xComponentSize)}`);
    }
  }

  // ==================== 应用恢复 ====================

  /**
   * 处理应用从后台恢复
   * 当应用从后台切回前台时，需要检查串流状态并尝试恢复
   */
  private handleAppResume(): void {
    console.info(`[StreamPage] 处理应用恢复, 连接状态: ${this.viewModel?.connectionState}`);

    // 如果当前已连接，尝试恢复串流
    if (this.viewModel?.isConnected) {
      console.info('[StreamPage] 尝试恢复串流...');
      this.viewModel.resumeFromBackground();
    }
  }

  // ==================== 延迟统计 ====================

  /**
   * 串流结束后显示延迟统计 Toast
   * 对齐 Android: Game.connectionTerminated() 中 enableLatencyToast 逻辑
   */
  showLatencyToastIfEnabled(): void {
    console.info(`[StreamPage] showLatencyToast: enabled=${this.latencyToastEnabled}`);
    if (!this.latencyToastEnabled) {
      return;
    }

    // 使用 getSummaryStats 获取有效数据（断连后 native 数据可能已清零）
    const session = this.viewModel?.getSession();
    const stats = session ? session.getSummaryStats() : this.viewModel?.performanceStats;
    if (!stats) return;

    console.info(`[StreamPage] stats: net=${stats.networkLatency}, decode=${stats.latency}, host=${stats.hostLatency}, fps=${stats.renderedFps}`);
    const parts: string[] = [];

    // 网络延迟 (RTT)
    if (stats.networkLatency > 0) {
      parts.push(`网络: ${stats.networkLatency}ms`);
    }
    // 解码延迟 - 使用全局累计平均值（真实平均，非 EMA）
    const decodeLatency = stats.globalAvgDecodeLatency > 0 ? stats.globalAvgDecodeLatency : stats.latency;
    if (decodeLatency > 0) {
      parts.push(`解码: ${decodeLatency.toFixed(1)}ms`);
    }
    // 主机延迟 - 使用全局累计平均值
    const hostLatency = stats.globalAvgHostLatency > 0 ? stats.globalAvgHostLatency : stats.hostLatency;
    if (hostLatency > 0) {
      parts.push(`主机: ${hostLatency.toFixed(1)}ms`);
    }
    // 帧率 - 使用全局平均帧率（真实平均，非瞬时窗口值）
    const avgFps = stats.globalAvgFps > 0 ? Math.round(stats.globalAvgFps) : stats.renderedFps;
    if (avgFps > 0) {
      parts.push(`帧率: ${avgFps}fps`);
    }

    const message = parts.length > 0 ? parts.join(' | ') : '串流已结束';
    promptAction.showToast({
      message: message,
      duration: 3500
    });
  }

  // ==================== 连接终止 ====================

  /**
   * 处理服务器断开连接
   * errorCode: 0 = 正常关闭（如用户在服务器端退出游戏）
   *           -100 = 无视频流量（端口问题）
   *           -101 = 无完整帧（网络不稳定）
   *           -102 = 意外提前终止
   *           -103 = 受保护内容
   *           -104 = 帧转换错误
   */
  handleConnectionTerminated(errorCode: number): void {
    console.info(`StreamPage: 连接终止, errorCode=${errorCode}`);

    const ML_ERROR_GRACEFUL_TERMINATION = 0;
    const ML_ERROR_NO_VIDEO_TRAFFIC = -100;
    const ML_ERROR_NO_VIDEO_FRAME = -101;
    const ML_ERROR_UNEXPECTED_EARLY_TERMINATION = -102;
    const ML_ERROR_PROTECTED_CONTENT = -103;
    const ML_ERROR_FRAME_CONVERSION = -104;

    if (errorCode === ML_ERROR_GRACEFUL_TERMINATION) {
      // 服务器正常关闭（用户在服务器端退出游戏），stopStreaming 内部会显示延迟统计
      this.callbacks?.stopStreaming();
    } else {
      // 连接异常终止，显示错误信息
      let message: string;
      switch (errorCode) {
        case ML_ERROR_NO_VIDEO_TRAFFIC:
          message = '未收到视频数据。请检查防火墙或端口转发规则（UDP 47998）。';
          break;
        case ML_ERROR_NO_VIDEO_FRAME:
          message = '未收到完整视频帧。网络可能不稳定或码率设置过高。';
          break;
        case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
        case ML_ERROR_PROTECTED_CONTENT:
          message = '串流意外终止。可能是受保护内容或编码器无法捕获视频。';
          break;
        case ML_ERROR_FRAME_CONVERSION:
          message = '帧转换错误。请尝试调整分辨率或关闭 HDR。';
          break;
        default:
          const errorHex = Math.abs(errorCode) > 1000 ? `0x${errorCode.toString(16)}` : errorCode.toString();
          message = `连接已断开 (错误码: ${errorHex})`;
          break;
      }

      promptAction.showDialog({
        title: '连接已断开',
        message: message,
        buttons: [{ text: '确定', color: '#3B82F6' }]
      }).then(() => {
        this.callbacks?.stopStreaming();
      }).catch(() => {
        this.callbacks?.stopStreaming();
      });
    }
  }
}
