/**
 * 性能监控浮层组件
 */
@Component
export struct PerformanceOverlay {
  @Prop fps: number;
  @Prop bitrate: number;
  @Prop latency: number;
  @Prop packetLoss: number;

  @State offsetX: number = 16;
  @State offsetY: number = 80;

  build() {
    Column() {
      this.StatRow('FPS', `${this.fps}`, this.fps < 30 ? $r('app.color.error_red') : $r('app.color.online_green'))
      this.StatRow('码率', `${(this.bitrate / 1000).toFixed(1)} Mbps`, $r('app.color.text_primary'))
      this.StatRow('延迟', `${this.latency} ms`, this.latency > 50 ? $r('app.color.warning_yellow') : $r('app.color.online_green'))
      this.StatRow('丢包', `${this.packetLoss.toFixed(1)}%`, this.packetLoss > 1 ? $r('app.color.error_red') : $r('app.color.online_green'))
    }
    .padding(12)
    .backgroundColor('#99000000')
    .borderRadius(12)
    .position({ x: this.offsetX, y: this.offsetY })
    .gesture(
      PanGesture()
        .onActionUpdate((event) => {
          this.offsetX += event.offsetX;
          this.offsetY += event.offsetY;
        })
    )
  }

  @Builder
  StatRow(label: string, value: string, valueColor: ResourceColor) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width(40)

      Text(value)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(valueColor)
    }
    .width('100%')
    .margin({ bottom: 4 })
  }
}
