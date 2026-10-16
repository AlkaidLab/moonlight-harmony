/*
 * Moonlight for HarmonyOS
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { KeyAction, CustomKeyDef, ComboAction, KeyMenuAction, KeyActionItem, KeyboardAction } from './CustomKeyTypes';

const KEY_MENU_MARGIN_VP = 12;
const KEY_MENU_MAX_WIDTH_VP = 320;
const KEY_MENU_THREE_COLUMN_WIDTH_VP = 360;
const KEY_MENU_BASE_HEIGHT_VP = 112;
const KEY_MENU_ROW_HEIGHT_VP = 76;

/** 菜单只接受可点按动作，连续区域和嵌套容器仍由各自控件处理。 */
export function isKeyMenuItemAction(action: KeyAction, depth: number = 0): boolean {
  if (!action || depth > 8) return false;
  switch (action.type) {
    case 'keyboard':
      return validKeyboardKeys([action.vk]);
    case 'mouse':
      return Number.isInteger(action.button) && action.button >= 1 && action.button <= 5;
    case 'mouseScroll':
      return Number.isFinite(action.direction) && action.direction !== 0;
    case 'gamepadButton':
      return Number.isInteger(action.mask) && action.mask > 0;
    case 'gamepadTrigger':
      return action.trigger === 'left' || action.trigger === 'right';
    case 'gamepadStick':
      return (action.stick === 'left' || action.stick === 'right') &&
        ['up', 'down', 'left', 'right'].includes(action.direction);
    case 'shortcut':
      return Array.isArray(action.keySequence) && action.keySequence.length > 0
        ? action.keySequence.every((keys: number[]) => validKeyboardKeys(keys)) : validKeyboardKeys(action.keys);
    case 'combo': {
      const actions = (action as ComboAction).actions;
      return Array.isArray(actions) && actions.length > 0 &&
        actions.every((child: KeyAction) => isKeyMenuItemAction(child, depth + 1));
    }
    default:
      return false;
  }
}

function validKeyboardKeys(keys: number[]): boolean {
  return Array.isArray(keys) && keys.length > 0 &&
    keys.every((vk: number) => Number.isInteger(vk) && vk > 0 && vk <= 0xFF);
}

/** 导入和本地加载走同样的菜单校验；不修改其他控件的数据。 */
export function normalizeKeyMenuAction(menu: KeyMenuAction): KeyMenuAction {
  const items = Array.isArray(menu.items) ? menu.items : [];
  return {
    type: 'keyMenu', autoClose: menu.autoClose !== false,
    items: items.filter((item: KeyActionItem) => !!item && typeof item.label === 'string' &&
      isKeyMenuItemAction(item.action)),
  };
}

export interface KeyMenuLayout {
  x: number;
  y: number;
  width: number;
  height: number;
  columns: number;
}

/** 使用覆盖层实际尺寸避让屏幕边缘；项目多时仅在菜单内部滚动。 */
export function resolveKeyMenuLayout(key: CustomKeyDef, viewWidth: number,
  viewHeight: number, count: number): KeyMenuLayout {
  const width = Math.min(KEY_MENU_MAX_WIDTH_VP,
    Math.max(0, viewWidth - KEY_MENU_MARGIN_VP * 2));
  // 两列能保留足够的点击面积；需要更宽的窗口才使用三列，避免滚动条挤压第三列。
  const columns = width >= KEY_MENU_THREE_COLUMN_WIDTH_VP ? 3 : 2;
  const height = Math.min(KEY_MENU_BASE_HEIGHT_VP +
    Math.ceil(Math.max(1, count) / columns) * KEY_MENU_ROW_HEIGHT_VP,
    Math.max(0, viewHeight - KEY_MENU_MARGIN_VP * 2));
  const anchorX = key.xPercent * viewWidth;
  const anchorY = key.yPercent * viewHeight;
  const above = anchorY - key.height / 2 - KEY_MENU_MARGIN_VP - height;
  const below = anchorY + key.height / 2 + KEY_MENU_MARGIN_VP;
  let x = anchorX + key.width / 2 - width;
  let y = above;
  if (above < KEY_MENU_MARGIN_VP) {
    y = below;
    if (below + height > viewHeight - KEY_MENU_MARGIN_VP) {
      const right = anchorX + key.width / 2 + KEY_MENU_MARGIN_VP;
      const left = anchorX - key.width / 2 - KEY_MENU_MARGIN_VP - width;
      if (right + width <= viewWidth - KEY_MENU_MARGIN_VP || left >= KEY_MENU_MARGIN_VP) {
        x = right + width <= viewWidth - KEY_MENU_MARGIN_VP ? right : left;
        y = anchorY - height / 2;
      }
    }
  }
  return {
    x: Math.max(KEY_MENU_MARGIN_VP,
      Math.min(viewWidth - width - KEY_MENU_MARGIN_VP, x)),
    y: Math.max(KEY_MENU_MARGIN_VP,
      Math.min(viewHeight - height - KEY_MENU_MARGIN_VP, y)),
    width: width, height: height, columns: columns,
  };
}

/**
 * 与弹出面板分离的点按生命周期。自动收起不会销毁待释放的按键；
 * 切换配置、进入编辑、暂停输入及卸载覆盖层时 reset() 立即释放。
 */
export class KeyMenuController {
  onOpenChanged: (keyId: string) => void = () => {};
  onAction: (action: KeyAction, isDown: boolean) => void = () => {};
  private openKeyId: string = '';
  private pulses: KeyActionPulseRunner = new KeyActionPulseRunner();

  constructor() {
    this.pulses.onAction = (action: KeyAction, isDown: boolean): void => this.onAction(action, isDown);
  }

  toggle(keyId: string): void {
    this.openKeyId = this.openKeyId === keyId ? '' : keyId;
    this.onOpenChanged(this.openKeyId);
  }

  close(): void {
    this.openKeyId = '';
    this.onOpenChanged('');
  }

  execute(action: KeyAction, autoClose: boolean): boolean {
    if (this.openKeyId === '' || !isKeyMenuItemAction(action)) return false;
    this.pulses.execute(action);
    if (autoClose) this.close();
    return true;
  }

  reset(): void {
    this.pulses.reset();
    this.close();
  }
}

/** 菜单和常驻快捷键共用可取消的点按/序列执行器，统一经过输入状态仲裁。 */
export class KeyActionPulseRunner {
  onAction: (action: KeyAction, isDown: boolean) => void = () => {};
  private pendingTimers: number[] = [];
  private pressedActions: KeyAction[] = [];

  execute(action: KeyAction, holdMs: number = 100): void {
    const groups: Map<number, KeyAction[]> = new Map();
    this.collectActions(action, 0, groups);
    groups.forEach((actions: KeyAction[], delay: number) => {
      if (delay === 0) this.pressTogether(actions, holdMs);
      else this.schedule(() => this.pressTogether(actions, holdMs), delay);
    });
  }

  reset(): void {
    for (const timer of this.pendingTimers) clearTimeout(timer);
    this.pendingTimers = [];
    const pressed = this.pressedActions;
    this.pressedActions = [];
    for (let i = pressed.length - 1; i >= 0; i--) this.onAction(pressed[i], false);
  }

  private schedule(callback: () => void, delay: number): void {
    const timer = setTimeout(() => {
      this.pendingTimers = this.pendingTimers.filter((id: number) => id !== timer);
      callback();
    }, delay) as number;
    this.pendingTimers.push(timer);
  }

  private collectActions(action: KeyAction, delay: number, groups: Map<number, KeyAction[]>): void {
    if (action.type === 'combo') {
      for (const child of action.actions) this.collectActions(child, delay, groups);
      return;
    }
    if (action.type === 'shortcut') {
      // 与现有快捷键相同的 200ms 步间隔；定时器归菜单所有，暂停时可取消后续步骤。
      const steps = action.keySequence && action.keySequence.length > 0 ? action.keySequence : [action.keys];
      steps.forEach((keys: number[], index: number) => {
        keys.forEach((vk: number) => {
          this.collectActions({ type: 'keyboard', vk: vk } as KeyboardAction, delay + index * 200, groups);
        });
      });
      return;
    }
    const actions = groups.get(delay) ?? [];
    actions.push(action);
    groups.set(delay, actions);
  }

  private pressTogether(actions: KeyAction[], holdMs: number): void {
    for (const action of actions) {
      this.pressedActions.push(action);
      this.onAction(action, true);
    }
    this.schedule(() => {
      for (let i = actions.length - 1; i >= 0; i--) {
        const action = actions[i];
        const index = this.pressedActions.indexOf(action);
        if (index < 0) continue;
        this.pressedActions.splice(index, 1);
        this.onAction(action, false);
      }
    }, holdMs);
  }
}
