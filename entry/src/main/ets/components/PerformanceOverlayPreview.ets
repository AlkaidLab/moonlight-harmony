/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/** Settings-page preview. The numbers are examples, not live stream statistics. */
@Component
export struct PerformanceOverlayPreview {
  @Prop fontSize: number = 12;
  @Prop verticalPadding: number = 12;
  // Percentage of transparency, matching the settings-page slider.
  @Prop backgroundTransparency: number = 47;
  @Prop isVertical: boolean = true;
  @State lightBackground: boolean = false;
  @State expanded: boolean = false;

  private overlayBackgroundColor(): string {
    const transparency = Math.max(0, Math.min(100, this.backgroundTransparency));
    const alpha = Math.round((100 - transparency) * 255 / 100).toString(16).padStart(2, '0');
    return '#' + alpha + '161616';
  }

  @Builder
  SampleOverlay() {
    Column({ space: this.fontSize / 3 }) {
      if (this.isVertical) {
        Text('☾ 1920x1080@60')
          .fontSize(this.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
        Text('Rx 60 / Rd 60 FPS')
          .fontSize(this.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0DDAF4')
        Text('● 12 ms')
          .fontSize(this.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor('#4CAF50')
      } else {
        Row() {
          Text('☾ 1920x1080@60')
            .fontSize(this.fontSize * 11 / 12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
          Text('  |  ')
            .fontSize(this.fontSize * 11 / 12)
            .fontColor('#66FFFFFF')
          Text('60/60 FPS')
            .fontSize(this.fontSize * 11 / 12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#0DDAF4')
          Text('  |  ')
            .fontSize(this.fontSize * 11 / 12)
            .fontColor('#66FFFFFF')
          Text('● 12 ms')
            .fontSize(this.fontSize * 11 / 12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#4CAF50')
        }
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: 12,
      right: 12,
      top: this.isVertical ? this.verticalPadding : Math.max(0, this.verticalPadding - 4),
      bottom: this.isVertical ? this.verticalPadding : Math.max(0, this.verticalPadding - 4)
    })
    .backgroundColor(this.overlayBackgroundColor())
    .borderRadius(12)
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 2 }) {
          Text('覆盖层预览')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#263B4B')
          Text(this.expanded ? '示例数据，调整时实时更新' : '查看大小和透明度效果')
            .fontSize(11)
            .fontColor('#748590')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(this.expanded ? '收起' : '展开')
          .fontSize(12)
          .fontColor('#2C75B5')
        Image($r('app.media.ic_arrow_right'))
          .width(14)
          .height(14)
          .fillColor('#2C75B5')
          .rotate({ angle: this.expanded ? 90 : 0 })
          .margin({ left: 4 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .focusable(true)
      .focusOnTouch(true)
      .onClick(() => { this.expanded = !this.expanded; })
      .onKeyEvent((event: KeyEvent) => {
        if (event.type === KeyType.Down && (event.keyCode === 2054 || event.keyCode === 2050)) {
          this.expanded = !this.expanded;
          return true;
        }
        return false;
      })

      if (this.expanded) {
        Row({ space: 4 }) {
          Blank()
          Button('深色')
            .fontSize(12)
            .fontColor(this.lightBackground ? '#536B79' : '#FFFFFF')
            .backgroundColor(this.lightBackground ? '#E8EFF4' : '#2C75B5')
            .height(32)
            .onClick(() => { this.lightBackground = false; })
          Button('浅色')
            .fontSize(12)
            .fontColor(this.lightBackground ? '#FFFFFF' : '#536B79')
            .backgroundColor(this.lightBackground ? '#2C75B5' : '#E8EFF4')
            .height(32)
            .onClick(() => { this.lightBackground = true; })
        }
        .width('100%')

        Stack({ alignContent: Alignment.Center }) {
          Scroll() {
            this.SampleOverlay()
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }
        .width('100%')
        // Keep the largest supported font and padding visible without moving the settings below.
        .height(192)
        .backgroundColor(this.lightBackground ? '#D9E2E9' : '#344757')
        .borderRadius(10)
        .clip(true)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#F1F6F9')
    .borderRadius(12)
  }
}
