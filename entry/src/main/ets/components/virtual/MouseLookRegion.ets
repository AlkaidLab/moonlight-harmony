/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2026 Moonlight/AlkaidLab
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import { MouseLookGestureHandler } from '../../service/input/MouseLookGestureHandler';

/** 独立触摸生命周期，阻断区域内事件，避免底层触摸模式发送点击。 */
@Component
export struct MouseLookRegion {
  @Prop regionWidth: number = 200;
  @Prop regionHeight: number = 200;
  @Prop sensitivity: number = 1.5;
  @Prop invertY: boolean = false;
  @Prop @Watch('onInputEnabledChanged') inputEnabled: boolean = true;
  onMovement: (deltaX: number, deltaY: number) => void = () => {};
  private handler: MouseLookGestureHandler = new MouseLookGestureHandler();

  onInputEnabledChanged(): void {
    this.handler.reset();
  }

  aboutToDisappear(): void {
    this.handler.reset();
  }

  build() {
    Column()
      .width(this.regionWidth)
      .height(this.regionHeight)
      // 保持命中测试区域，游玩时无可见标签、边框或光标。
      .backgroundColor('#01000000')
      .hitTestBehavior(HitTestMode.Block)
      .onTouch((event: TouchEvent) => {
        event.stopPropagation();
        if (!this.inputEnabled) {
          this.handler.reset();
          return;
        }
        this.handler.handleEvent(event, this.sensitivity, this.invertY, this.onMovement);
      })
  }
}
