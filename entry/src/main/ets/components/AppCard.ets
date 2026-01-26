import { AppInfo } from '../model/AppInfo';

/**
 * 应用卡片组件
 */
@Component
export struct AppCard {
  @Prop app: AppInfo;
  onTap: () => void = () => {};

  build() {
    Column() {
      // 应用图标占位
      Stack() {
        // 背景
        Column()
          .width('100%')
          .height(120)
          .backgroundColor('#2a2a4a')
          .borderRadius({ topLeft: 12, topRight: 12 })

        // 图标占位
        Image($r('app.media.ic_game'))
          .width(48)
          .height(48)
          .fillColor($r('app.color.text_secondary'))

        // 运行中指示器
        if (this.app.isRunning) {
          Row() {
            Circle()
              .width(8)
              .height(8)
              .fill($r('app.color.online_green'))
              .margin({ right: 4 })
            Text('运行中')
              .fontSize(10)
              .fontColor($r('app.color.online_green'))
          }
          .position({ x: 8, y: 8 })
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#33000000')
          .borderRadius(12)
        }
      }

      // 应用名称
      Text(this.app.name)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .padding({ left: 8, right: 8, top: 12, bottom: 12 })
    }
    .width('100%')
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(12)
    .clip(true)
    .onClick(() => {
      this.onTap();
    })
  }
}
