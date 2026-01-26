import { router } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { StreamingSession } from '../service/StreamingSession';
import { StreamConfig } from '../model/StreamConfig';
import { PerformanceOverlay } from '../components/PerformanceOverlay';
import { VirtualController } from '../components/VirtualController';

interface StreamPageParams {
  computerId: string;
  appId: number;
}

@Entry
@Component
struct StreamPage {
  @State isConnecting: boolean = true;
  @State isConnected: boolean = false;
  @State errorMessage: string = '';
  @State showOverlay: boolean = true;
  @State showController: boolean = true;
  @State fps: number = 0;
  @State bitrate: number = 0;
  @State latency: number = 0;
  @State packetLoss: number = 0;

  private xComponentController: XComponentController = new XComponentController();
  private streamingSession: StreamingSession | null = null;
  private computerId: string = '';
  private appId: number = 0;

  aboutToAppear(): void {
    const params = router.getParams() as StreamPageParams;
    if (params) {
      this.computerId = params.computerId;
      this.appId = params.appId;
    }

    // 设置全屏和保持屏幕常亮
    this.configureWindow();
  }

  async configureWindow(): Promise<void> {
    try {
      const win = await window.getLastWindow(getContext(this));
      // 保持屏幕常亮
      win.setWindowKeepScreenOn(true);
      // 隐藏状态栏和导航栏
      win.setWindowSystemBarEnable([]);
    } catch (err) {
      console.error('配置窗口失败:', err);
    }
  }

  async startStreaming(): Promise<void> {
    this.isConnecting = true;
    this.errorMessage = '';

    try {
      const config: StreamConfig = {
        width: 1920,
        height: 1080,
        fps: 60,
        bitrate: 20000,
        codec: 'HEVC',
        hdr: false,
        audioEnabled: true,
        microphoneEnabled: false
      };

      // 获取 XComponent 的 surfaceId
      const surfaceId = this.xComponentController.getXComponentSurfaceId();

      // 创建串流会话
      this.streamingSession = new StreamingSession();
      await this.streamingSession.start(this.computerId, this.appId, config, surfaceId);

      this.isConnecting = false;
      this.isConnected = true;

      // 开始性能监控
      this.startPerformanceMonitoring();
    } catch (err) {
      this.isConnecting = false;
      this.errorMessage = `连接失败: ${err}`;
    }
  }

  startPerformanceMonitoring(): void {
    // TODO: 实现性能监控
    setInterval(() => {
      if (this.streamingSession) {
        const stats = this.streamingSession.getStats();
        this.fps = stats.fps;
        this.bitrate = stats.bitrate;
        this.latency = stats.latency;
        this.packetLoss = stats.packetLoss;
      }
    }, 1000);
  }

  async stopStreaming(): Promise<void> {
    if (this.streamingSession) {
      await this.streamingSession.stop();
      this.streamingSession = null;
    }
    this.isConnected = false;

    // 恢复窗口设置
    try {
      const win = await window.getLastWindow(getContext(this));
      win.setWindowKeepScreenOn(false);
      win.setWindowSystemBarEnable(['status', 'navigation']);
    } catch (err) {
      console.error('恢复窗口设置失败:', err);
    }

    router.back();
  }

  build() {
    Stack() {
      // 视频渲染层 - 使用 XComponent
      XComponent({
        id: 'streamSurface',
        type: XComponentType.SURFACE,
        controller: this.xComponentController
      })
        .onLoad(() => {
          console.info('XComponent 加载完成');
          this.startStreaming();
        })
        .onDestroy(() => {
          console.info('XComponent 销毁');
        })
        .width('100%')
        .height('100%')

      // 连接状态层
      if (this.isConnecting) {
        this.ConnectingOverlay()
      }

      // 错误提示层
      if (this.errorMessage) {
        this.ErrorOverlay()
      }

      // 性能监控层
      if (this.isConnected && this.showOverlay) {
        PerformanceOverlay({
          fps: this.fps,
          bitrate: this.bitrate,
          latency: this.latency,
          packetLoss: this.packetLoss
        })
      }

      // 虚拟控制器层
      if (this.isConnected && this.showController) {
        VirtualController({
          onInput: (input) => {
            this.streamingSession?.sendInput(input);
          }
        })
      }

      // 菜单按钮
      if (this.isConnected) {
        this.MenuButton()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  @Builder
  ConnectingOverlay() {
    Column() {
      LoadingProgress()
        .width(64)
        .height(64)
        .color($r('app.color.primary'))
      Text($r('app.string.connecting'))
        .fontSize(18)
        .fontColor(Color.White)
        .margin({ top: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#CC000000')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorOverlay() {
    Column() {
      Image($r('app.media.ic_error'))
        .width(64)
        .height(64)
        .fillColor($r('app.color.error_red'))
      Text(this.errorMessage)
        .fontSize(16)
        .fontColor(Color.White)
        .margin({ top: 16 })
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })

      Button('返回')
        .fontSize(16)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.primary'))
        .width(120)
        .height(44)
        .borderRadius(12)
        .margin({ top: 24 })
        .onClick(() => {
          router.back();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#CC000000')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  MenuButton() {
    Button({ type: ButtonType.Circle }) {
      Image($r('app.media.ic_menu'))
        .width(24)
        .height(24)
        .fillColor(Color.White)
    }
    .width(48)
    .height(48)
    .backgroundColor('#66000000')
    .position({ x: 16, y: 48 })
    .onClick(() => {
      this.showStreamMenu();
    })
  }

  showStreamMenu(): void {
    // TODO: 显示串流菜单（断开、设置、切换控制器等）
  }
}
