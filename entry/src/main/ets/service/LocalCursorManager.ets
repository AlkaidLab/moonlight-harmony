/**
 * 绝对鼠标位置管理器
 *
 * 在绝对鼠标模式下，将触控板的相对移动转换为绝对坐标发送给服务器
 * 同时支持物理鼠标直接发送绝对位置
 */

/**
 * 鼠标发送接口
 */
export interface MouseSender {
  sendMouseMove(deltaX: number, deltaY: number): void;
  sendMousePosition(x: number, y: number, referenceWidth: number, referenceHeight: number): void;
}

/**
 * 绝对鼠标位置管理器
 */
export class AbsoluteMouseManager {
  private static instance: AbsoluteMouseManager | null = null;

  /** 虚拟光标X位置（触控板模式用） */
  private cursorX: number = 0;
  /** 虚拟光标Y位置 */
  private cursorY: number = 0;
  /** 视图宽度 */
  private viewWidth: number = 1920;
  /** 视图高度 */
  private viewHeight: number = 1080;
  /** 是否启用绝对鼠标模式 */
  private absoluteMouseMode: boolean = false;
  /** Native 输入接口 */
  private mouseSender: MouseSender | null = null;

  private constructor() {}

  /**
   * 获取单例实例
   */
  public static getInstance(): AbsoluteMouseManager {
    if (!AbsoluteMouseManager.instance) {
      AbsoluteMouseManager.instance = new AbsoluteMouseManager();
    }
    return AbsoluteMouseManager.instance;
  }

  /**
   * 初始化管理器
   */
  public initialize(mouseSender: MouseSender, viewWidth: number, viewHeight: number): void {
    this.mouseSender = mouseSender;
    this.viewWidth = viewWidth;
    this.viewHeight = viewHeight;
    this.cursorX = viewWidth / 2;
    this.cursorY = viewHeight / 2;
    console.info(`AbsoluteMouseManager: initialized ${viewWidth}x${viewHeight}`);
  }

  /**
   * 更新视图尺寸
   */
  public updateViewSize(width: number, height: number): void {
    if (this.viewWidth > 0 && this.viewHeight > 0) {
      this.cursorX = (this.cursorX / this.viewWidth) * width;
      this.cursorY = (this.cursorY / this.viewHeight) * height;
    }
    this.viewWidth = width;
    this.viewHeight = height;
  }

  /**
   * 设置是否启用绝对鼠标模式
   */
  public setAbsoluteMouseMode(enabled: boolean): void {
    this.absoluteMouseMode = enabled;
    console.info(`AbsoluteMouseManager: absoluteMouseMode = ${enabled}`);
  }

  /**
   * 获取是否启用绝对鼠标模式
   */
  public isAbsoluteMouseMode(): boolean {
    return this.absoluteMouseMode;
  }

  /**
   * 处理触控板相对移动（触控板模式）
   * 累加 delta 到虚拟光标位置，发送绝对坐标
   */
  public handleRelativeMove(deltaX: number, deltaY: number, sensitivity: number = 1.0): void {
    if (!this.mouseSender) return;

    if (this.absoluteMouseMode) {
      // 绝对模式：累加到虚拟光标，发送绝对位置
      this.cursorX += deltaX * sensitivity;
      this.cursorY += deltaY * sensitivity;
      this.cursorX = Math.max(0, Math.min(this.cursorX, this.viewWidth - 1));
      this.cursorY = Math.max(0, Math.min(this.cursorY, this.viewHeight - 1));

      this.mouseSender.sendMousePosition(
        Math.floor(this.cursorX),
        Math.floor(this.cursorY),
        this.viewWidth,
        this.viewHeight
      );
    } else {
      // 相对模式：直接发送相对移动
      this.mouseSender.sendMouseMove(
        Math.floor(deltaX * sensitivity),
        Math.floor(deltaY * sensitivity)
      );
    }
  }

  /**
   * 处理物理鼠标移动事件
   * 直接发送鼠标事件的绝对坐标
   */
  public handleMouseEvent(x: number, y: number): void {
    if (!this.mouseSender || !this.absoluteMouseMode) return;

    // 同步虚拟光标位置
    this.cursorX = x;
    this.cursorY = y;

    this.mouseSender.sendMousePosition(
      Math.floor(x),
      Math.floor(y),
      this.viewWidth,
      this.viewHeight
    );
  }

  /**
   * 重置虚拟光标到屏幕中心
   */
  public resetPosition(): void {
    this.cursorX = this.viewWidth / 2;
    this.cursorY = this.viewHeight / 2;
  }

  /**
   * 销毁管理器
   */
  public destroy(): void {
    this.mouseSender = null;
    this.absoluteMouseMode = false;
  }

  /**
   * 重置单例
   */
  public static resetInstance(): void {
    if (AbsoluteMouseManager.instance) {
      AbsoluteMouseManager.instance.destroy();
      AbsoluteMouseManager.instance = null;
    }
  }
}

// 为了兼容性，保留旧名称别名
export const LocalCursorManager = AbsoluteMouseManager;
