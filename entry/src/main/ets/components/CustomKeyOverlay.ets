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

import { componentSnapshot, display, LengthMetrics, promptAction, window } from '@kit.ArkUI';
import {
  CustomKeyDef,
  KeyAction,
  KeyBehavior,
  KeyShape,
  AnalogStickAction,
  DPadAction,
  WheelPadAction,
  WheelPadSegment,
  DigitalStickAction,
  KeyboardAction,
  createDefaultKeyDef,
  cloneKeyDef,
  generateKeyId,
  getActionDisplayName,
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
import {
  DigitalDirState, SnapResult,
  EDIT_BORDER_COLOR, SELECT_BORDER_COLOR, EDIT_TOOLBAR_HEIGHT, DRAG_THRESHOLD,
  BG_COLOR_PRESETS, TEXT_COLOR_PRESETS, PRESSED_COLOR_PRESETS, HAPTIC_OPTIONS,
  doKeyHaptic,
} from './CustomKeyConstants';
import {
  ColorTheme, COLOR_THEMES, RGBPixel,
  parseHexRGB, toHexARGB, generateThemeFromAccent,
  kMeansPlusPlus, pickAccentFromClusters,
} from '../service/CustomKeyTheme';
import { CustomKeyBtn } from './CustomKeyBtn';

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
  /** 配置版本号（外部递增触发重新加载按键） */
  @Prop @Watch('onProfileVersionChanged') profileVersion: number = 0;
  @State selectedKeyId: string = '';
  @State showAddPanel: boolean = false;
  @State showPropertyPanel: boolean = false;
  @State addPanelCategoryIdx: number = 0;
  /** 轮盘分区编辑：正在选择按键的分区索引，-1 表示未在选择 */
  @State private segmentPickerIndex: number = -1;
  /** 分区按键选择器的分类索引 */
  @State private segmentPickerCategoryIdx: number = 0;

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

  /** 删除确认对话框 */
  /** 配色主题面板 */
  @State private showThemePanel: boolean = false;
  /** 配置档案面板 */
  @State private showProfilePanel: boolean = false;
  @State private profileNames: string[] = [];
  @State private activeProfileName: string = '';
  /** 配置切换回调（通知 StreamPage 刷新） */
  onProfileSwitched: () => void = () => {};
  @State private themeExtracting: boolean = false;
  @State private extractedAccentColor: string = '';
  /** 截屏取色时临时隐藏覆盖层，避免 UI 元素污染采样 */
  @State private hidingForCapture: boolean = false;
  /** 取色动画 */
  @State private captureAnimColor: string = '';
  @State private captureAnimActive: boolean = false;
  @State private scanLineY: number = 0;        // 扫描线 Y 位置百分比 0~100
  @State private scanTintOpacity: number = 0;  // 扫过区域染色透明度
  @State private scanLabelOpacity: number = 0; // 颜色标签透明度
  @State private scanFlashOpacity: number = 0; // 完成时闪光效果

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
    this.activeProfileName = await CustomKeyStore.getActiveProfileName();

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

  /** 外部配置版本变化时重新加载按键 */
  async onProfileVersionChanged(): Promise<void> {
    this.keys = await CustomKeyStore.getKeys();
    this.activeProfileName = await CustomKeyStore.getActiveProfileName();
    this.selectedKeyId = '';
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

        // 编辑模式空状态引导
        if (this.editMode && this.keys.length === 0) {
          this.EmptyStateGuide()
        }

        // 配色主题面板
        if (this.showThemePanel) {
          this.ThemePanel()
        }

        // 添加按键面板
        if (this.showAddPanel) {
          this.AddKeyPanel()
        }

        // 属性编辑面板
        if (this.showPropertyPanel && this.selectedKeyId) {
          this.PropertyPanel()
        }

        // 配置档案面板
        if (this.showProfilePanel) {
          this.ProfilePanel()
        }

        // 二维码分享面板
        if (this.showSharePanel) {
          this.SharePanel()
        }

        // 科幻扫描线取色动画
        if (this.captureAnimActive) {
          Stack() {
            // 扫描过的区域渐变染色
            Column()
              .width('100%')
              .height(this.scanLineY + '%')
              .linearGradient({
                angle: 180,
                colors: [[this.captureAnimColor, 0.0], ['#00000000', 1.0]]
              })
              .opacity(this.scanTintOpacity)

            // 扫描线（发光横条）
            Column()
              .width('100%')
              .height(3)
              .backgroundColor('#FFFFFF')
              .shadow({
                radius: 20,
                color: this.captureAnimColor,
                offsetX: 0,
                offsetY: 0
              })
              .opacity(this.scanLineY > 0 && this.scanLineY < 100 ? 0.9 : 0)
              .position({ x: 0, y: this.scanLineY + '%' })

            // 扫描线两侧的装饰短线
            Row() {
              Column().width(40).height(1).backgroundColor(this.captureAnimColor).opacity(0.6)
              Blank()
              Column().width(40).height(1).backgroundColor(this.captureAnimColor).opacity(0.6)
            }
            .width('100%')
            .padding({ left: 12, right: 12 })
            .opacity(this.scanLineY > 0 && this.scanLineY < 100 ? 1 : 0)
            .position({ x: 0, y: this.scanLineY + '%' })

            // 完成时全屏闪烁
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor(this.captureAnimColor)
              .opacity(this.scanFlashOpacity)

            // 颜色标签
            Column({ space: 4 }) {
              Text('SCAN COMPLETE')
                .fontSize(11)
                .fontColor(this.captureAnimColor)
                .fontWeight(FontWeight.Bold)
                .letterSpacing(3)
              Row({ space: 6 }) {
                Column()
                  .width(12)
                  .height(12)
                  .borderRadius(6)
                  .backgroundColor(this.captureAnimColor)
                Text(this.captureAnimColor)
                  .fontSize(13)
                  .fontColor('#DDFFFFFF')
                  .fontFamily('monospace')
              }
            }
            .opacity(this.scanLabelOpacity)
            .position({ x: '50%', y: '50%' })
            .translate({ x: '-50%', y: '-50%' })
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.BottomStart)
      .hitTestBehavior(HitTestMode.Transparent)
      // hitTestReady: 微小 opacity 变化触发父层重渲染，刷新命中测试树
      .opacity(this.hidingForCapture ? 0 : (this.hitTestReady > 0 ? 1 : 0.99))

      // 编辑模式工具栏（面板打开时隐藏，避免遮挡面板）
      if (this.editMode && !this.showAddPanel && !this.showPropertyPanel && !this.showSharePanel && !this.showThemePanel && !this.showProfilePanel) {
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
          .onClick(() => {
            if (this.selectedKeyId) {
              this.deleteSelectedKey();
            }
          })

          Row({ space: 4 }) {
            Text('⧉')
              .fontSize(16).fontColor(Color.White)
            Text('复制')
              .fontSize(OV_FONT_LG).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
          }
          .height(32).padding({ left: 10, right: 12 })
          .borderRadius(16).backgroundColor('#8070A0')
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { if (this.selectedKeyId) { this.cloneSelectedKey(); } })

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
            Text('🎨')
              .fontSize(14)
            Text('配色')
              .fontSize(OV_FONT_LG).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
          }
          .height(32).padding({ left: 10, right: 12 })
          .borderRadius(16).backgroundColor('#C07050')
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { this.showThemePanel = true; })

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

          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.square_stack_3d_up'))
              .fontSize(16).fontColor([Color.White])
            Text('配置')
              .fontSize(OV_FONT_LG).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
          }
          .height(32).padding({ left: 10, right: 12 })
          .borderRadius(16).backgroundColor('#6080A0')
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { this.openProfilePanel(); })

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

  /** 克隆选中按键：复制全部属性，位置略微偏移避免完全重叠 */
  private async cloneSelectedKey(): Promise<void> {
    const src = this.getSelectedKey();
    if (!src) return;
    this.pushUndoState();
    const cloned = cloneKeyDef(src);
    cloned.id = generateKeyId();
    // 偏移 3% 避免完全重叠
    cloned.xPercent = Math.min(1.0, cloned.xPercent + 0.03);
    cloned.yPercent = Math.min(1.0, cloned.yPercent + 0.03);
    const newArr: CustomKeyDef[] = this.keys.slice();
    newArr.push(cloned);
    this.keys = newArr;
    await CustomKeyStore.saveKeys(this.keys);
    this.selectedKeyId = cloned.id;
    promptAction.showToast({ message: '已复制按键', duration: 1200 });
  }

  /** 微调选中按键位置，单位 vp */
  private nudgeSelectedKey(dx: number, dy: number): void {
    const idx = this.keys.findIndex(k => k.id === this.selectedKeyId);
    if (idx === -1 || this.screenWidthVp <= 0) return;
    this.pushUndoState();
    const updated = cloneKeyDef(this.keys[idx]);
    updated.xPercent = Math.max(0, Math.min(1, updated.xPercent + dx / this.screenWidthVp));
    updated.yPercent = Math.max(0, Math.min(1, updated.yPercent + dy / this.screenHeightVp));
    const newKeys: CustomKeyDef[] = this.keys.slice();
    newKeys[idx] = updated;
    this.keys = newKeys;
    CustomKeyStore.saveKeys(this.keys);
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
    this.showThemePanel = false;
    this.showProfilePanel = false;
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
    this.showThemePanel = false;
    this.showProfilePanel = false;
    await CustomKeyStore.saveKeys(this.keys);
    this.onEditModeChanged(false);
  }

  async reloadKeys(): Promise<void> {
    this.keys = await CustomKeyStore.getKeys();
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 智能配色
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /** 将配色主题应用到所有按键 */
  private async applyThemeToAllKeys(theme: ColorTheme): Promise<void> {
    if (this.keys.length === 0) return;
    this.pushUndoState();
    const newKeys: CustomKeyDef[] = this.keys.map((k: CustomKeyDef): CustomKeyDef => {
      const updated = cloneKeyDef(k);
      updated.bgColor = theme.bgColor;
      updated.textColor = theme.textColor;
      updated.pressedColor = theme.pressedColor;
      updated.normalColor = theme.normalColor;
      return updated;
    });
    this.keys = newKeys;
    await CustomKeyStore.saveKeys(this.keys);
    this.showThemePanel = false;
    promptAction.showToast({ message: `已应用「${theme.name}」配色`, duration: 1500 });
  }

  /**
   * 从当前屏幕截图提取主色调，生成智能配色方案
   * 使用 window.snapshot() 获取窗口截图，然后采样像素提取主色
   */
  private async extractColorsFromScreen(): Promise<void> {
    this.themeExtracting = true;
    this.extractedAccentColor = '';

    // ── 步骤1：隐藏覆盖层 UI，等一帧让渲染生效 ──
    this.showThemePanel = false;
    this.hidingForCapture = true;
    await new Promise<void>((resolve) => setTimeout(resolve, 150));

    try {
      const context = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(context);
      const pixelMap = await win.snapshot();

      // ── 步骤2：截图完成后立刻恢复 UI 显示 ──
      this.hidingForCapture = false;
      this.showThemePanel = true;

      const info = await pixelMap.getImageInfo();
      const width = info.size.width;
      const height = info.size.height;

      // 采样区域：聚焦中心 60% 区域
      const startX = Math.floor(width * 0.2);
      const endX = Math.floor(width * 0.8);
      const startY = Math.floor(height * 0.15);
      const endY = Math.floor(height * 0.75);
      const sampleCount = 300;

      // 读取整图像素
      const bufferSize = width * height * 4; // RGBA
      const buffer = new ArrayBuffer(bufferSize);
      await pixelMap.readPixelsToBuffer(buffer);
      const view = new Uint8Array(buffer);
      pixelMap.release();

      // 随机采样像素，过滤接近纯黑的点
      const samples: RGBPixel[] = [];
      for (let i = 0; i < sampleCount; i++) {
        const sx = startX + Math.floor(Math.random() * (endX - startX));
        const sy = startY + Math.floor(Math.random() * (endY - startY));
        const offset = (sy * width + sx) * 4;
        if (offset + 3 < view.length) {
          const r = view[offset];
          const g = view[offset + 1];
          const b = view[offset + 2];
          if (r + g + b > 30) {
            const pixel: RGBPixel = { r: r, g: g, b: b };
            samples.push(pixel);
          }
        }
      }

      if (samples.length < 10) {
        promptAction.showToast({ message: '画面过暗，建议手动选择主题', duration: 2000 });
        this.themeExtracting = false;
        return;
      }

      // ── 步骤3：K-means++ 聚类提取主色调 ──
      const clusters = kMeansPlusPlus(samples, 5);
      const accent = pickAccentFromClusters(clusters, samples.length);
      const accentHex = toHexARGB(255, accent.r, accent.g, accent.b);

      // ── 步骤4：科幻扫描线动画 ──
      this.captureAnimColor = accentHex;
      this.scanLineY = 0;
      this.scanTintOpacity = 0;
      this.scanLabelOpacity = 0;
      this.scanFlashOpacity = 0;
      this.captureAnimActive = true;

      // 阶段1：扫描线从上往下扫（0→600ms）
      animateTo({ duration: 600, curve: Curve.Linear }, () => {
        this.scanLineY = 100;
      });
      // 扫过区域同步染色
      animateTo({ duration: 600, curve: Curve.EaseIn }, () => {
        this.scanTintOpacity = 0.3;
      });

      // 动画播放期间同时应用主题
      this.extractedAccentColor = accentHex;
      const theme = generateThemeFromAccent(accent.r, accent.g, accent.b);
      await this.applyThemeToAllKeys(theme);

      // 阶段2：扫描完成 → 全屏闪烁 + 标签淡入（600ms后）
      setTimeout(() => {
        // 闪光
        animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
          this.scanFlashOpacity = 0.25;
        });
        setTimeout(() => {
          animateTo({ duration: 300, curve: Curve.EaseIn }, () => {
            this.scanFlashOpacity = 0;
          });
        }, 150);
        // 标签淡入
        animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
          this.scanLabelOpacity = 1;
        });
      }, 600);

      // 阶段3：整体淡出（1200ms后开始）
      setTimeout(() => {
        animateTo({ duration: 400, curve: Curve.EaseIn }, () => {
          this.scanTintOpacity = 0;
          this.scanLabelOpacity = 0;
        });
        setTimeout(() => { this.captureAnimActive = false; }, 450);
      }, 1200);
    } catch (e) {
      this.hidingForCapture = false;
      this.showThemePanel = true;
      console.error('[CustomKeyOverlay] 屏幕取色失败:', JSON.stringify(e));
      promptAction.showToast({ message: '屏幕取色失败，请手动选择主题', duration: 2000 });
    }
    this.themeExtracting = false;
  }

  private getSelectedCategoryPresets(): KeyPreset[] {
    if (this.addPanelCategoryIdx >= 0 && this.addPanelCategoryIdx < KEY_PRESET_CATEGORIES.length) {
      return KEY_PRESET_CATEGORIES[this.addPanelCategoryIdx].presets;
    }
    return [];
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 配置档案切换
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /** 打开配置档案面板 */
  private async openProfilePanel(): Promise<void> {
    this.profileNames = await CustomKeyStore.getProfileNames();
    this.activeProfileName = await CustomKeyStore.getActiveProfileName();
    this.showProfilePanel = true;
  }

  /** 切换到指定配置 */
  private async switchToProfile(name: string): Promise<void> {
    if (name === this.activeProfileName) return;
    // 先保存当前配置
    await CustomKeyStore.saveKeys(this.keys);
    // 切换
    const profile = await CustomKeyStore.switchProfile(name);
    if (profile) {
      this.activeProfileName = name;
      this.keys = profile.keys;
      this.selectedKeyId = '';
      this.undoStack = [];
      this.redoStack = [];
      this.canUndo = false;
      this.canRedo = false;
      this.onProfileSwitched();
      promptAction.showToast({ message: `已切换到: ${name}`, duration: 1500 });
    }
  }

  /** 新建空配置 */
  private async createNewProfile(): Promise<void> {
    // 生成不重复的名称
    let idx = this.profileNames.length + 1;
    let name = `配置 ${idx}`;
    while (this.profileNames.indexOf(name) >= 0) {
      idx++;
      name = `配置 ${idx}`;
    }
    await CustomKeyStore.saveKeys(this.keys);
    const profile = await CustomKeyStore.createProfile(name);
    if (profile) {
      this.profileNames = await CustomKeyStore.getProfileNames();
      this.activeProfileName = name;
      this.keys = profile.keys;
      this.selectedKeyId = '';
      this.undoStack = [];
      this.redoStack = [];
      this.canUndo = false;
      this.canRedo = false;
      this.onProfileSwitched();
      promptAction.showToast({ message: `已创建: ${name}`, duration: 1500 });
    }
  }

  /** 复制当前配置 */
  private async duplicateCurrentProfile(): Promise<void> {
    let idx = 1;
    let name = `${this.activeProfileName} (复制)`;
    while (this.profileNames.indexOf(name) >= 0) {
      idx++;
      name = `${this.activeProfileName} (复制 ${idx})`;
    }
    await CustomKeyStore.saveKeys(this.keys);
    const profile = await CustomKeyStore.duplicateProfile(name);
    if (profile) {
      this.profileNames = await CustomKeyStore.getProfileNames();
      this.activeProfileName = name;
      this.keys = profile.keys;
      this.selectedKeyId = '';
      this.undoStack = [];
      this.redoStack = [];
      this.canUndo = false;
      this.canRedo = false;
      this.onProfileSwitched();
      promptAction.showToast({ message: `已复制为: ${name}`, duration: 1500 });
    }
  }

  /** 删除指定配置 */
  private async deleteProfileByName(name: string): Promise<void> {
    if (this.profileNames.length <= 1) {
      promptAction.showToast({ message: '至少保留一个配置', duration: 1500 });
      return;
    }
    const ok = await CustomKeyStore.deleteProfile(name);
    if (ok) {
      this.profileNames = await CustomKeyStore.getProfileNames();
      this.activeProfileName = await CustomKeyStore.getActiveProfileName();
      this.keys = await CustomKeyStore.getKeys();
      this.selectedKeyId = '';
      this.undoStack = [];
      this.redoStack = [];
      this.canUndo = false;
      this.canRedo = false;
      this.onProfileSwitched();
      promptAction.showToast({ message: `已删除: ${name}`, duration: 1500 });
    }
  }

  /** 循环切换到下一个配置（SpecialAction 使用） */
  async cycleNextProfile(): Promise<void> {
    const names = await CustomKeyStore.getProfileNames();
    if (names.length <= 1) {
      promptAction.showToast({ message: '仅有一个配置', duration: 1500 });
      return;
    }
    const currentName = await CustomKeyStore.getActiveProfileName();
    const currentIdx = names.indexOf(currentName);
    const nextIdx = (currentIdx + 1) % names.length;
    await this.switchToProfile(names[nextIdx]);
  }

  @Builder
  ProfilePanel() {
    Column() {
      // 遮罩层
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#40000000')
        .onClick(() => { this.showProfilePanel = false; })

      // 底部面板
      Column({ space: 12 }) {
        // 标题行
        Row() {
          Text('配置档案')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(OV_TEXT_BRIGHT)
          Blank()
          Text('✕')
            .fontSize(18)
            .fontColor(OV_TEXT_DIM)
            .onClick(() => { this.showProfilePanel = false; })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 4 })

        // 配置列表 — 水平胶囊
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.profileNames, (name: string) => {
              Row() {
                Text(name)
                  .fontSize(OV_FONT_MD)
                  .fontWeight(name === this.activeProfileName ? FontWeight.Bold : FontWeight.Medium)
                  .fontColor(name === this.activeProfileName ? OV_TEXT_WHITE : OV_TEXT_MEDIUM)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .height(36)
              .padding({ left: 16, right: 16 })
              .borderRadius(18)
              .backgroundColor(name === this.activeProfileName ? OV_ACCENT_BLUE : '#20FFFFFF')
              .border({ width: 1, color: name === this.activeProfileName ? OV_BLUE_50 : '#15FFFFFF' })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
              .onClick(() => { this.switchToProfile(name); })
              .gesture(
                LongPressGesture({ repeat: false, duration: 600 })
                  .onAction(() => {
                    if (this.profileNames.length > 1 && name !== this.activeProfileName) {
                      this.deleteProfileByName(name);
                    }
                  })
              )
            }, (name: string) => name)
          }
          .padding({ left: 20, right: 20 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')

        // 操作按钮行
        Row({ space: 10 }) {
          Row({ space: 4 }) {
            Text('+')
              .fontSize(16).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Bold)
            Text('新建')
              .fontSize(OV_FONT_MD).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
          }
          .height(32).padding({ left: 12, right: 14 })
          .borderRadius(16).backgroundColor('#50C080')
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { this.createNewProfile(); })

          Row({ space: 4 }) {
            Text('⧉')
              .fontSize(14).fontColor(OV_TEXT_WHITE)
            Text('复制当前')
              .fontSize(OV_FONT_MD).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
          }
          .height(32).padding({ left: 12, right: 14 })
          .borderRadius(16).backgroundColor('#8070A0')
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { this.duplicateCurrentProfile(); })
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 16 })

        // 提示
        Text('长按非活跃配置可删除')
          .fontSize(OV_FONT_SM)
          .fontColor(OV_TEXT_FAINT)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ bottom: 12 })
      }
      .width('100%')
      .backgroundColor('#E6191925')
      .backdropBlur(40)
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 1 }, color: '#20FFFFFF' })
    }
    .width('100%')
    .height('100%')
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
  EmptyStateGuide() {
    Column({ space: 12 }) {
      Text('🎮')
        .fontSize(36)
      Text('还没有自定义按键')
        .fontSize(15).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
      Text('点击下方「添加」创建你的第一个按键')
        .fontSize(12).fontColor(OV_TEXT_DIM)
      Text('添加按键')
        .fontSize(14).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
        .padding({ left: 20, right: 20 }).height(36)
        .borderRadius(18).backgroundColor('#50C080')
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => { this.showAddPanel = true; })
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
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
  ThemePanel() {
    Column() {
      // 标题栏
      Row() {
        Text('🎨 智能配色').fontSize(16).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Bold)
        Blank()
        Text('✕').fontSize(14).fontColor('#99FFFFFF')
          .width(28).height(28).textAlign(TextAlign.Center)
          .borderRadius(14).backgroundColor(OV_BG_TRACK)
          .onClick(() => { this.showThemePanel = false; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // ── 从画面取色 ──
          Column({ space: 8 }) {
            Text('从当前画面取色')
              .fontSize(13).fontColor(OV_TEXT_MEDIUM)
            Text('截取屏幕画面，自动提取主色调应用到所有按键')
              .fontSize(11).fontColor(OV_TEXT_DIM)
            Row({ space: 12 }) {
              if (this.themeExtracting) {
                Row({ space: 8 }) {
                  LoadingProgress()
                    .width(16).height(16).color(OV_ACCENT_BLUE)
                  Text('正在分析画面...')
                    .fontSize(12).fontColor(OV_TEXT_MEDIUM)
                }
              } else {
                Text('截屏取色')
                  .fontSize(13).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
                  .padding({ left: 16, right: 16 }).height(34)
                  .borderRadius(17).backgroundColor('#C07050')
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                  .onClick(() => { this.extractColorsFromScreen(); })
              }
              if (this.extractedAccentColor) {
                Row({ space: 6 }) {
                  Text('').width(20).height(20).borderRadius(10)
                    .backgroundColor(this.extractedAccentColor)
                    .border({ width: 1, color: '#40FFFFFF' })
                  Text('上次取色')
                    .fontSize(11).fontColor(OV_TEXT_DIM)
                }
              }
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          Divider().color('#20FFFFFF').width('90%')

          // ── 预设主题 ──
          Column({ space: 8 }) {
            Text('预设主题')
              .fontSize(13).fontColor(OV_TEXT_MEDIUM)
              .padding({ left: 16 })

            Flex({ wrap: FlexWrap.Wrap,
              space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
              ForEach(COLOR_THEMES, (theme: ColorTheme) => {
                Column({ space: 4 }) {
                  // 预览色卡：模拟按键外观
                  Stack() {
                    Text('A')
                      .fontSize(13).fontColor(theme.textColor).fontWeight(FontWeight.Bold)
                      .textAlign(TextAlign.Center)
                  }
                  .width(40).height(40)
                  .borderRadius(8)
                  .backgroundColor(theme.bgColor)
                  .border({ width: 1, color: theme.normalColor })
                  .alignContent(Alignment.Center)

                  Text(theme.name)
                    .fontSize(10).fontColor(OV_TEXT_DIM)
                }
                .alignItems(HorizontalAlign.Center)
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                .onClick(() => { this.applyThemeToAllKeys(theme); })
              })
            }
            .padding({ left: 16, right: 16 })
          }
          .width('100%')

          Divider().color('#20FFFFFF').width('90%')

          // ── 提示 ──
          Text('提示：配色会应用到所有按键，可用撤销恢复')
            .fontSize(11).fontColor(OV_TEXT_DIM)
            .padding({ left: 16, right: 16 })

          // 间距
          Row().height(8)
        }
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
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
            this.PropertySliderCompact('圆角', 0, 60, this.getSelectedKey()?.borderRadius ?? 12, 'borderRadius')
          }
          .width('100%').padding({ left: 4, right: 4 })

          // 位置微调
          Row({ space: 8 }) {
            Text('微调').fontSize(11).fontColor(OV_TEXT_MEDIUM).width(28)
            Text('←')
              .fontSize(14).fontColor(OV_TEXT_WHITE)
              .width(28).height(28).textAlign(TextAlign.Center)
              .borderRadius(6).backgroundColor(OV_BG_TRACK)
              .border({ width: 1, color: '#20FFFFFF' })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .onClick(() => { this.nudgeSelectedKey(-2, 0); })
            Text('→')
              .fontSize(14).fontColor(OV_TEXT_WHITE)
              .width(28).height(28).textAlign(TextAlign.Center)
              .borderRadius(6).backgroundColor(OV_BG_TRACK)
              .border({ width: 1, color: '#20FFFFFF' })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .onClick(() => { this.nudgeSelectedKey(2, 0); })
            Text('↑')
              .fontSize(14).fontColor(OV_TEXT_WHITE)
              .width(28).height(28).textAlign(TextAlign.Center)
              .borderRadius(6).backgroundColor(OV_BG_TRACK)
              .border({ width: 1, color: '#20FFFFFF' })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .onClick(() => { this.nudgeSelectedKey(0, -2); })
            Text('↓')
              .fontSize(14).fontColor(OV_TEXT_WHITE)
              .width(28).height(28).textAlign(TextAlign.Center)
              .borderRadius(6).backgroundColor(OV_BG_TRACK)
              .border({ width: 1, color: '#20FFFFFF' })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .onClick(() => { this.nudgeSelectedKey(0, 2); })
            Text(`${((this.getSelectedKey()?.xPercent ?? 0) * 100).toFixed(0)}%, ${((this.getSelectedKey()?.yPercent ?? 0) * 100).toFixed(0)}%`)
              .fontSize(10).fontColor(OV_TEXT_DIM)
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

          // 轮盘分区编辑器（仅 wheelPad 类型显示）
          if (this.getSelectedKey()?.action?.type === 'wheelPad') {
            Column({ space: 6 }) {
              Row() {
                Text('轮盘分区').fontSize(12).fontColor(OV_TEXT_BRIGHT).fontWeight(FontWeight.Medium)
                Blank()
                Text('+')
                  .fontSize(14).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Bold)
                  .width(24).height(24).textAlign(TextAlign.Center)
                  .borderRadius(12).backgroundColor('#50C080')
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                  .onClick(() => { this.addWheelPadSegment(); })
              }
              .width('100%')

              ForEach(this.getWheelPadSegments(), (seg: WheelPadSegment, index?: number) => {
                Column({ space: 4 }) {
                  Row({ space: 6 }) {
                    Text(`${(index ?? 0) + 1}`)
                      .fontSize(10).fontColor(OV_TEXT_DIM)
                      .width(16).textAlign(TextAlign.Center)
                    TextInput({ text: seg.label })
                      .width(50).height(28).fontSize(11)
                      .fontColor(OV_TEXT_WHITE).backgroundColor(OV_BG_CARD_LIGHTER)
                      .borderRadius(6).padding({ left: 6, right: 6 })
                      .maxLength(6)
                      .onChange((value: string) => { this.updateSegmentLabel(index ?? 0, value); })
                    Text(getActionDisplayName(seg.action))
                      .fontSize(11).fontColor(OV_ACCENT_BLUE)
                      .layoutWeight(1).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text('改')
                      .fontSize(11).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
                      .padding({ left: 8, right: 8 }).height(24)
                      .borderRadius(12).backgroundColor(OV_BG_TRACK)
                      .border({ width: 1, color: '#20FFFFFF' })
                      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                      .onClick(() => {
                        this.segmentPickerIndex = (this.segmentPickerIndex === (index ?? 0)) ? -1 : (index ?? 0);
                        this.segmentPickerCategoryIdx = 0;
                      })
                    if (this.getWheelPadSegments().length > 2) {
                      Text('✕')
                        .fontSize(11).fontColor('#FF8080')
                        .width(22).height(24).textAlign(TextAlign.Center)
                        .borderRadius(12).backgroundColor('#30FF6060')
                        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                        .onClick(() => { this.removeWheelPadSegment(index ?? 0); })
                    }
                  }
                  .width('100%')

                  // 按键选择器（展开时显示）
                  if (this.segmentPickerIndex === (index ?? 0)) {
                    this.SegmentActionPicker(index ?? 0)
                  }
                }
              }, (_seg: WheelPadSegment, index?: number) => `seg_${index}_${this.segmentPickerIndex}`)
            }
            .width('100%').padding({ left: 4, right: 4 })
            .backgroundColor('#10FFFFFF')
            .borderRadius(8)
            .padding(8)
          }
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

  // ── 轮盘分区编辑 ──

  /** 获取选中按键的轮盘分区（安全访问） */
  private getWheelPadSegments(): WheelPadSegment[] {
    const key = this.getSelectedKey();
    if (key && key.action.type === 'wheelPad') {
      return (key.action as WheelPadAction).segments;
    }
    return [];
  }

  /** 更新分区标签 */
  private updateSegmentLabel(segIndex: number, label: string): void {
    const key = this.getSelectedKey();
    if (!key || key.action.type !== 'wheelPad') return;
    this.pushUndoState();
    const segments = (key.action as WheelPadAction).segments;
    if (segIndex >= 0 && segIndex < segments.length) {
      segments[segIndex].label = label;
    }
    this.forceRefreshSelectedKey();
  }

  /** 更新分区绑定的按键动作 */
  private updateSegmentAction(segIndex: number, action: KeyAction): void {
    const key = this.getSelectedKey();
    if (!key || key.action.type !== 'wheelPad') return;
    this.pushUndoState();
    const segments = (key.action as WheelPadAction).segments;
    if (segIndex >= 0 && segIndex < segments.length) {
      segments[segIndex].action = action;
    }
    this.segmentPickerIndex = -1;
    this.forceRefreshSelectedKey();
  }

  /** 添加新分区 */
  private addWheelPadSegment(): void {
    const key = this.getSelectedKey();
    if (!key || key.action.type !== 'wheelPad') return;
    this.pushUndoState();
    const segments = (key.action as WheelPadAction).segments;
    const idx = segments.length + 1;
    const newSeg: WheelPadSegment = {
      label: `${idx}`,
      action: { type: 'keyboard', vk: 0x30 + (idx % 10) } as KeyboardAction,
    };
    segments.push(newSeg);
    this.forceRefreshSelectedKey();
  }

  /** 删除指定分区（至少保留 2 个） */
  private removeWheelPadSegment(segIndex: number): void {
    const key = this.getSelectedKey();
    if (!key || key.action.type !== 'wheelPad') return;
    const segments = (key.action as WheelPadAction).segments;
    if (segments.length <= 2) return;
    this.pushUndoState();
    segments.splice(segIndex, 1);
    if (this.segmentPickerIndex >= segments.length) {
      this.segmentPickerIndex = -1;
    }
    this.forceRefreshSelectedKey();
  }

  /** 强制刷新选中按键的 UI（触发 @State keys 变更） */
  private forceRefreshSelectedKey(): void {
    const idx = this.keys.findIndex(k => k.id === this.selectedKeyId);
    if (idx >= 0) {
      const newKeys = this.keys.slice();
      newKeys[idx] = cloneKeyDef(this.keys[idx]);
      // 保留 action 引用（cloneKeyDef 浅拷贝 action）
      newKeys[idx].action = this.keys[idx].action;
      this.keys = newKeys;
      CustomKeyStore.saveKeys(this.keys);
    }
  }

  /** 用于分区编辑的简化预设列表（排除复合类型） */
  private static readonly SEGMENT_PICKER_CATEGORIES: string[] = [
    '常用键', '功能键', '鼠标', '手柄', '方向键', '字母', '数字', '符号',
  ];

  @Builder
  SegmentActionPicker(segIndex: number) {
    Column({ space: 4 }) {
      // 分类选择
      Scroll() {
        Row({ space: 4 }) {
          ForEach(CustomKeyOverlay.SEGMENT_PICKER_CATEGORIES, (catName: string, catIdx?: number) => {
            Text(catName)
              .fontSize(10)
              .fontColor(this.segmentPickerCategoryIdx === (catIdx ?? 0) ? OV_TEXT_WHITE : OV_TEXT_DIM)
              .fontWeight(FontWeight.Medium)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(10)
              .backgroundColor(this.segmentPickerCategoryIdx === (catIdx ?? 0) ? OV_ACCENT_BLUE : '#15FFFFFF')
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
              .onClick(() => { this.segmentPickerCategoryIdx = catIdx ?? 0; })
          }, (catName: string) => catName)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      // 按键列表
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(4), cross: LengthMetrics.vp(4) } }) {
        ForEach(this.getSegmentPickerPresets(), (preset: KeyPreset) => {
          Text(preset.label)
            .fontSize(10).fontColor(OV_TEXT_WHITE).fontWeight(FontWeight.Medium)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(8)
            .backgroundColor(OV_BG_TRACK)
            .border({ width: 1, color: '#20FFFFFF' })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => { this.updateSegmentAction(segIndex, preset.action); })
        }, (preset: KeyPreset) => `${preset.label}_${preset.action.type}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(6)
    .backgroundColor('#15FFFFFF')
    .borderRadius(6)
  }

  /** 获取当前分类下的按键预设 */
  private getSegmentPickerPresets(): KeyPreset[] {
    const catName = CustomKeyOverlay.SEGMENT_PICKER_CATEGORIES[this.segmentPickerCategoryIdx];
    if (!catName) return [];
    for (let i = 0; i < KEY_PRESET_CATEGORIES.length; i++) {
      if (KEY_PRESET_CATEGORIES[i].name === catName) {
        // 过滤掉复合类型（摇杆、十字键、轮盘等不适合作为分区动作的类型）
        return KEY_PRESET_CATEGORIES[i].presets.filter((p: KeyPreset): boolean => {
          const t = p.action.type;
          return t !== 'analogStick' && t !== 'dpad' && t !== 'wheelPad' && t !== 'digitalStick';
        });
      }
    }
    return [];
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
