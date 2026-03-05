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
import { display, LengthMetrics, promptAction } from '@kit.ArkUI';
import {
  CustomKeyDef,
  KeyAction,
  KeyBehavior,
  KeyShape,
  AnalogStickAction,
  createDefaultKeyDef,
  cloneKeyDef,
  KEY_PRESET_CATEGORIES,
  KeyPreset,
  KeyPresetCategory,
} from '../service/CustomKeyTypes';
import { CustomKeyStore } from '../service/CustomKeyStore';
import { VirtualJoystick } from './VirtualJoystick';
import {
  OV_ACCENT_BLUE, OV_TEXT_BRIGHT, OV_TEXT_MEDIUM, OV_TEXT_DIM,
  OV_TEXT_WHITE, OV_TEXT_SUBTLE, OV_BG_TRACK, OV_BG_CARD_LIGHTER,
  OV_BG_CARD_DARK, OV_BLUE_40, OV_BLUE_50,
  OV_FONT_MD, OV_FONT_LG,
} from '../common/OverlayConstants';

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
        width: this.editMode ? 2 : 1,
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
          this.dragOffsetX = dx;
          this.dragOffsetY = dy;
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
    try {
      vibrator.startVibration({ type: 'time', duration: 15 }, { id: 0, usage: 'touch' });
    } catch (_e) { /* ignore */ }
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
        // 自定义按键 —— 每个是独立 @Component，有自己的触摸生命周期
        ForEach(this.keys, (key: CustomKeyDef) => {
          if (key.action.type === 'analogStick' && !this.editMode) {
            // 模拟摇杆：非编辑模式时渲染真正的虚拟摇杆 UI
            VirtualJoystick({
              joystickSize: Math.max(key.width, key.height),
              ringColor: key.normalColor,
              stickColor: key.bgColor,
              pressedColor: key.pressedColor,
              opacity_: key.opacity,
              onMovement: (x: number, y: number): void => {
                const stickAction = key.action as AnalogStickAction;
                this.onAnalogStickMovement(stickAction.stick, x, y);
              },
              onStickClick: (): void => {
                // 单击仅开始追踪，不发送任何按键
              },
              onDoubleClick: (): void => {
                // 双击触发 L3/R3 短按+自动释放（与 AnalogStick 一致）
                const stickAction = key.action as AnalogStickAction;
                this.onAnalogStickClick(stickAction.stick);
              },
              onRevoke: (): void => {
                // 手指抬起：无需额外操作（L3/R3 已自动释放）
              },
              isEditMode: (): boolean => this.editMode,
            })
              .position({
                x: key.xPercent * this.screenWidthVp - Math.max(key.width, key.height) / 2,
                y: key.yPercent * this.screenHeightVp - Math.max(key.width, key.height) / 2,
              })
          } else {
            // 普通按键（含编辑模式下的 analogStick 占位）
            CustomKeyBtn({
              keyDef: key,
              editMode: this.editMode,
              isSelected: this.selectedKeyId === key.id,
              onAction: (action: KeyAction, isDown: boolean): void => {
                this.onKeyAction(action, isDown);
              },
              onDragFinish: (keyId: string, deltaX: number, deltaY: number): void => {
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
              .position({
                x: key.xPercent * this.screenWidthVp - key.width / 2,
                y: key.yPercent * this.screenHeightVp - key.height / 2,
              })
          }
        }, (key: CustomKeyDef) => {
          // key 包含位置和外观属性，任何变化都触发组件重建
          // 加上 editMode 以在模式切换时强制重建（切换 VirtualJoystick ↔ CustomKeyBtn）
          return `${key.id}|${this.editMode}|${key.xPercent.toFixed(4)}|${key.yPercent.toFixed(4)}|${key.width}|${key.height}|${key.opacity}|${key.fontSize}|${key.borderRadius}|${key.shape}|${key.behavior}|${key.label}|${key.bgColor}|${key.textColor}`;
        })

        // 添加按键面板
        if (this.showAddPanel) {
          this.AddKeyPanel()
        }

        // 属性编辑面板
        if (this.showPropertyPanel && this.selectedKeyId) {
          this.PropertyPanel()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.BottomStart)
      .hitTestBehavior(HitTestMode.Transparent)
      // hitTestReady: 微小 opacity 变化触发父层重渲染，刷新命中测试树
      .opacity(this.hitTestReady > 0 ? 1 : 0.99)

      // 编辑模式工具栏（面板打开时隐藏，避免遮挡面板）
      if (this.editMode && !this.showAddPanel && !this.showPropertyPanel) {
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

          Blank()

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
  // 编辑操作
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private handleDragEnd(keyId: string, deltaX: number, deltaY: number): void {
    const idx = this.keys.findIndex(k => k.id === keyId);
    if (idx === -1) return;
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
        width = 120;
        height = 120;
        bgColor = '#4050C080';
        pressedColor = '#8070E090';
        textColor = '#E0FFFFFF';
        borderRadius = 60;
        fontSize = 12;
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
    this.keys = newArr;
    await CustomKeyStore.addKey(newKey);
    this.selectedKeyId = newKey.id;
    this.showAddPanel = false;
  }

  private async deleteSelectedKey(): Promise<void> {
    if (!this.selectedKeyId) return;
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
        Column({ space: 10 }) {
          // 标签编辑
          Row() {
            Text('标签').fontSize(12).fontColor(OV_TEXT_MEDIUM).width(50)
            TextInput({ text: this.getSelectedKey()?.label ?? '' })
              .layoutWeight(1).height(32).fontSize(OV_FONT_LG)
              .fontColor(OV_TEXT_WHITE).backgroundColor(OV_BG_CARD_LIGHTER)
              .borderRadius(8).padding({ left: 8, right: 8 })
              .maxLength(8)
              .onChange((value: string) => { this.updateSelectedKeyProp('label', value); })
          }
          .width('100%').padding({ left: 4, right: 4 })

          this.PropertySlider('宽度', 30, 200, this.getSelectedKey()?.width ?? 60, 'width')
          this.PropertySlider('高度', 30, 200, this.getSelectedKey()?.height ?? 60, 'height')
          this.PropertySlider('透明度', 10, 100, this.getSelectedKey()?.opacity ?? 80, 'opacity')
          this.PropertySlider('字号', 8, 30, this.getSelectedKey()?.fontSize ?? 14, 'fontSize')
          this.PropertySlider('圆角', 0, 50, this.getSelectedKey()?.borderRadius ?? 12, 'borderRadius')

          // 背景色
          Row() {
            Text('底色').fontSize(12).fontColor(OV_TEXT_MEDIUM).width(50)
            Row({ space: 6 }) {
              ForEach(BG_COLOR_PRESETS, (color: string) => {
                Text('')
                  .width(22).height(22).borderRadius(11)
                  .backgroundColor(color)
                  .border({
                    width: this.getSelectedKey()?.bgColor === color ? 2 : 1,
                    color: this.getSelectedKey()?.bgColor === color ? '#FFFFD700' : '#30FFFFFF',
                  })
                  .onClick(() => { this.updateSelectedKeyProp('bgColor', color); })
              })
            }
          }
          .width('100%').padding({ left: 4, right: 4 })

          // 文字色
          Row() {
            Text('字色').fontSize(12).fontColor(OV_TEXT_MEDIUM).width(50)
            Row({ space: 6 }) {
              ForEach(TEXT_COLOR_PRESETS, (color: string) => {
                Text('')
                  .width(22).height(22).borderRadius(11)
                  .backgroundColor(color)
                  .border({
                    width: this.getSelectedKey()?.textColor === color ? 2 : 1,
                    color: this.getSelectedKey()?.textColor === color ? '#FFFFD700' : '#30FFFFFF',
                  })
                  .onClick(() => { this.updateSelectedKeyProp('textColor', color); })
              })
            }
          }
          .width('100%').padding({ left: 4, right: 4 })

          Row() {
            Text('模式').fontSize(12).fontColor(OV_TEXT_MEDIUM).width(50)
            Row({ space: 8 }) {
              this.BehaviorChip('点触', 'momentary')
              this.BehaviorChip('切换', 'toggle')
            }
          }
          .width('100%').padding({ left: 4, right: 4 })

          Row() {
            Text('形状').fontSize(12).fontColor(OV_TEXT_MEDIUM).width(50)
            Row({ space: 8 }) {
              this.ShapeChip('方形', 'rect')
              this.ShapeChip('圆形', 'circle')
            }
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
