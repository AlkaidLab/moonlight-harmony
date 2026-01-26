import { router } from '@kit.ArkUI';

@Entry
@Component
struct Index {
  @State isLoading: boolean = true;

  aboutToAppear(): void {
    // 模拟初始化加载
    setTimeout(() => {
      this.isLoading = false;
      // 自动跳转到主页
      router.replaceUrl({
        url: 'pages/PcListPage'
      });
    }, 1500);
  }

  build() {
    Column() {
      // Logo
      Image($r('app.media.startIcon'))
        .width(120)
        .height(120)
        .margin({ bottom: 24 })

      // 应用名称
      Text('Moonlight V+')
        .fontSize(32)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 8 })

      // 副标题
      Text('HarmonyOS 游戏串流客户端')
        .fontSize(16)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 48 })

      // 加载指示器
      if (this.isLoading) {
        LoadingProgress()
          .width(48)
          .height(48)
          .color($r('app.color.primary'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
