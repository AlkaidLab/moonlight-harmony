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
 * 自定义按键覆盖层
 *
 * 参照 VirtualController 的经验重构（ARKUI_TOUCH_HANDLING_LESSONS.md）：
 *   - 每个按键是独立 @Component（如 AnalogStick），有自己的 @State 和触摸处理器
 *   - 每个按钮使用 HitTestMode.Block + event.stopPropagation()
 *   - 编辑模式拖拽通过按钮内部 @State 实现，不触发父级重渲染
 *   - 父层使用 hitTestReady 延迟刷新命中测试区域
 */

import { vibrator } from '@kit.SensorServiceKit';
import { componentSnapshot, display, LengthMetrics, promptAction } from '@kit.ArkUI';
import {
  CustomKeyDef,
  KeyAction,
  KeyBehavior,
  KeyShape,
  AnalogStickAction,
  DPadAction,
  WheelPadAction,
  DigitalStickAction,
  createDefaultKeyDef,
  cloneKeyDef,
  KEY_PRESET_CATEGORIES,
  KeyPreset,
  KeyPresetCategory,
} from '../service/CustomKeyTypes';
import { CustomKeyStore } from '../service/CustomKeyStore';
import { QrShareService } from '../service/QrShareService';
import { VirtualJoystick } from './VirtualJoystick';
import { VirtualDPad } from './VirtualDPad';
import { VirtualWheelPad } from './VirtualWheelPad';
import { image } from '@kit.ImageKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  OV_ACCENT_BLUE, OV_TEXT_BRIGHT, OV_TEXT_MEDIUM, OV_TEXT_DIM,
  OV_TEXT_WHITE, OV_TEXT_SUBTLE, OV_BG_TRACK, OV_BG_CARD_LIGHTER,
  OV_BG_CARD_DARK, OV_BLUE_40, OV_BLUE_50,
  OV_FONT_SM, OV_FONT_MD, OV_FONT_LG,
} from '../common/OverlayConstants';

/** 数字摇杆每个按键的四方向按下状态 */
interface DigitalDirState {
  up: boolean;
  down: boolean;
  left: boolean;
  right: boolean;
}

/** 吸附计算结果 */
interface SnapResult {
  /** 吸附后的 vp 偏移 X */
  dx: number;
  /** 吸附后的 vp 偏移 Y */
  dy: number;
}

// =============================================================================
// 常量
// =============================================================================

const EDIT_BORDER_COLOR = '#80FF6B6B';
const SELECT_BORDER_COLOR = '#FFFFD700';
const EDIT_TOOLBAR_HEIGHT = 48;
const DRAG_THRESHOLD = 5;

/** 预设颜色：背景色 */
const BG_COLOR_PRESETS: string[] = [
  '#401A1A2E', '#40A8D8EA', '#40FF6B6B', '#4050C080',
  '#40FFD700', '#40D06060', '#406098C0', '#40FF8C00',
];

/** 预设颜色：文字色 */
const TEXT_COLOR_PRESETS: string[] = [
  '#E0FFFFFF', '#FFFFD700', '#FFA8D8EA', '#FFFF6B6B',
  '#FF50C080', '#FFFF8C00', '#FFD06060', '#FF6098C0',
];

/** 预设颜色：按压色 */
const PRESSED_COLOR_PRESETS: string[] = [
  '#80A8D8EA', '#80FF6B6B', '#8050C080', '#80FFD700',
  '#80D06060', '#806098C0', '#80FF8C00', '#80E070E0',
];

/** 振动等级选项 */
const HAPTIC_OPTIONS: Array<[string, string]> = [
  ['none', '无'], ['light', '轻'], ['medium', '中'], ['heavy', '重'],
];

/** 根据 haptic 等级触发振动 */
function doKeyHaptic(level: string): void {
  let duration = 0;
  switch (level) {
    case 'light': duration = 15; break;
    case 'medium': duration = 40; break;
    case 'heavy': duration = 80; break;
    default: return;
  }
  try {
    vibrator.startVibration({ type: 'time', duration }, { id: 0, usage: 'touch' });
  } catch (_e) { /* ignore */ }
}

// =============================================================================
// 独立按键组件（参照 AnalogStick 设计 —— 独立 @Component 保证触摸处理器稳定）
// =============================================================================

@Component
struct CustomKeyBtn {
  // ── 配置属性 ──
  keyDef: CustomKeyDef = createDefaultKeyDef();
  @Prop editMode: boolean = false;
  @Prop isSelected: boolean = false;

  // ── 回调 ──
  onAction: (action: KeyAction, isDown: boolean) => void = () => {};
  /** 拖拽完成回调，参数为 vp 偏移量 (deltaX, deltaY) */
  onDragFinish: (keyId: string, deltaX: number, deltaY: number) => void = () => {};
  onSelect: (keyId: string) => void = () => {};
  onLongPress: (keyId: string) => void = () => {};

  /**
   * 吸附计算回调：传入按键 ID 和原始 vp 偏移，返回吸附后的 vp 偏移
   * 返回 null 表示不吸附
   */
  snapCalculator: (keyId: string, rawDx: number, rawDy: number) => SnapResult | null = () => null;

  // ── 内部状态（独立 @State —— 触摸时变化只触发自身重渲染） ──
  @State private isPressed: boolean = false;
  @State private isToggled: boolean = false;
  /** 拖拽偏移（视觉 translate） */
  @State private dragOffsetX: number = 0;
  @State private dragOffsetY: number = 0;

  // 拖拽追踪（非 @State）
  private dragging: boolean = false;
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private longPressTimer: number = -1;

  build() {
    Text(this.keyDef.label)
      .fontSize(this.keyDef.fontSize)
      .fontColor(this.isPressed || this.isToggled ? OV_TEXT_WHITE : this.keyDef.textColor)
      .fontWeight(FontWeight.Bold)
      .textAlign(TextAlign.Center)
      .width(this.keyDef.width)
      .height(this.keyDef.height)
      .borderRadius(this.keyDef.shape === 'circle'
        ? this.keyDef.width / 2
        : this.keyDef.borderRadius)
      .backgroundColor(this.isPressed || this.isToggled
        ? this.keyDef.pressedColor
        : this.keyDef.bgColor)
      .border({
        width: this.editMode ? 2 : (this.keyDef.borderWidth ?? 1),
        color: this.editMode
          ? (this.isSelected ? SELECT_BORDER_COLOR : EDIT_BORDER_COLOR)
          : (this.isPressed || this.isToggled
              ? this.keyDef.pressedColor
              : this.keyDef.normalColor),
        style: this.editMode ? BorderStyle.Dashed : BorderStyle.Solid,
      })
      .shadow({
        radius: this.isPressed || this.isToggled ? 8 : 3,
        color: this.isPressed || this.isToggled ? '#40A8D8EA' : '#20000000',
        offsetY: 1,
      })
      .opacity(this.keyDef.opacity / 100)
      .translate({ x: this.dragOffsetX, y: this.dragOffsetY })
      .hitTestBehavior(HitTestMode.Block)
      .onTouch((event: TouchEvent) => {
        event.stopPropagation();
        if (this.editMode) {
          this.handleEditTouch(event);
        } else {
          this.handlePlayTouch(event);
        }
      })
  }

  // ── 普通模式触摸处理 ──

  private handlePlayTouch(event: TouchEvent): void {
    if (this.keyDef.behavior === 'toggle') {
      if (event.type === TouchType.Down) {
        this.isToggled = !this.isToggled;
        this.onAction(this.keyDef.action, this.isToggled);
        this.doHaptic();
      }
      return;
    }
    // 点触模式
    if (event.type === TouchType.Down) {
      this.isPressed = true;
      this.onAction(this.keyDef.action, true);
      this.doHaptic();
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.isPressed = false;
      this.onAction(this.keyDef.action, false);
    }
  }

  // ── 编辑模式触摸处理（拖拽 + 长按 + 选中） ──

  private handleEditTouch(event: TouchEvent): void {
    const touch = event.touches[0];
    if (!touch) return;

    switch (event.type) {
      case TouchType.Down:
        this.dragStartX = touch.windowX;
        this.dragStartY = touch.windowY;
        this.dragOffsetX = 0;
        this.dragOffsetY = 0;
        this.dragging = false;

        this.cancelLongPress();
        this.longPressTimer = setTimeout(() => {
          if (!this.dragging) {
            this.onLongPress(this.keyDef.id);
            this.doHaptic();
          }
          this.longPressTimer = -1;
        }, 500) as number;
        break;

      case TouchType.Move: {
        const dx = touch.windowX - this.dragStartX;
        const dy = touch.windowY - this.dragStartY;
        if (!this.dragging && Math.abs(dx) + Math.abs(dy) > DRAG_THRESHOLD) {
          this.dragging = true;
          this.cancelLongPress();
        }
        if (this.dragging) {
          const snapResult = this.snapCalculator(this.keyDef.id, dx, dy);
          if (snapResult) {
            this.dragOffsetX = snapResult.dx;
            this.dragOffsetY = snapResult.dy;
          } else {
            this.dragOffsetX = dx;
            this.dragOffsetY = dy;
          }
        }
        break;
      }

      case TouchType.Up:
      case TouchType.Cancel:
        this.cancelLongPress();
        if (this.dragging) {
          // 传递 vp 偏移量（不是新坐标），由父层转换为百分比
          this.onDragFinish(this.keyDef.id,
            this.dragOffsetX,
            this.dragOffsetY);
        } else {
          this.onSelect(this.keyDef.id);
        }
        this.dragging = false;
        break;
    }
  }

  private cancelLongPress(): void {
    if (this.longPressTimer !== -1) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  private doHaptic(): void {
    doKeyHaptic(this.keyDef.haptic ?? 'light');
  }
}

// =============================================================================
// 主覆盖层组件
// =============================================================================

@Component
export struct CustomKeyOverlay {
  /** 按键事件回调（统一入口，包含 keyboard/mouse/gamepad/special 所有类型） */
  onKeyAction: (action: KeyAction, isDown: boolean) => void = () => {};
  /** 模拟摇杆移动回调 */
  onAnalogStickMovement: (stick: string, x: number, y: number) => void = () => {};
  /** 模拟摇杆 L3/R3 点击回调（双击触发，自动短按+释放） */
  onAnalogStickClick: (stick: string) => void = () => {};
  /** 十字键盘方向变化回调（位掩码，0=无方向） */
  onDPadDirectionChange: (direction: number) => void = () => {};
  /** 编辑模式变化回调 */
  onEditModeChanged: (editing: boolean) => void = () => {};

  // ── 状态 ──
  @State keys: CustomKeyDef[] = [];
  @Link editMode: boolean;
  @State selectedKeyId: string = '';
  @State showAddPanel: boolean = false;
  @State showPropertyPanel: boolean = false;
  @State addPanelCategoryIdx: number = 0;

  /**
   * 命中测试刷新触发器（参照 VirtualControllerOverlay）。
   * 延迟在父层触发一次重渲染，刷新整棵子树的命中测试区域。
   */
  @State private hitTestReady: number = 0;

  /** 屏幕尺寸 (vp)，用于百分比坐标↔绝对坐标转换 */
  @State private screenWidthVp: number = 0;
  @State private screenHeightVp: number = 0;
  /** 数字摇杆方向追踪状态（按 keyId 索引） */
  private digitalStickStates: Map<string, DigitalDirState> = new Map();
  /** 撤销/重做栈 */
  private undoStack: CustomKeyDef[][] = [];
  private redoStack: CustomKeyDef[][] = [];
  private static readonly MAX_UNDO = 50;
  @State private canUndo: boolean = false;
  @State private canRedo: boolean = false;
  /** 缩放手柄拖拽状态 */
  @State private resizeDragDX: number = 0;
  @State private resizeDragDY: number = 0;
  private resizing: boolean = false;
  private resizeStartX: number = 0;
  private resizeStartY: number = 0;
  private resizeOrigWidth: number = 0;
  private resizeOrigHeight: number = 0;
  /** 元素对齐吸附 */
  @State private snapEnabled: boolean = false;
  /** 吸附阈值 (vp) */
  private static readonly SNAP_THRESHOLD_VP = 8;
  /** 对齐辅助线位置 (vp)，-1 表示隐藏 */
  @State private alignGuideX: number = -1;
  @State private alignGuideY: number = -1;

  /** 二维码分享面板 */
  @State private showSharePanel: boolean = false;
  @State private qrPixelMap: image.PixelMap | undefined = undefined;
  @State private qrLoading: boolean = false;
  @State private qrTooLarge: boolean = false;
  @State private qrError: string = '';
  @State private shareJson: string = '';
  /** 扫码导入预览 */
  @State private importPreviewName: string = '';
  @State private importPreviewCount: number = 0;
  @State private importPreviewKeys: CustomKeyDef[] = [];
  @State private showImportConfirm: boolean = false;

  /** 获取按 layer 升序排列的按键（layer 大的在上层） */
  private getSortedKeys(): CustomKeyDef[] {
    return this.keys.slice().sort((a: CustomKeyDef, b: CustomKeyDef) => a.layer - b.layer);
  }

  /** 屏幕变化监听回调引用，用于注销 */
  private displayChangeCallback: ((displayId: number) => void) | null = null;

  async aboutToAppear(): Promise<void> {
    // 获取屏幕尺寸
    const displayInfo = display.getDefaultDisplaySync();
    this.screenWidthVp = px2vp(displayInfo.width);
    this.screenHeightVp = px2vp(displayInfo.height);

    // 监听屏幕变化（折叠屏展开/折叠、旋转等），动态更新坐标基准
    this.displayChangeCallback = (_displayId: number): void => {
      try {
        const info = display.getDefaultDisplaySync();
        const newW = px2vp(info.width);
        const newH = px2vp(info.height);
        if (newW > 0 && newH > 0 && (newW !== this.screenWidthVp || newH !== this.screenHeightVp)) {
          console.info(`[CustomKeyOverlay] 屏幕尺寸变化: ${this.screenWidthVp}x${this.screenHeightVp} → ${newW}x${newH}`);
          this.screenWidthVp = newW;
          this.screenHeightVp = newH;
        }
      } catch (e) {
        console.warn('[CustomKeyOverlay] 获取屏幕尺寸失败:', e);
      }
    };
    try {
      display.on('change', this.displayChangeCallback);
    } catch (e) {
      console.warn('[CustomKeyOverlay] 注册屏幕变化监听失败:', e);
    }

    await CustomKeyStore.init();
    this.keys = await CustomKeyStore.getKeys();

    // 延迟刷新命中测试区域（与 VirtualControllerOverlay 同理）
    setTimeout(() => {
      this.hitTestReady = 1;
    }, 100);
  }

  aboutToDisappear(): void {
    // 注销屏幕变化监听
    if (this.displayChangeCallback) {
      try {
        display.off('change', this.displayChangeCallback);
      } catch (_e) { /* ignore */ }
      this.displayChangeCallback = null;
    }
  }

  build() {
    Column() {
      // 主区域
      Stack() {
        // 对齐辅助线（拖拽吸附时显示）
        if (this.editMode && this.snapEnabled) {
          this.AlignmentGuides()
        }

        // 自定义按键 —— 每个是独立 @Component，有自己的触摸生命周期
        // 按 layer 升序排列，layer 大的在上层
        ForEach(this.getSortedKeys(), (key: CustomKeyDef) => {
          if (key.action.type === 'analogStick' && !this.editMode) {
            // 模拟摇杆：非编辑模式时渲染真正的虚拟摇杆 UI
            Column() {
              VirtualJoystick({
                joystickSize: Math.max(key.width, key.height),
                ringColor: key.normalColor,
                stickColor: key.bgColor,
                pressedColor: key.pressedColor,
                opacity_: key.opacity,
                invisibleMode: (key.action as AnalogStickAction).invisible === true,
                onMovement: (x: number, y: number): void => {
                  const stickAction = key.action as AnalogStickAction;
                  const sens = stickAction.sensitivity ?? 1.0;
                  const sx = Math.max(-1, Math.min(1, x * sens));
                  const sy = Math.max(-1, Math.min(1, y * sens));
                  this.onAnalogStickMovement(stickAction.stick, sx, sy);
                },
                onStickClick: (): void => {
                  // 单击仅开始追踪，不发送任何按键
                },
                onDoubleClick: (): void => {
                  // 双击触发 L3/R3 短按+自动释放（与 AnalogStick 一致）
                  const stickAction = key.action as AnalogStickAction;
                  doKeyHaptic(key.haptic ?? 'light');
                  this.onAnalogStickClick(stickAction.stick);
                },
                onRevoke: (): void => {
                  // 手指抬起：无需额外操作（L3/R3 已自动释放）
                },
                isEditMode: (): boolean => this.editMode,
              })
            }
              .position({
                x: key.xPercent * this.screenWidthVp - Math.max(key.width, key.height) / 2,
                y: key.yPercent * this.screenHeightVp - Math.max(key.width, key.height) / 2,
              })
          } else if (key.action.type === 'dpad' && !this.editMode) {
            // 十字键盘：非编辑模式时渲染 VirtualDPad 控件
            Column() {
              VirtualDPad({
                dpadSize: Math.max(key.width, key.height),
                normalColor: key.normalColor,
                pressedColor: key.pressedColor,
                bgColor: key.bgColor,
                opacity_: key.opacity,
                onDirectionChange: (direction: number): void => {
                  if (direction > 0) doKeyHaptic(key.haptic ?? 'light');
                  this.onDPadDirectionChange(direction);
                },
                isEditMode: (): boolean => this.editMode,
              })
            }
              .position({
                x: key.xPercent * this.screenWidthVp - Math.max(key.width, key.height) / 2,
                y: key.yPercent * this.screenHeightVp - Math.max(key.width, key.height) / 2,
              })
          } else if (key.action.type === 'wheelPad' && !this.editMode) {
            // 轮盘菜单：非编辑模式时渲染 VirtualWheelPad 控件
            Column() {
              VirtualWheelPad({
                wheelSize: Math.max(key.width, key.height),
                normalColor: key.normalColor,
                pressedColor: key.pressedColor,
                bgColor: key.bgColor,
                textColor: key.textColor,
                opacity_: key.opacity,
                segments: (key.action as WheelPadAction).segments,
                onSegmentAction: (action: KeyAction, isDown: boolean): void => {
                  if (isDown) doKeyHaptic(key.haptic ?? 'light');
                  this.onKeyAction(action, isDown);
                },
                isEditMode: (): boolean => this.editMode,
              })
            }
              .position({
                x: key.xPercent * this.screenWidthVp - Math.max(key.width, key.height) / 2,
                y: key.yPercent * this.screenHeightVp - Math.max(key.width, key.height) / 2,
              })
          } else if (key.action.type === 'digitalStick' && !this.editMode) {
            // 数字摇杆：外观同模拟摇杆，输出离散四方向
            Column() {
              VirtualJoystick({
                joystickSize: Math.max(key.width, key.height),
                ringColor: key.normalColor,
                stickColor: key.bgColor,
                pressedColor: key.pressedColor,
                opacity_: key.opacity,
                onMovement: (x: number, y: number): void => {
                  this.handleDigitalStickMovement(key.id, key.action as DigitalStickAction, x, y);
                },
                onStickClick: (): void => {},
                onDoubleClick: (): void => {
                  const dsAction = key.action as DigitalStickAction;
                  if (dsAction.clickAction) {
                    doKeyHaptic(key.haptic ?? 'light');
                    this.onKeyAction(dsAction.clickAction, true);
                    setTimeout(() => {
                      this.onKeyAction(dsAction.clickAction!, false);
                    }, 100);
                  }
                },
                onRevoke: (): void => {
                  this.releaseAllDigitalDirections(key.id, key.action as DigitalStickAction);
                },
                isEditMode: (): boolean => this.editMode,
              })
            }
              .position({
                x: key.xPercent * this.screenWidthVp - Math.max(key.width, key.height) / 2,
                y: key.yPercent * this.screenHeightVp - Math.max(key.width, key.height) / 2,
              })
          } else {
            // 普通按键（含编辑模式下的 analogStick 占位）
            Column() {
              CustomKeyBtn({
                keyDef: key,
                editMode: this.editMode,
                isSelected: this.selectedKeyId === key.id,
                snapCalculator: (keyId: string, rawDx: number, rawDy: number): SnapResult | null => {
                  return this.calcAlignmentSnap(keyId, rawDx, rawDy);
                },
                onAction: (action: KeyAction, isDown: boolean): void => {
                  this.onKeyAction(action, isDown);
                },
                onDragFinish: (keyId: string, deltaX: number, deltaY: number): void => {
                  this.alignGuideX = -1;
                  this.alignGuideY = -1;
                  this.handleDragEnd(keyId, deltaX, deltaY);
                },
                onSelect: (keyId: string): void => {
                  this.selectedKeyId = keyId;
                },
                onLongPress: (keyId: string): void => {
                  this.selectedKeyId = keyId;
                  this.showPropertyPanel = true;
                },
              })
            }
              .position({
                x: key.xPercent * this.screenWidthVp - key.width / 2,
                y: key.yPercent * this.screenHeightVp - key.height / 2,
              })
          }
        }, (key: CustomKeyDef) => {
          // key 包含位置和外观属性，任何变化都触发组件重建
          // 加上 editMode 以在模式切换时强制重建（切换 VirtualJoystick ↔ CustomKeyBtn）
          return `${key.id}|${this.editMode}|${key.xPercent.toFixed(4)}|${key.yPercent.toFixed(4)}|${key.width}|${key.height}|${key.opacity}|${key.fontSize}|${key.borderRadius}|${key.borderWidth}|${key.shape}|${key.behavior}|${key.label}|${key.bgColor}|${key.textColor}`;
        })

        // 缩放手柄：选中按键时显示在右下角
        if (this.editMode && this.selectedKeyId) {
          this.ResizeHandle()
        }

        // 添加按键面板
        if (this.showAddPanel) {
          this.AddKeyPanel()
        }

        // 属性编辑面板
        if (this.showPropertyPanel && this.selectedKeyId) {
          this.PropertyPanel()
        }

        // 二维码分享面板
        if (this.showSharePanel) {
          this.SharePanel()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.BottomStart)
      .hitTestBehavior(HitTestMode.Transparent)
      // hitTestReady: 微小 opacity 变化触发父层重渲染，刷新命中测试树
      .opacity(this.hitTestReady > 0 ? 1 : 0.99)

      // 编辑模式工具栏（面板打开时隐藏，避免遮挡面板）
      if (this.editMode && !this.showAddPanel && !this.showPropertyPanel && !this.showSharePanel) {
        Row({ space: 12 }) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.plus_circle'))
              .fontSize(16).fontColor([Color.White])
            Text('添加')
              .fontSize(OV_FONT_LG).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
          }
          .height(32).padding({ left: 10, right: 12 })
          .borderRadius(16).backgroundColor('#50C080')
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { this.showAddPanel = true; })

          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(16).fontColor([Color.White])
            Text('删除')
              .fontSize(OV_FONT_LG).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
          }
          .height(32).padding({ left: 10, right: 12 })
          .borderRadius(16).backgroundColor('#D06060')
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { if (this.selectedKeyId) { this.deleteSelectedKey(); } })

          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.gearshape'))
              .fontSize(16).fontColor([Color.White])
            Text('属性')
              .fontSize(OV_FONT_LG).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
          }
          .height(32).padding({ left: 10, right: 12 })
          .borderRadius(16).backgroundColor('#6098C0')
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { if (this.selectedKeyId) { this.showPropertyPanel = true; } })

          Row({ space: 4 }) {
            Text('⊞')
              .fontSize(16).fontColor(this.snapEnabled ? Color.White : '#60FFFFFF')
            Text('吸附')
              .fontSize(OV_FONT_LG).fontColor(this.snapEnabled ? OV_TEXT_WHITE : '#60FFFFFF').fontWeight(FontWeight.Medium)
          }
          .height(32).padding({ left: 10, right: 12 })
          .borderRadius(16).backgroundColor(this.snapEnabled ? '#5090B0' : '#40404060')
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { this.snapEnabled = !this.snapEnabled; })

          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.share'))
              .fontSize(16)
              .fontColor([Color.White])
            Text('分享')
              .fontSize(OV_FONT_LG).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
          }
          .height(32).padding({ left: 10, right: 12 })
          .borderRadius(16).backgroundColor('#7060A0')
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { this.openSharePanel(); })

          Blank()

          Stack() {
            SymbolGlyph($r('sys.symbol.undo'))
              .fontSize(18)
              .fontColor(this.canUndo ? [Color.White] : ['#60FFFFFF'])
          }
          .width(32).height(32)
          .borderRadius(16)
          .backgroundColor(this.canUndo ? '#8070B0' : '#40404060')
          .alignContent(Alignment.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { this.performUndo(); })

          Stack() {
            SymbolGlyph($r('sys.symbol.redo'))
              .fontSize(18)
              .fontColor(this.canRedo ? [Color.White] : ['#60FFFFFF'])
          }
          .width(32).height(32)
          .borderRadius(16)
          .backgroundColor(this.canRedo ? '#8070B0' : '#40404060')
          .alignContent(Alignment.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { this.performRedo(); })

          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.checkmark_circle'))
              .fontSize(16).fontColor([Color.White])
            Text('完成')
              .fontSize(OV_FONT_LG).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
          }
          .height(32).padding({ left: 10, right: 12 })
          .borderRadius(16).backgroundColor('#A8D8EA')
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { this.exitEditMode(); })
        }
        .width('100%')
        .height(EDIT_TOOLBAR_HEIGHT)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#CC1A1A2E')
        .backdropBlur(30)
        .border({ width: { top: 1 }, color: '#20FFFFFF' })
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 撤销/重做
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /** 保存当前状态到撤销栈（在操作之前调用） */
  private pushUndoState(): void {
    this.undoStack.push(this.keys.map(k => cloneKeyDef(k)));
    if (this.undoStack.length > CustomKeyOverlay.MAX_UNDO) {
      this.undoStack.shift();
    }
    this.redoStack = [];
    this.canUndo = this.undoStack.length > 0;
    this.canRedo = false;
  }

  /** 撤销：恢复上一个状态 */
  private async performUndo(): Promise<void> {
    if (this.undoStack.length === 0) return;
    // 当前状态压入重做栈
    this.redoStack.push(this.keys.map(k => cloneKeyDef(k)));
    // 弹出上一个状态
    const prev = this.undoStack.pop()!;
    this.keys = prev;
    this.selectedKeyId = '';
    this.canUndo = this.undoStack.length > 0;
    this.canRedo = this.redoStack.length > 0;
    await CustomKeyStore.saveKeys(this.keys);
  }

  /** 重做：恢复下一个状态 */
  private async performRedo(): Promise<void> {
    if (this.redoStack.length === 0) return;
    // 当前状态压入撤销栈
    this.undoStack.push(this.keys.map(k => cloneKeyDef(k)));
    // 弹出重做状态
    const next = this.redoStack.pop()!;
    this.keys = next;
    this.selectedKeyId = '';
    this.canUndo = this.undoStack.length > 0;
    this.canRedo = this.redoStack.length > 0;
    await CustomKeyStore.saveKeys(this.keys);
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 编辑操作
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /**
   * 数字摇杆移动：将连续 x/y → 离散四方向 pressed/released
   * 阈值 0.5，支持对角线同时激活相邻方向
   */
  private handleDigitalStickMovement(keyId: string, action: DigitalStickAction, x: number, y: number): void {
    let state = this.digitalStickStates.get(keyId);
    if (!state) {
      state = { up: false, down: false, left: false, right: false } as DigitalDirState;
      this.digitalStickStates.set(keyId, state);
    }
    const threshold = 0.5;

    // 左右轴
    if (x < -threshold && !state.left) {
      state.left = true;
      this.onKeyAction(action.leftAction, true);
    } else if (x >= -threshold && state.left) {
      state.left = false;
      this.onKeyAction(action.leftAction, false);
    }
    if (x > threshold && !state.right) {
      state.right = true;
      this.onKeyAction(action.rightAction, true);
    } else if (x <= threshold && state.right) {
      state.right = false;
      this.onKeyAction(action.rightAction, false);
    }

    // 上下轴（y 负=上，正=下）
    if (y < -threshold && !state.up) {
      state.up = true;
      this.onKeyAction(action.upAction, true);
    } else if (y >= -threshold && state.up) {
      state.up = false;
      this.onKeyAction(action.upAction, false);
    }
    if (y > threshold && !state.down) {
      state.down = true;
      this.onKeyAction(action.downAction, true);
    } else if (y <= threshold && state.down) {
      state.down = false;
      this.onKeyAction(action.downAction, false);
    }
  }

  /** 数字摇杆释放：释放所有仍处于按下状态的方向 */
  private releaseAllDigitalDirections(keyId: string, action: DigitalStickAction): void {
    const state = this.digitalStickStates.get(keyId);
    if (!state) return;
    if (state.up) { this.onKeyAction(action.upAction, false); state.up = false; }
    if (state.down) { this.onKeyAction(action.downAction, false); state.down = false; }
    if (state.left) { this.onKeyAction(action.leftAction, false); state.left = false; }
    if (state.right) { this.onKeyAction(action.rightAction, false); state.right = false; }
  }

  /**
   * PPT 风格元素对齐吸附计算。
   * 检查拖拽中按键的边缘/中心是否与其他按键的边缘/中心对齐，
   * 在阈值范围内则吸附到对齐位置，并更新辅助线坐标。
   */
  private calcAlignmentSnap(keyId: string, rawDx: number, rawDy: number): SnapResult | null {
    if (!this.snapEnabled) return null;
    const key = this.keys.find(k => k.id === keyId);
    if (!key || this.screenWidthVp <= 0) return null;

    const THRESHOLD = CustomKeyOverlay.SNAP_THRESHOLD_VP;
    const W = this.screenWidthVp;
    const H = this.screenHeightVp;

    // 当前拖拽候选位置（中心，vp）
    const candCx = key.xPercent * W + rawDx;
    const candCy = key.yPercent * H + rawDy;
    const halfW = key.width / 2;
    const halfH = key.height / 2;

    // 收集其他元素的对齐目标（vp）
    const targetsX: number[] = [0, W / 2, W]; // 屏幕左、中、右
    const targetsY: number[] = [0, H / 2, H]; // 屏幕上、中、下

    for (const other of this.keys) {
      if (other.id === keyId) continue;
      const ocx = other.xPercent * W;
      const ocy = other.yPercent * H;
      const ohw = other.width / 2;
      const ohh = other.height / 2;
      targetsX.push(ocx - ohw, ocx, ocx + ohw); // 左边缘、中心、右边缘
      targetsY.push(ocy - ohh, ocy, ocy + ohh); // 上边缘、中心、下边缘
    }

    // X 轴：检查左边缘、中心、右边缘与目标的距离
    const candXPoints: number[] = [candCx - halfW, candCx, candCx + halfW];
    let bestDx = rawDx;
    let bestDistX = THRESHOLD;
    let guideX = -1;

    for (let i = 0; i < candXPoints.length; i++) {
      for (const target of targetsX) {
        const dist = Math.abs(candXPoints[i] - target);
        if (dist < bestDistX) {
          bestDistX = dist;
          bestDx = rawDx + (target - candXPoints[i]); // 修正偏移使候选点对齐到目标
          guideX = target;
        }
      }
    }

    // Y 轴：检查上边缘、中心、下边缘与目标的距离
    const candYPoints: number[] = [candCy - halfH, candCy, candCy + halfH];
    let bestDy = rawDy;
    let bestDistY = THRESHOLD;
    let guideY = -1;

    for (let i = 0; i < candYPoints.length; i++) {
      for (const target of targetsY) {
        const dist = Math.abs(candYPoints[i] - target);
        if (dist < bestDistY) {
          bestDistY = dist;
          bestDy = rawDy + (target - candYPoints[i]);
          guideY = target;
        }
      }
    }

    // 更新辅助线（-1 = 隐藏）
    this.alignGuideX = guideX;
    this.alignGuideY = guideY;

    // 有任何一个轴发生吸附就返回结果
    if (guideX >= 0 || guideY >= 0) {
      return { dx: bestDx, dy: bestDy };
    }
    return null;
  }

  private handleDragEnd(keyId: string, deltaX: number, deltaY: number): void {
    const idx = this.keys.findIndex(k => k.id === keyId);
    if (idx === -1) return;
    this.pushUndoState();
    const updated = cloneKeyDef(this.keys[idx]);
    // vp 偏移量 → 百分比偏移量
    if (this.screenWidthVp > 0 && this.screenHeightVp > 0) {
      updated.xPercent = updated.xPercent + deltaX / this.screenWidthVp;
      updated.yPercent = updated.yPercent + deltaY / this.screenHeightVp;
      // 边界约束: 0.0~1.0
      updated.xPercent = Math.max(0.0, Math.min(1.0, updated.xPercent));
      updated.yPercent = Math.max(0.0, Math.min(1.0, updated.yPercent));
    }
    const newKeys: CustomKeyDef[] = this.keys.slice();
    newKeys[idx] = updated;
    this.keys = newKeys;
    CustomKeyStore.saveKeys(this.keys);
  }

  private async addKeyFromPreset(preset: KeyPreset): Promise<void> {
    // 随机偏移让多个按键不完全重叠（偏移量约 ±5% 屏幕宽度）
    const centerXPercent = 0.5 + (Math.random() - 0.5) * 0.1;
    const centerYPercent = 0.5 + (Math.random() - 0.5) * 0.1;

    // 根据按键类型设定智能默认外观
    let shape: KeyShape = 'rect';
    let width = 60;
    let height = 60;
    let bgColor = '#30FFFFFF';
    let textColor = '#E0FFFFFF';
    let pressedColor = '#80A8D8EA';
    let borderRadius = 12;
    let fontSize = 14;

    switch (preset.action.type) {
      case 'gamepadButton':
      case 'gamepadTrigger':
      case 'gamepadStick':
        // 手柄按键：圆形、略大、绿色系
        shape = 'circle';
        width = 56;
        height = 56;
        bgColor = '#3050C080';
        pressedColor = '#8050C080';
        textColor = '#E0FFFFFF';
        borderRadius = 28;
        fontSize = 13;
        break;
      case 'special':
        // 特殊功能：宽矩形、蓝色系
        shape = 'rect';
        width = 72;
        height = 44;
        bgColor = '#306098C0';
        pressedColor = '#806098C0';
        textColor = '#FFA8D8EA';
        fontSize = 12;
        break;
      case 'shortcut':
        // 快捷键：宽矩形、橙色系
        shape = 'rect';
        width = 76;
        height = 44;
        bgColor = '#30C09050';
        pressedColor = '#80C09050';
        textColor = '#FFFFD080';
        fontSize = 11;
        break;
      case 'mouse':
      case 'mouseScroll':
        // 鼠标：圆形、紫色系
        shape = 'circle';
        width = 52;
        height = 52;
        bgColor = '#30A070C0';
        pressedColor = '#80A070C0';
        borderRadius = 26;
        break;
      case 'analogStick':
        // 模拟摇杆：大圆形、绿色系（与手柄按键同色调）
        shape = 'circle';
        if ((preset.action as AnalogStickAction).invisible === true) {
          // 隐形摇杆：更大触摸区域、半透明
          width = 200;
          height = 200;
        } else {
          width = 120;
          height = 120;
        }
        bgColor = '#4050C080';
        pressedColor = '#8070E090';
        textColor = '#E0FFFFFF';
        borderRadius = 60;
        fontSize = 12;
        break;
      case 'dpad':
        // 十字键盘：大正方形、绿色系
        shape = 'rect';
        width = 120;
        height = 120;
        bgColor = '#3050C080';
        pressedColor = '#8070E090';
        textColor = '#E0FFFFFF';
        borderRadius = 8;
        fontSize = 12;
        break;
      case 'wheelPad':
        // 轮盘菜单：大圆形、紫蓝色系
        shape = 'circle';
        width = 150;
        height = 150;
        bgColor = '#306080C0';
        pressedColor = '#80A070E0';
        textColor = '#E0FFFFFF';
        borderRadius = 75;
        fontSize = 11;
        break;
      case 'digitalStick':
        // 数字摇杆：与模拟摇杆同外观，橙色系区分
        shape = 'circle';
        width = 120;
        height = 120;
        bgColor = '#40C09050';
        pressedColor = '#80E0B060';
        textColor = '#E0FFFFFF';
        borderRadius = 60;
        fontSize = 11;
        break;
      default:
        break;
    }

    const newKey = createDefaultKeyDef({
      label: preset.label,
      action: preset.action,
      xPercent: centerXPercent,
      yPercent: centerYPercent,
      shape: shape,
      width: width,
      height: height,
      bgColor: bgColor,
      pressedColor: pressedColor,
      textColor: textColor,
      borderRadius: borderRadius,
      fontSize: fontSize,
    });

    const newArr: CustomKeyDef[] = this.keys.slice();
    newArr.push(newKey);
    this.pushUndoState();
    this.keys = newArr;
    await CustomKeyStore.addKey(newKey);
    this.selectedKeyId = newKey.id;
    this.showAddPanel = false;
  }

  private async deleteSelectedKey(): Promise<void> {
    if (!this.selectedKeyId) return;
    this.pushUndoState();
    this.keys = this.keys.filter(k => k.id !== this.selectedKeyId);
    await CustomKeyStore.deleteKey(this.selectedKeyId);
    this.selectedKeyId = '';
    this.showPropertyPanel = false;
  }

  private getSelectedKey(): CustomKeyDef | undefined {
    return this.keys.find(k => k.id === this.selectedKeyId);
  }

  private updateSelectedKeyProp(prop: string, value: Object): void {
    const idx = this.keys.findIndex(k => k.id === this.selectedKeyId);
    if (idx === -1) return;
    this.pushUndoState();
    const updated = cloneKeyDef(this.keys[idx]);
    switch (prop) {
      case 'width': updated.width = value as number; break;
      case 'height': updated.height = value as number; break;
      case 'opacity': updated.opacity = value as number; break;
      case 'fontSize': updated.fontSize = value as number; break;
      case 'borderRadius': updated.borderRadius = value as number; break;
      case 'behavior': updated.behavior = value as KeyBehavior; break;
      case 'shape': updated.shape = value as KeyShape; break;
      case 'label': updated.label = value as string; break;
      case 'bgColor': updated.bgColor = value as string; break;
      case 'textColor': updated.textColor = value as string; break;
      case 'pressedColor': updated.pressedColor = value as string; break;
      case 'haptic': updated.haptic = value as string; break;
      case 'layer': updated.layer = value as number; break;
      case 'borderWidth': updated.borderWidth = value as number; break;
      default: break;
    }
    const newKeys: CustomKeyDef[] = this.keys.slice();
    newKeys[idx] = updated;
    this.keys = newKeys;
    CustomKeyStore.saveKeys(this.keys);
  }

  enterEditMode(): void {
    this.editMode = true;
    this.selectedKeyId = '';
    this.showAddPanel = false;
    this.showPropertyPanel = false;
    this.showSharePanel = false;
    this.undoStack = [];
    this.redoStack = [];
    this.canUndo = false;
    this.canRedo = false;
    this.onEditModeChanged(true);
    promptAction.showToast({
      message: '单击选中 | 长按属性 | 拖拽移动',
      duration: 2500,
    });
  }

  private async exitEditMode(): Promise<void> {
    this.editMode = false;
    this.selectedKeyId = '';
    this.showAddPanel = false;
    this.showPropertyPanel = false;
    this.showSharePanel = false;
    await CustomKeyStore.saveKeys(this.keys);
    this.onEditModeChanged(false);
  }

  async reloadKeys(): Promise<void> {
    this.keys = await CustomKeyStore.getKeys();
  }

  private getSelectedCategoryPresets(): KeyPreset[] {
    if (this.addPanelCategoryIdx >= 0 && this.addPanelCategoryIdx < KEY_PRESET_CATEGORIES.length) {
      return KEY_PRESET_CATEGORIES[this.addPanelCategoryIdx].presets;
    }
    return [];
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 二维码分享
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /** 打开分享面板并生成二维码 */
  private async openSharePanel(): Promise<void> {
    this.showSharePanel = true;
    this.showImportConfirm = false;
    this.qrLoading = true;
    this.qrTooLarge = false;
    this.qrError = '';
    this.qrPixelMap = undefined;

    const profileName = await CustomKeyStore.getActiveProfileName();
    const json = QrShareService.serialize(profileName, this.keys);
    this.shareJson = json;

    if (!QrShareService.canFitInQr(json)) {
      this.qrTooLarge = true;
      this.qrLoading = false;
      return;
    }

    const result = await QrShareService.generateQrCode(json, 600);
    if (result.pixelMap) {
      this.qrPixelMap = result.pixelMap;
    } else {
      this.qrError = result.error ?? '未知错误';
    }
    this.qrLoading = false;
  }

  /** 复制配置 JSON 到剪贴板 */
  private async copyToClipboard(): Promise<void> {
    try {
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.shareJson);
      const sysBoard = pasteboard.getSystemPasteboard();
      await sysBoard.setData(pasteData);
      promptAction.showToast({ message: '已复制到剪贴板', duration: 1500 });
    } catch (_e) {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    }
  }

  /** 通过系统分享面板分享美化卡片（含二维码 + 标题） */
  private async shareToFriend(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const profileName = await CustomKeyStore.getActiveProfileName();
      const keyCount = this.keys.length;
      const qrPixel = this.qrPixelMap;

      // 先关闭自身面板，避免与系统分享面板冲突
      this.showSharePanel = false;

      let shareData: systemShare.SharedData;

      if (qrPixel) {
        // 用 componentSnapshot 渲染美化卡片
        const cardPixelMap = await componentSnapshot.createFromBuilder((): void => {
          this.ShareCardBuilder(qrPixel, profileName, keyCount);
        }, 300, true);

        const tempPath = context.tempDir + '/moonlight_share_card.png';
        const packer = image.createImagePacker();
        const buf = await packer.packing(cardPixelMap, { format: 'image/png', quality: 100 });
        packer.release();
        const file = fileIo.openSync(tempPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, buf);
        fileIo.closeSync(file.fd);

        shareData = new systemShare.SharedData({
          utd: 'general.png',
          uri: fileUri.getUriFromPath(tempPath),
          title: `Moonlight · ${profileName}`,
          description: `${keyCount} 个自定义按键`,
        });
      } else {
        // 无二维码：分享文本
        shareData = new systemShare.SharedData({
          utd: 'general.plain-text',
          content: this.shareJson,
          title: `Moonlight · ${profileName}`,
        });
      }

      const controller = new systemShare.ShareController(shareData);
      await controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT,
      });
    } catch (e) {
      console.error('[CustomKeyOverlay] 分享失败:', JSON.stringify(e));
      promptAction.showToast({ message: '分享失败', duration: 1500 });
    }
  }

  @Builder
  ShareCardBuilder(qrPixel: image.PixelMap, profileName: string, keyCount: number) {
    Stack() {
      // ── 装饰背景层 ──
      // 主渐变背景
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 135,
          colors: [['#FF0F1628', 0], ['#FF162040', 0.35], ['#FF1A1040', 0.65], ['#FF10101E', 1]],
        })

      // 右上角装饰光晕
      Circle()
        .width(180).height(180)
        .fill('#00000000')
        .radialGradient({
          center: [90, 90],
          radius: 90,
          colors: [['#18A8D8EA', 0], ['#00A8D8EA', 1]],
        })
        .position({ right: -40, top: -40 })

      // 左下角装饰光晕
      Circle()
        .width(140).height(140)
        .fill('#00000000')
        .radialGradient({
          center: [70, 70],
          radius: 70,
          colors: [['#128060C0', 0], ['#008060C0', 1]],
        })
        .position({ left: -30, bottom: -30 })

      // ── 内容层 ──
      Column() {
        // 顶部品牌区
        Row({ space: 10 }) {
          Image($r('app.media.app_icon'))
            .width(36).height(36)
            .borderRadius(8)
          Column({ space: 2 }) {
            Text('Moonlight V+')
              .fontSize(18).fontColor('#FFA8D8EA').fontWeight(FontWeight.Bold)
            Text('王冠的自定义按键配置分享')
              .fontSize(11).fontColor('#80FFFFFF')
          }
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 24, right: 24, top: 24, bottom: 16 })

        // 二维码区域 — 带渐变边框和内阴影效果
        Stack() {
          // 外层渐变边框
          Column()
            .width(244).height(244)
            .borderRadius(18)
            .linearGradient({
              angle: 135,
              colors: [['#40A8D8EA', 0], ['#208060C0', 0.5], ['#30A8D8EA', 1]],
            })

          // 白色内容区
          Column() {
            Image(qrPixel)
              .width(200).height(200)
              .objectFit(ImageFit.Contain)
          }
          .width(236).height(236)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#FFFFFFFF')
          .borderRadius(16)
        }
        .alignContent(Alignment.Center)

        // 配置名称 + 按键数
        Column({ space: 6 }) {
          Text(profileName)
            .fontSize(16).fontColor('#FFFFFFFF').fontWeight(FontWeight.Bold)
            .textAlign(TextAlign.Center)
          Row({ space: 6 }) {
            Text(`${keyCount}`)
              .fontSize(13).fontColor('#FFA8D8EA').fontWeight(FontWeight.Bold)
            Text('个按键')
              .fontSize(12).fontColor('#99A8D8EA')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 16, bottom: 14 })

        // 底部提示
        Divider().color('#20A8D8EA').width('60%')
        Text('打开 Moonlight V+ → 扫一扫即可导入')
          .fontSize(11).fontColor('#60FFFFFF')
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 24 })
      }
    }
    .width(320)
    .height(420)
    .borderRadius(20)
    .border({ width: 1, color: '#25A8D8EA' })
    .clip(true)
  }

  /** 从剪贴板粘贴导入 */
  private async pasteFromClipboard(): Promise<void> {
    try {
      const sysBoard = pasteboard.getSystemPasteboard();
      const pasteData = await sysBoard.getData();
      const text = pasteData.getPrimaryText();
      if (!text) {
        promptAction.showToast({ message: '剪贴板为空', duration: 1500 });
        return;
      }
      this.handleImportJson(text);
    } catch (_e) {
      promptAction.showToast({ message: '读取剪贴板失败', duration: 1500 });
    }
  }

  /** 调用系统相机扫码导入 */
  private async scanAndImport(): Promise<void> {
    const result = await QrShareService.scanQrCode();
    if (!result) {
      promptAction.showToast({ message: '扫码取消或失败', duration: 1500 });
      return;
    }
    this.handleImportJson(result);
  }

  /** 解析 JSON 并显示导入确认 */
  private handleImportJson(json: string): void {
    const parsed = QrShareService.deserialize(json);
    if (!parsed) {
      promptAction.showToast({ message: '无效的配置数据', duration: 2000 });
      return;
    }
    this.importPreviewName = parsed[0];
    this.importPreviewKeys = parsed[1];
    this.importPreviewCount = parsed[1].length;
    this.showImportConfirm = true;
  }

  /** 执行替换导入 — 替换当前所有按键 */
  private async doImportReplace(): Promise<void> {
    this.pushUndoState();
    this.keys = this.importPreviewKeys;
    await CustomKeyStore.saveKeys(this.keys);
    this.showImportConfirm = false;
    this.showSharePanel = false;
    promptAction.showToast({
      message: `已导入 "${this.importPreviewName}" (${this.importPreviewCount} 个按键)`,
      duration: 2000,
    });
  }

  /** 执行合并导入 — 追加到现有按键 */
  private async doImportMerge(): Promise<void> {
    this.pushUndoState();
    const merged = this.keys.slice();
    for (const k of this.importPreviewKeys) {
      merged.push(k);
    }
    this.keys = merged;
    await CustomKeyStore.saveKeys(this.keys);
    this.showImportConfirm = false;
    this.showSharePanel = false;
    promptAction.showToast({
      message: `已合并 ${this.importPreviewCount} 个按键`,
      duration: 2000,
    });
  }

  @Builder
  AlignmentGuides() {
    // 对齐辅助线 — 拖拽吸附时在对齐位置绘制蓝色参考线
    Stack() {
      if (this.alignGuideX >= 0) {
        Divider()
          .vertical(true)
          .strokeWidth(1)
          .color('#80A8D8EA')
          .height('100%')
          .position({ x: this.alignGuideX, y: 0 })
      }
      if (this.alignGuideY >= 0) {
        Divider()
          .vertical(false)
          .strokeWidth(1)
          .color('#80A8D8EA')
          .width('100%')
          .position({ x: 0, y: this.alignGuideY })
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  SharePanel() {
    Column() {
      // 标题栏
      Row() {
        Text('分享 / 导入').fontSize(16).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Bold)
        Blank()
        Text('✕').fontSize(14).fontColor('#99FFFFFF')
          .width(28).height(28).textAlign(TextAlign.Center)
          .borderRadius(14).backgroundColor(OV_BG_TRACK)
          .onClick(() => {
            this.showSharePanel = false;
            this.showImportConfirm = false;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      if (this.showImportConfirm) {
        // ── 导入确认视图 ──
        Column({ space: 12 }) {
          Text(`配置: ${this.importPreviewName}`)
            .fontSize(14).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Bold)
          Text(`包含 ${this.importPreviewCount} 个按键`)
            .fontSize(13).fontColor(OV_TEXT_MEDIUM)

          Row({ space: 12 }) {
            Text('替换导入')
              .fontSize(13).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
              .padding({ left: 16, right: 16 }).height(36)
              .borderRadius(18).backgroundColor('#D06060')
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .onClick(() => { this.doImportReplace(); })
            Text('合并导入')
              .fontSize(13).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
              .padding({ left: 16, right: 16 }).height(36)
              .borderRadius(18).backgroundColor('#50C080')
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .onClick(() => { this.doImportMerge(); })
            Text('取消')
              .fontSize(13).fontColor(OV_TEXT_MEDIUM)
              .padding({ left: 16, right: 16 }).height(36)
              .borderRadius(18).backgroundColor(OV_BG_TRACK)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .onClick(() => { this.showImportConfirm = false; })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      } else {
        // ── 分享 + 导入主视图 ──
        Scroll() {
          Row({ space: 16 }) {
            // 左侧：二维码
            Column({ space: 8 }) {
              Text('当前配置二维码')
                .fontSize(12).fontColor(OV_TEXT_MEDIUM)
              if (this.qrLoading) {
                LoadingProgress()
                  .width(120).height(120)
                  .color(OV_ACCENT_BLUE)
              } else if (this.qrTooLarge) {
                Column({ space: 4 }) {
                  Text('⚠')
                    .fontSize(28)
                  Text('按键过多')
                    .fontSize(12).fontColor('#FFFFD700')
                  Text('超出二维码容量')
                    .fontSize(11).fontColor(OV_TEXT_DIM)
                  Text('请使用剪贴板分享')
                    .fontSize(11).fontColor(OV_TEXT_DIM)
                }
                .width(140).height(140)
                .justifyContent(FlexAlign.Center)
                .borderRadius(8).backgroundColor('#20FFFFFF')
                .border({ width: 1, color: '#30FFD700' })
              } else if (this.qrPixelMap) {
                Image(this.qrPixelMap)
                  .width(140).height(140)
                  .borderRadius(8)
                  .backgroundColor(Color.White)
                  .objectFit(ImageFit.Contain)
              } else {
                Column({ space: 4 }) {
                  Text('⚠')
                    .fontSize(28)
                  Text('二维码生成失败')
                    .fontSize(11).fontColor(OV_TEXT_DIM)
                  Text('请使用剪贴板分享')
                    .fontSize(11).fontColor(OV_TEXT_DIM)
                  if (this.qrError) {
                    Text(this.qrError)
                      .fontSize(9).fontColor(OV_TEXT_SUBTLE)
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .width(140).height(140)
                .justifyContent(FlexAlign.Center)
                .borderRadius(8).backgroundColor('#20FFFFFF')
                .border({ width: 1, color: '#20FFFFFF' })
              }
              // 操作按钮
              Row({ space: 8 }) {
                Text('复制')
                  .fontSize(12).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
                  .padding({ left: 10, right: 10 }).height(30)
                  .borderRadius(15).backgroundColor('#506080A0')
                  .border({ width: 1, color: '#306080A0' })
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                  .onClick(() => { this.copyToClipboard(); })
                Text('分享')
                  .fontSize(12).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
                  .padding({ left: 10, right: 10 }).height(30)
                  .borderRadius(15).backgroundColor('#5090B0')
                  .border({ width: 1, color: '#306090B0' })
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                  .onClick(() => { this.shareToFriend(); })
              }

              Text(`${this.keys.length} 个按键 · ${this.shareJson.length} 字符`)
                .fontSize(10).fontColor(OV_TEXT_DIM)
            }

            // 右侧：导入选项
            Column({ space: 10 }) {
              Text('导入配置')
                .fontSize(12).fontColor(OV_TEXT_MEDIUM)

              Text('扫码导入')
                .fontSize(13).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
                .width(130).height(36).textAlign(TextAlign.Center)
                .borderRadius(18).backgroundColor('#6098C0')
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                .onClick(() => { this.scanAndImport(); })

              Text('从剪贴板导入')
                .fontSize(13).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
                .width(130).height(36).textAlign(TextAlign.Center)
                .borderRadius(18).backgroundColor('#7060A0')
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                .onClick(() => { this.pasteFromClipboard(); })

              Divider().color('#20FFFFFF').width(100).margin({ top: 4, bottom: 4 })

              Text('扫描其他设备上的')
                .fontSize(10).fontColor(OV_TEXT_DIM)
              Text('配置二维码即可导入')
                .fontSize(10).fontColor(OV_TEXT_DIM)
            }
          }
          .padding({ left: 16, right: 16, top: 8, bottom: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .constraintSize({ maxHeight: '45%' })
    .backgroundColor('#E01A1A2E')
    .backdropBlur(50)
    .borderRadius({ topLeft: 16, topRight: 16 })
    .border({ width: { top: 1, left: 1, right: 1 }, color: '#20FFFFFF' })
    .onTouch((event: TouchEvent) => { event.stopPropagation(); })
    .transition(TransitionEffect.move(TransitionEdge.BOTTOM).animation({ duration: 200 }))
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 缩放手柄
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private static readonly RESIZE_HANDLE_SIZE = 20;
  private static readonly MIN_KEY_SIZE = 24;
  private static readonly MAX_KEY_SIZE = 400;

  @Builder
  ResizeHandle() {
    if (this.getSelectedKey()) {
      Stack() {
        Text('⤡')
          .fontSize(12)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .width('100%')
          .height('100%')
          .lineHeight(CustomKeyOverlay.RESIZE_HANDLE_SIZE)
      }
      .width(CustomKeyOverlay.RESIZE_HANDLE_SIZE)
      .height(CustomKeyOverlay.RESIZE_HANDLE_SIZE)
      .borderRadius(CustomKeyOverlay.RESIZE_HANDLE_SIZE / 2)
      .backgroundColor('#C0FF6040')
      .border({ width: 1, color: '#E0FFFFFF', style: BorderStyle.Solid })
      .shadow({ radius: 4, color: '#40000000', offsetY: 1 })
      .alignContent(Alignment.Center)
      .translate({ x: this.resizeDragDX, y: this.resizeDragDY })
      .position({
        x: this.getSelectedKey()!.xPercent * this.screenWidthVp
           + this.getSelectedKey()!.width / 2
           - CustomKeyOverlay.RESIZE_HANDLE_SIZE / 2,
        y: this.getSelectedKey()!.yPercent * this.screenHeightVp
           + this.getSelectedKey()!.height / 2
           - CustomKeyOverlay.RESIZE_HANDLE_SIZE / 2,
      })
      .hitTestBehavior(HitTestMode.Block)
      .onTouch((event: TouchEvent) => {
        event.stopPropagation();
        this.handleResizeTouch(event);
      })
    }
  }

  private handleResizeTouch(event: TouchEvent): void {
    const touch = event.touches[0];
    if (!touch) return;

    switch (event.type) {
      case TouchType.Down: {
        const sel = this.getSelectedKey();
        if (!sel) return;
        this.pushUndoState();
        this.resizeStartX = touch.windowX;
        this.resizeStartY = touch.windowY;
        this.resizeOrigWidth = sel.width;
        this.resizeOrigHeight = sel.height;
        this.resizing = true;
        this.resizeDragDX = 0;
        this.resizeDragDY = 0;
        break;
      }
      case TouchType.Move: {
        if (!this.resizing) return;
        const dx = touch.windowX - this.resizeStartX;
        const dy = touch.windowY - this.resizeStartY;
        this.resizeDragDX = dx;
        this.resizeDragDY = dy;
        // 实时预览：更新按键尺寸
        const minS = CustomKeyOverlay.MIN_KEY_SIZE;
        const maxS = CustomKeyOverlay.MAX_KEY_SIZE;
        const newW = Math.max(minS, Math.min(maxS, this.resizeOrigWidth + dx));
        const newH = Math.max(minS, Math.min(maxS, this.resizeOrigHeight + dy));
        this.applyResize(newW, newH);
        break;
      }
      case TouchType.Up:
      case TouchType.Cancel: {
        if (this.resizing) {
          this.resizing = false;
          this.resizeDragDX = 0;
          this.resizeDragDY = 0;
          CustomKeyStore.saveKeys(this.keys);
        }
        break;
      }
    }
  }

  /** 直接更新选中按键的宽高（不推 undo，缩放结束时由 touch up 保存） */
  private applyResize(newWidth: number, newHeight: number): void {
    const idx = this.keys.findIndex(k => k.id === this.selectedKeyId);
    if (idx === -1) return;
    const updated = cloneKeyDef(this.keys[idx]);
    if (updated.shape === 'circle') {
      // 圆形按键：保持等比
      const s = Math.max(newWidth, newHeight);
      updated.width = s;
      updated.height = s;
    } else {
      updated.width = newWidth;
      updated.height = newHeight;
    }
    const newKeys: CustomKeyDef[] = this.keys.slice();
    newKeys[idx] = updated;
    this.keys = newKeys;
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // Builders: 面板
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  @Builder
  AddKeyPanel() {
    Column() {
      // 标题栏
      Row() {
        Text('添加按键').fontSize(16).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Bold)
        Blank()
        Text('✕').fontSize(14).fontColor('#99FFFFFF')
          .width(28).height(28).textAlign(TextAlign.Center)
          .borderRadius(14).backgroundColor(OV_BG_TRACK)
          .onClick(() => { this.showAddPanel = false; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 6 })

      // 水平分类标签
      Scroll() {
        Row({ space: 6 }) {
          ForEach(KEY_PRESET_CATEGORIES, (category: KeyPresetCategory, index: number) => {
            Text(category.name)
              .fontSize(12)
              .fontColor(this.addPanelCategoryIdx === index ? OV_TEXT_WHITE : '#80FFFFFF')
              .fontWeight(this.addPanelCategoryIdx === index ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: 12, right: 12 })
              .height(30)
              .borderRadius(15)
              .backgroundColor(this.addPanelCategoryIdx === index ? '#50A8D8EA' : '#20FFFFFF')
              .border({
                width: 1,
                color: this.addPanelCategoryIdx === index ? '#60A8D8EA' : '#00000000',
              })
              .onClick(() => { this.addPanelCategoryIdx = index; })
          })
        }
        .padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(38)

      // 选中分类的按键网格
      Scroll() {
        Flex({ wrap: FlexWrap.Wrap,
          space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
          ForEach(this.getSelectedCategoryPresets(), (preset: KeyPreset) => {
            Text(preset.label)
              .fontSize(12).fontColor(OV_TEXT_BRIGHT).fontWeight(FontWeight.Bold)
              .constraintSize({ minWidth: 42 })
              .padding({ left: 6, right: 6 })
              .height(36).textAlign(TextAlign.Center)
              .borderRadius(8).backgroundColor(OV_BG_TRACK)
              .border({ width: 1, color: '#20FFFFFF' })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .onClick(() => { this.addKeyFromPreset(preset); })
          })
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('40%')
    .backgroundColor('#E01A1A2E')
    .backdropBlur(50)
    .borderRadius({ topLeft: 16, topRight: 16 })
    .border({ width: { top: 1, left: 1, right: 1 }, color: '#20FFFFFF' })
    .onTouch((event: TouchEvent) => { event.stopPropagation(); })
    .transition(TransitionEffect.move(TransitionEdge.BOTTOM).animation({ duration: 200 }))
  }

  @Builder
  PropertyPanel() {
    Column() {
      Row() {
        Text('按键属性').fontSize(16).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Bold)
        Blank()
        Text('✕').fontSize(14).fontColor('#99FFFFFF')
          .width(28).height(28).textAlign(TextAlign.Center)
          .borderRadius(14).backgroundColor(OV_BG_TRACK)
          .onClick(() => { this.showPropertyPanel = false; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 8 }) {
          // 标签编辑
          Row() {
            Text('标签').fontSize(12).fontColor(OV_TEXT_MEDIUM).width(36)
            TextInput({ text: this.getSelectedKey()?.label ?? '' })
              .layoutWeight(1).height(32).fontSize(OV_FONT_LG)
              .fontColor(OV_TEXT_WHITE).backgroundColor(OV_BG_CARD_LIGHTER)
              .borderRadius(8).padding({ left: 8, right: 8 })
              .maxLength(8)
              .onChange((value: string) => { this.updateSelectedKeyProp('label', value); })
          }
          .width('100%').padding({ left: 4, right: 4 })

          // 尺寸/样式 滑块 — 两列紧凑排列
          Row({ space: 12 }) {
            this.PropertySliderCompact('宽', 30, 200, this.getSelectedKey()?.width ?? 60, 'width')
            this.PropertySliderCompact('高', 30, 200, this.getSelectedKey()?.height ?? 60, 'height')
          }
          .width('100%').padding({ left: 4, right: 4 })

          Row({ space: 12 }) {
            this.PropertySliderCompact('透明', 10, 100, this.getSelectedKey()?.opacity ?? 80, 'opacity')
            this.PropertySliderCompact('字号', 8, 30, this.getSelectedKey()?.fontSize ?? 14, 'fontSize')
          }
          .width('100%').padding({ left: 4, right: 4 })

          Row({ space: 12 }) {
            this.PropertySliderCompact('线宽', 0, 6, this.getSelectedKey()?.borderWidth ?? 1, 'borderWidth')
          }
          .width('100%').padding({ left: 4, right: 4 })

          Row({ space: 12 }) {
            // 形状 + 模式 — 紧凑行内
            Row({ space: 6 }) {
              this.ShapeChip('方', 'rect')
              this.ShapeChip('圆', 'circle')
              Text('|').fontSize(10).fontColor('#30FFFFFF')
              this.BehaviorChip('点触', 'momentary')
              this.BehaviorChip('切换', 'toggle')
            }
            .justifyContent(FlexAlign.End)
          }
          .width('100%').padding({ left: 4, right: 4 })

          // 颜色行 — 底色 + 字色 并排
          Row({ space: 16 }) {
            Row() {
              Text('底色').fontSize(12).fontColor(OV_TEXT_MEDIUM).margin({ right: 6 })
              Row({ space: 5 }) {
                ForEach(BG_COLOR_PRESETS, (color: string) => {
                  Text('')
                    .width(20).height(20).borderRadius(10)
                    .backgroundColor(color)
                    .border({
                      width: this.getSelectedKey()?.bgColor === color ? 2 : 1,
                      color: this.getSelectedKey()?.bgColor === color ? '#FFFFD700' : '#30FFFFFF',
                    })
                    .onClick(() => { this.updateSelectedKeyProp('bgColor', color); })
                })
              }
            }

            Row() {
              Text('字色').fontSize(12).fontColor(OV_TEXT_MEDIUM).margin({ right: 6 })
              Row({ space: 5 }) {
                ForEach(TEXT_COLOR_PRESETS, (color: string) => {
                  Text('')
                    .width(20).height(20).borderRadius(10)
                    .backgroundColor(color)
                    .border({
                      width: this.getSelectedKey()?.textColor === color ? 2 : 1,
                      color: this.getSelectedKey()?.textColor === color ? '#FFFFD700' : '#30FFFFFF',
                    })
                    .onClick(() => { this.updateSelectedKeyProp('textColor', color); })
                })
              }
            }
          }
          .width('100%').padding({ left: 4, right: 4 })

          // 按压色
          Row() {
            Text('按压').fontSize(12).fontColor(OV_TEXT_MEDIUM).margin({ right: 6 })
            Row({ space: 5 }) {
              ForEach(PRESSED_COLOR_PRESETS, (color: string) => {
                Text('')
                  .width(20).height(20).borderRadius(10)
                  .backgroundColor(color)
                  .border({
                    width: this.getSelectedKey()?.pressedColor === color ? 2 : 1,
                    color: this.getSelectedKey()?.pressedColor === color ? '#FFFFD700' : '#30FFFFFF',
                  })
                  .onClick(() => { this.updateSelectedKeyProp('pressedColor', color); })
              })
            }
          }
          .width('100%').padding({ left: 4, right: 4 })

          // 振动反馈
          Row({ space: 6 }) {
            Text('振动').fontSize(12).fontColor(OV_TEXT_MEDIUM).width(36)
            ForEach(HAPTIC_OPTIONS, (opt: [string, string]) => {
              Text(opt[1])
                .fontSize(12)
                .fontColor((this.getSelectedKey()?.haptic ?? 'light') === opt[0] ? '#FF000000' : OV_TEXT_WHITE)
                .fontWeight(FontWeight.Medium)
                .padding({ left: 10, right: 10 }).height(28)
                .borderRadius(14)
                .backgroundColor((this.getSelectedKey()?.haptic ?? 'light') === opt[0] ? '#FFFFD700' : OV_BG_TRACK)
                .border({ width: 1, color: (this.getSelectedKey()?.haptic ?? 'light') === opt[0] ? '#FFFFD700' : '#20FFFFFF' })
                .onClick(() => { this.updateSelectedKeyProp('haptic', opt[0]); })
            })
          }
          .width('100%').padding({ left: 4, right: 4 })

          // 层级管理
          Row({ space: 8 }) {
            Text('层级').fontSize(12).fontColor(OV_TEXT_MEDIUM).width(36)
            Text(`${this.getSelectedKey()?.layer ?? 0}`)
              .fontSize(12).fontColor(OV_TEXT_WHITE).width(24).textAlign(TextAlign.Center)
            Text('↓ 下移')
              .fontSize(12).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
              .padding({ left: 8, right: 8 }).height(28)
              .borderRadius(14).backgroundColor(OV_BG_TRACK)
              .border({ width: 1, color: '#20FFFFFF' })
              .onClick(() => { this.updateSelectedKeyProp('layer', (this.getSelectedKey()?.layer ?? 0) - 1); })
            Text('↑ 上移')
              .fontSize(12).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
              .padding({ left: 8, right: 8 }).height(28)
              .borderRadius(14).backgroundColor(OV_BG_TRACK)
              .border({ width: 1, color: '#20FFFFFF' })
              .onClick(() => { this.updateSelectedKeyProp('layer', (this.getSelectedKey()?.layer ?? 0) + 1); })
          }
          .width('100%').padding({ left: 4, right: 4 })
        }
        .padding({ left: 16, right: 16, bottom: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('45%')
    .backgroundColor('#E01A1A2E')
    .backdropBlur(50)
    .borderRadius({ topLeft: 16, topRight: 16 })
    .border({ width: { top: 1, left: 1, right: 1 }, color: '#20FFFFFF' })
    .onTouch((event: TouchEvent) => { event.stopPropagation(); })
    .transition(TransitionEffect.move(TransitionEdge.BOTTOM).animation({ duration: 200 }))
  }

  @Builder
  PropertySliderCompact(label: string, min: number, max: number, value: number, propName: string) {
    Row() {
      Text(label).fontSize(11).fontColor(OV_TEXT_MEDIUM).width(28)
      Slider({ value: value, min: min, max: max, step: 1, style: SliderStyle.OutSet })
        .layoutWeight(1)
        .blockColor(OV_ACCENT_BLUE).blockSize({ width: 12, height: 12 })
        .trackColor(OV_BG_TRACK).selectedColor(OV_ACCENT_BLUE).trackThickness(2)
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
        .onChange((v: number) => { this.updateSelectedKeyProp(propName, Math.round(v)); })
      Text(Math.round(value).toString())
        .fontSize(OV_FONT_SM).fontColor(OV_TEXT_DIM).width(26).textAlign(TextAlign.End)
    }
    .layoutWeight(1)
  }

  @Builder
  PropertySlider(label: string, min: number, max: number, value: number, propName: string) {
    Row() {
      Text(label).fontSize(12).fontColor(OV_TEXT_MEDIUM).width(50)
      Slider({ value: value, min: min, max: max, step: 1, style: SliderStyle.OutSet })
        .layoutWeight(1)
        .blockColor(OV_ACCENT_BLUE).blockSize({ width: 14, height: 14 })
        .trackColor(OV_BG_TRACK).selectedColor(OV_ACCENT_BLUE).trackThickness(3)
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
        .onChange((v: number) => { this.updateSelectedKeyProp(propName, Math.round(v)); })
      Text(Math.round(value).toString())
        .fontSize(OV_FONT_MD).fontColor(OV_TEXT_DIM).width(30).textAlign(TextAlign.End)
    }
    .width('100%')
  }

  @Builder
  BehaviorChip(label: string, behavior: KeyBehavior) {
    Text(label)
      .fontSize(OV_FONT_MD)
      .fontColor(this.getSelectedKey()?.behavior === behavior ? OV_TEXT_WHITE : '#80FFFFFF')
      .padding({ left: 10, right: 10 }).height(26).borderRadius(13)
      .backgroundColor(this.getSelectedKey()?.behavior === behavior ? '#50A8D8EA' : '#20FFFFFF')
      .border({
        width: 1,
        color: this.getSelectedKey()?.behavior === behavior ? '#80A8D8EA' : '#00000000',
      })
      .onClick(() => { this.updateSelectedKeyProp('behavior', behavior); })
  }

  @Builder
  ShapeChip(label: string, shape: string) {
    Text(label)
      .fontSize(OV_FONT_MD)
      .fontColor(this.getSelectedKey()?.shape === shape ? OV_TEXT_WHITE : '#80FFFFFF')
      .padding({ left: 10, right: 10 }).height(26).borderRadius(13)
      .backgroundColor(this.getSelectedKey()?.shape === shape ? '#50A8D8EA' : '#20FFFFFF')
      .border({
        width: 1,
        color: this.getSelectedKey()?.shape === shape ? '#80A8D8EA' : '#00000000',
      })
      .onClick(() => { this.updateSelectedKeyProp('shape', shape); })
  }
}
