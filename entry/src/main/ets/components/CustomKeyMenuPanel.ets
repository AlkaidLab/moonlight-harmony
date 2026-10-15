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
import { StreamMenuColors } from '../common/OverlayConstants';

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

  build() {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        Text(this.menuKey.label)
          .fontSize(13).fontWeight(FontWeight.Medium).fontColor(StreamMenuColors.TextBright)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button(this.menu().autoClose !== false ? '固定' : '已固定', { type: ButtonType.Normal })
          .fontSize(11).fontColor(StreamMenuColors.TextBright)
          .backgroundColor(this.menu().autoClose !== false ? StreamMenuColors.Control : StreamMenuColors.SelectedSurface)
          .borderRadius(10).height(44).padding({ left: 10, right: 10 })
          .accessibilityText(this.menu().autoClose !== false ? '保持展开' : '恢复执行后自动收起')
          .onClick(() => this.onAutoCloseChanged(this.menu().autoClose === false))
        Button('✕', { type: ButtonType.Normal })
          .width(44).height(44).borderRadius(10).fontSize(16)
          .backgroundColor(StreamMenuColors.Control).fontColor(StreamMenuColors.TextBright)
          .accessibilityText('收起快捷菜单')
          .onClick(() => this.onClose())
      }
      .width('100%')

      Scroll() {
        if (this.menu().items.length === 0) {
          Text('暂无菜单项，请在编辑模式中添加')
            .fontSize(12).fontColor(StreamMenuColors.TextDim).padding(12)
        } else {
          Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
            ForEach(this.menu().items, (item: KeyActionItem, index: number) => {
              Button({ type: ButtonType.Normal }) {
                Column({ space: 5 }) {
                  Text(item.label)
                    .fontSize(13).fontColor(StreamMenuColors.TextBright).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(getActionDisplayName(item.action))
                    .fontSize(11).fontColor(StreamMenuColors.TextDim).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
              }
              .width((this.layout().width - 20 - (this.layout().columns - 1) * 6) / this.layout().columns)
              .height(60).padding(6).borderRadius(12).backgroundColor(StreamMenuColors.Control)
              .enabled(isKeyMenuItemAction(item.action))
              .accessibilityText(`${item.label}，${getActionDisplayName(item.action)}`)
              .onClick(() => this.onExecute(item.action))
            }, (_item: KeyActionItem, index: number) => `${index}`)
          }
          .width('100%')
        }
      }
      .layoutWeight(1).width('100%').scrollBar(BarState.Auto)

      Text(this.menu().autoClose !== false ? '执行后自动收起' : '保持展开 · 点击入口或 ✕ 收起')
        .fontSize(11).fontColor(StreamMenuColors.TextDim).maxLines(1)
    }
    .padding(10).width(this.layout().width).height(this.layout().height)
    .borderRadius(18).backgroundColor(StreamMenuColors.Surface)
    .border({ width: 1, color: StreamMenuColors.Border })
    .shadow({ radius: 18, color: StreamMenuColors.Shadow, offsetY: 6 })
    .position({ x: this.layout().x, y: this.layout().y })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => event.stopPropagation())
  }
}
