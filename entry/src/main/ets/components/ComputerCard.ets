import { ComputerInfo, ComputerState } from '../model/ComputerInfo';

/**
 * 电脑卡片组件
 */
@Component
export struct ComputerCard {
  @Prop computer: ComputerInfo;
  onTap: () => void = () => {};
  onLongPress: () => void = () => {};

  build() {
    Row() {
      // 状态指示器
      Circle()
        .width(12)
        .height(12)
        .fill(this.getStatusColor())
        .margin({ right: 16 })

      // 电脑信息
      Column() {
        Text(this.computer.name)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.computer.address)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 4 })

        // 状态标签
        Row() {
          Text(this.getStatusText())
            .fontSize(12)
            .fontColor(this.getStatusColor())

          if (this.computer.runningGameId > 0) {
            Text(' · 正在运行游戏')
              .fontSize(12)
              .fontColor($r('app.color.warning_yellow'))
          }
        }
        .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 箭头指示
      Image($r('app.media.ic_arrow_right'))
        .width(24)
        .height(24)
        .fillColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(16)
    .onClick(() => {
      this.onTap();
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          this.onLongPress();
        })
    )
  }

  getStatusColor(): ResourceColor {
    switch (this.computer.state) {
      case ComputerState.ONLINE:
        return $r('app.color.online_green');
      case ComputerState.OFFLINE:
        return $r('app.color.offline_gray');
      case ComputerState.PAIRING:
        return $r('app.color.warning_yellow');
      default:
        return $r('app.color.offline_gray');
    }
  }

  getStatusText(): string {
    switch (this.computer.state) {
      case ComputerState.ONLINE:
        return '在线';
      case ComputerState.OFFLINE:
        return '离线';
      case ComputerState.PAIRING:
        return '配对中...';
      default:
        return '未知';
    }
  }
}
