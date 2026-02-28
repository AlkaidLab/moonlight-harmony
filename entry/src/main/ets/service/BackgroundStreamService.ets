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
 * 后台串流保活服务
 *
 * 使用 AVSession + AUDIO_PLAYBACK 长时任务防止系统在后台冻结（Suspend）应用进程。
 * HarmonyOS 在应用退到后台时，若未申请长时任务且未接入 AVSession，
 * 系统会静音并冻结进程，导致网络连接超时断开、解码器状态丢失。
 *
 * 工作原理：
 * 1. 创建 AVSession（类型 'audio'），设置必要元数据
 * 2. 申请 AUDIO_PLAYBACK 类型长时任务（backgroundTaskManager.startBackgroundRunning）
 * 3. 保持 AVSession 激活状态，确保进程不被冻结
 * 4. 串流结束时停止长时任务并销毁 AVSession
 */
import { avSession as AVSessionManager } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { image } from '@kit.ImageKit';

const TAG = '[BackgroundStreamService]';

/**
 * 播控中心控制回调
 * 由 StreamPage 提供具体实现
 */
export interface BroadcastControlCallbacks {
  /** 播控中心点击"停止" → 断开串流 */
  onStop?: () => void;
}

export class BackgroundStreamService {
  private static instance: BackgroundStreamService;
  private session: AVSessionManager.AVSession | null = null;
  private isRunning: boolean = false;
  private context: common.UIAbilityContext | null = null;
  private notificationId: number = 0;  // 长时任务通知 ID（用于更新通知内容）
  private gameName: string = 'Moonlight 串流';
  private controlCallbacks: BroadcastControlCallbacks | null = null;

  private constructor() {}

  static getInstance(): BackgroundStreamService {
    if (!BackgroundStreamService.instance) {
      BackgroundStreamService.instance = new BackgroundStreamService();
    }
    return BackgroundStreamService.instance;
  }

  /**
   * 启动后台保活
   * 在串流连接建立后调用，防止进入后台时被系统冻结
   * @param context UIAbilityContext
   * @param gameName 当前串流的游戏名称（用于播控中心展示）
   * @param callbacks 播控中心操作回调（stop → 断开串流）
   */
  async start(context: common.UIAbilityContext, gameName?: string, callbacks?: BroadcastControlCallbacks): Promise<void> {
    if (this.isRunning) {
      console.info(`${TAG} 已在运行，跳过重复启动`);
      return;
    }

    this.context = context;
    this.gameName = gameName || 'Moonlight 串流';
    this.controlCallbacks = callbacks || null;

    try {
      // 0. 监听长时任务被系统取消事件（用于诊断）
      this.registerCancelListener();

      // 1. 创建 AVSession
      await this.createAVSession(this.gameName);

      // 2. 启动长时任务
      await this.startContinuousTask();

      this.isRunning = true;
      console.info(`${TAG} 后台保活已启动`);
    } catch (err) {
      console.error(`${TAG} 启动后台保活失败:`, err);
      // 清理可能部分创建的资源
      await this.cleanup();
    }
  }

  /**
   * 停止后台保活
   * 在串流断开后调用
   */
  async stop(): Promise<void> {
    if (!this.isRunning) {
      return;
    }

    console.info(`${TAG} 正在停止后台保活...`);
    await this.cleanup();
    this.isRunning = false;
    console.info(`${TAG} 后台保活已停止`);
  }

  /**
   * 获取当前运行状态
   */
  getIsRunning(): boolean {
    return this.isRunning;
  }

  // ── 内部实现 ──

  /**
   * 注册长时任务取消监听（诊断用途）
   * 当系统取消长时任务时打印日志
   */
  private registerCancelListener(): void {
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info) => {
        console.error(`${TAG} ⚠️ 长时任务被系统取消! info=${JSON.stringify(info)}`);
      });
    } catch (err) {
      console.warn(`${TAG} 注册取消监听失败:`, err);
    }
  }

  /**
   * 取消长时任务取消监听
   */
  private unregisterCancelListener(): void {
    try {
      backgroundTaskManager.off('continuousTaskCancel');
    } catch (err) {
      // 忽略
    }
  }

  /**
   * 创建并激活 AVSession
   * 设置封面图片、元数据、播控命令以满足播控中心规范
   */
  private async createAVSession(gameName: string): Promise<void> {
    try {
      // 创建 audio 类型的 AVSession
      this.session = await AVSessionManager.createAVSession(
        this.context!,
        'MoonlightStreaming',
        'audio'
      );
      console.info(`${TAG} AVSession 已创建, sessionId=${this.session.sessionId}`);

      // 加载应用图标作为封面 (800x800 方形，符合播控中心规范)
      let coverImage: image.PixelMap | undefined = undefined;
      try {
        const resourceManager = this.context!.resourceManager;
        const iconData: Uint8Array = resourceManager.getMediaContentSync($r('app.media.app_icon').id);
        const imageSource: image.ImageSource = image.createImageSource(iconData.buffer as ArrayBuffer);
        coverImage = await imageSource.createPixelMap({
          desiredSize: { width: 800, height: 800 }
        });
        imageSource.release();
      } catch (imgErr) {
        console.warn(`${TAG} 加载封面图片失败:`, imgErr);
      }

      // 设置元数据（标题 + 副标题 + 封面）
      const metadata: AVSessionManager.AVMetadata = {
        assetId: 'moonlight_streaming',
        title: gameName,
        artist: 'Moonlight 游戏串流',
        mediaImage: coverImage,
      } as AVSessionManager.AVMetadata;
      await this.session.setAVMetadata(metadata);

      // 注册播控命令（不注册的命令在播控中心自动置灰）
      // play: 串流持续运行，仅切换播控状态指示
      this.session.on('play', () => {
        console.info(`${TAG} 播控中心: play`);
        this.setPlaybackState(AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY);
      });
      // pause: 切换播控状态，实际串流不暂停（游戏无法暂停）
      this.session.on('pause', () => {
        console.info(`${TAG} 播控中心: pause`);
        this.setPlaybackState(AVSessionManager.PlaybackState.PLAYBACK_STATE_PAUSE);
      });
      // stop: 断开串流
      this.session.on('stop', () => {
        console.info(`${TAG} 播控中心: stop → 断开串流`);
        if (this.controlCallbacks?.onStop) {
          this.controlCallbacks.onStop();
        }
      });

      // 设置播放状态为"播放中"
      await this.setPlaybackState(AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY);

      // 激活 AVSession（必须在元数据和控制命令注册后）
      await this.session.activate();
      console.info(`${TAG} AVSession 已激活`);
    } catch (err) {
      const error = err as BusinessError;
      console.error(`${TAG} 创建 AVSession 失败: code=${error.code}, msg=${error.message}`);
      throw new Error(`创建 AVSession 失败: ${error.message}`);
    }
  }

  /**
   * 更新 AVSession 播放状态
   */
  private async setPlaybackState(state: AVSessionManager.PlaybackState): Promise<void> {
    if (!this.session) return;
    try {
      const playbackState: AVSessionManager.AVPlaybackState = {
        state: state,
        speed: 1.0,
      };
      await this.session.setAVPlaybackState(playbackState);
    } catch (err) {
      console.warn(`${TAG} 设置播放状态失败:`, err);
    }
  }

  /**
   * 启动 AUDIO_PLAYBACK 类型长时任务
   * 配合 AVSession 防止系统冻结进程
   */
  private async startContinuousTask(): Promise<void> {
    try {
      // 创建 WantAgent（点击通知时跳转回应用）
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.alkaidlab.sdream',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);

      // 启动长时任务（同时申请 dataTransfer + audioPlayback，
      // dataTransfer: 串流本身就是持续数据传输，系统不会因为检测不到媒体渲染而取消
      // audioPlayback: 音频播放保活，配合 AVSession）
      const bgModes: string[] = ['dataTransfer', 'audioPlayback'];
      const result = await backgroundTaskManager.startBackgroundRunning(
        this.context!,
        bgModes,
        agent
      );
      this.notificationId = result.notificationId;
      console.info(`${TAG} 长时任务已启动 (dataTransfer+audioPlayback), notificationId=${this.notificationId}`);

      // 更新通知内容，显示游戏名称
      await this.updateNotification();
    } catch (err) {
      const error = err as BusinessError;
      console.error(`${TAG} 启动长时任务失败: code=${error.code}, msg=${error.message}`);
      throw new Error(`启动长时任务失败: ${error.message}`);
    }
  }

  /**
   * 更新长时任务通知，显示游戏名称
   */
  private async updateNotification(): Promise<void> {
    if (this.notificationId <= 0) {
      return;
    }
    try {
      const request: notificationManager.NotificationRequest = {
        id: this.notificationId,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'Moonlight 串流中',
            text: this.gameName,
          }
        },
      };
      await notificationManager.publish(request);
      console.info(`${TAG} 通知已更新: ${this.gameName}`);
    } catch (err) {
      console.warn(`${TAG} 更新通知失败:`, err);
    }
  }

  /**
   * 清理所有资源
   */
  private async cleanup(): Promise<void> {
    // 取消监听
    this.unregisterCancelListener();

    // 停止长时任务
    try {
      if (this.context) {
        await backgroundTaskManager.stopBackgroundRunning(this.context);
        console.info(`${TAG} 长时任务已停止`);
      }
    } catch (err) {
      console.warn(`${TAG} 停止长时任务失败:`, err);
    }

    // 销毁 AVSession
    if (this.session) {
      try {
        // 取消控制命令监听
        this.session.off('play');
        this.session.off('pause');
        this.session.off('stop');
        // 反激活并销毁
        await this.session.deactivate();
        await this.session.destroy();
        console.info(`${TAG} AVSession 已销毁`);
      } catch (err) {
        console.warn(`${TAG} 销毁 AVSession 失败:`, err);
      }
      this.session = null;
    }

    this.context = null;
    this.controlCallbacks = null;
  }
}
