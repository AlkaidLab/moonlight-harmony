/*
 * Moonlight for HarmonyOS
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { LengthMetrics } from '@kit.ArkUI';
import {
  CustomKeyDef, KeyMenuAction, KeyActionItem, KeyAction,
  createDefaultKeyDef, getActionDisplayName,
} from '../service/customkey/CustomKeyTypes';
import { resolveKeyMenuLayout, KeyMenuLayout, isKeyMenuItemAction } from '../service/customkey/KeyMenuController';
import {
  OV_ACCENT_BLUE, OV_ACCENT_GOLD, OV_BG_CARD_LIGHTER, OV_BG_DIVIDER, OV_BG_TRACK,
  OV_BLUE_20, OV_BLUE_50, OV_TEXT_BRIGHT, OV_TEXT_DIM, OV_TEXT_MEDIUM, OV_TEXT_WHITE,
} from '../common/OverlayConstants';

const MENU_PANEL_SPACING_VP = 8;
const MENU_ITEM_CONTENT_SPACING_VP = 4;
const MENU_ITEM_GAP_VP = 8;
const MENU_ITEM_HEIGHT_VP = 68;
const MENU_SCROLLBAR_RESERVE_VP = 44;

/** 仅菜单区域参与命中测试，不加全屏遮罩，保留其他手指的移动/视角操作。 */
@Component
export struct CustomKeyMenuPanel {
  @Prop menuKey: CustomKeyDef = createDefaultKeyDef();
  @Prop viewWidth: number = 0;
  @Prop viewHeight: number = 0;
  onExecute: (action: KeyAction) => void = () => {};
  onClose: () => void = () => {};
  onAutoCloseChanged: (autoClose: boolean) => void = () => {};

  private menu(): KeyMenuAction {
    return this.menuKey.action as KeyMenuAction;
  }

  private layout(): KeyMenuLayout {
    return resolveKeyMenuLayout(this.menuKey, this.viewWidth, this.viewHeight, this.menu().items.length);
  }

  private autoCloseEnabled(): boolean {
    return this.menu().autoClose !== false;
  }

  private itemWidth(): number {
    const layout = this.layout();
    return (layout.width - MENU_SCROLLBAR_RESERVE_VP - (layout.columns - 1) * MENU_ITEM_GAP_VP) /
      layout.columns;
  }

  build() {
    Column({ space: MENU_PANEL_SPACING_VP }) {
      Row({ space: MENU_PANEL_SPACING_VP }) {
        Text(this.menuKey.label)
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(OV_TEXT_BRIGHT)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 5 }) {
          Circle()
            .width(6).height(6)
            .fill(this.autoCloseEnabled() ? OV_TEXT_MEDIUM : OV_ACCENT_BLUE)
          Text(this.autoCloseEnabled() ? '执行后收起' : '保持展开')
            .fontSize(11)
            .fontColor(this.autoCloseEnabled() ? OV_TEXT_MEDIUM : OV_ACCENT_BLUE)
        }
          .height(34).padding({ left: 10, right: 10 })
          .justifyContent(FlexAlign.Center)
          .borderRadius(17)
          .backgroundColor(this.autoCloseEnabled() ? OV_BG_TRACK : OV_BLUE_20)
          .border({ width: 1, color: this.autoCloseEnabled() ? '#20FFFFFF' : OV_BLUE_50 })
          .accessibilityText(this.autoCloseEnabled() ? '当前为执行后自动收起，点击后保持展开' : '当前为保持展开，点击后执行后自动收起')
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => this.onAutoCloseChanged(!this.autoCloseEnabled()))
        Stack() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16).fontColor([OV_TEXT_WHITE])
        }
          .width(34).height(34).borderRadius(17)
          .backgroundColor(OV_BG_TRACK)
          .border({ width: 1, color: '#20FFFFFF' })
          .alignContent(Alignment.Center)
          .accessibilityText('收起快捷菜单')
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => this.onClose())
      }
      .width('100%')

      Divider()
        .strokeWidth(1).color(OV_BG_DIVIDER).width('100%')

      Scroll() {
        if (this.menu().items.length === 0) {
          Text('暂无菜单项，请在编辑模式中添加')
            .fontSize(12).fontColor(OV_TEXT_DIM).padding(16)
        } else {
          Flex({ wrap: FlexWrap.Wrap, space: {
            main: LengthMetrics.vp(MENU_ITEM_GAP_VP),
            cross: LengthMetrics.vp(MENU_ITEM_GAP_VP),
          } }) {
            ForEach(this.menu().items, (item: KeyActionItem, index: number) => {
              Column({ space: MENU_ITEM_CONTENT_SPACING_VP }) {
                Text(item.label)
                  .fontSize(14).fontColor(OV_TEXT_WHITE).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(getActionDisplayName(item.action))
                  .fontSize(11).fontColor(OV_TEXT_DIM).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              // Scroll 会占用一小段宽度，额外预留空间避免两列被挤成单列。
              .width(this.itemWidth())
              .height(MENU_ITEM_HEIGHT_VP).padding({ left: 8, right: 8 }).borderRadius(16)
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
              .backgroundColor(OV_BG_CARD_LIGHTER)
              .border({ width: 1, color: '#30FFFFFF' })
              .opacity(isKeyMenuItemAction(item.action) ? 1 : 0.45)
              .accessibilityText(item.label + '，' + getActionDisplayName(item.action))
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
              .onClick(() => {
                if (isKeyMenuItemAction(item.action)) this.onExecute(item.action);
              })
            }, (_item: KeyActionItem, index: number) => `${index}`)
          }
          .width('100%')
        }
      }
      .layoutWeight(1).width('100%').scrollBar(BarState.Auto)

      Row({ space: 6 }) {
        Circle()
          .width(6).height(6)
          .fill(this.autoCloseEnabled() ? OV_ACCENT_BLUE : OV_ACCENT_GOLD)
        Text(this.autoCloseEnabled() ? '执行后自动收起' : '保持展开 · 点击入口或关闭按钮收起')
          .fontSize(11).fontColor(OV_TEXT_DIM).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
    }
    .padding(16).width(this.layout().width).height(this.layout().height)
    .borderRadius(20).backgroundColor('#E61A1A2E')
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 18, color: '#60000000', offsetY: 6 })
    .position({ x: this.layout().x, y: this.layout().y })
    // 让菜单子节点成为实际命中目标；面板外层仍由 CustomKeyOverlay 的透明容器负责定位。
    .hitTestBehavior(HitTestMode.Default)
  }
}
