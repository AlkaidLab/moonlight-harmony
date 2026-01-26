import { router } from '@kit.ArkUI';
import { AppInfo } from '../model/AppInfo';
import { NvComputer } from '../service/NvComputer';
import { AppCard } from '../components/AppCard';

interface PageParams {
  computerId: string;
}

@Entry
@Component
struct AppListPage {
  @State apps: AppInfo[] = [];
  @State computerName: string = '';
  @State isLoading: boolean = true;
  @State computerId: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as PageParams;
    if (params && params.computerId) {
      this.computerId = params.computerId;
      this.loadApps();
    }
  }

  async loadApps(): Promise<void> {
    this.isLoading = true;
    try {
      // TODO: 从 NvComputer 加载应用列表
      // const computer = await NvComputer.getComputer(this.computerId);
      // this.computerName = computer.name;
      // this.apps = await computer.getAppList();

      // 模拟数据
      this.computerName = '我的电脑';
      this.apps = [
        { id: 1, name: 'Steam', isRunning: false },
        { id: 2, name: 'Desktop', isRunning: false },
        { id: 3, name: 'Epic Games', isRunning: false },
      ];
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    Column() {
      // 标题栏
      this.TitleBar()

      // 应用列表
      if (this.isLoading) {
        this.LoadingState()
      } else if (this.apps.length === 0) {
        this.EmptyState()
      } else {
        this.AppGrid()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
  }

  @Builder
  TitleBar() {
    Row() {
      // 返回按钮
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ic_back'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        router.back();
      })

      Column() {
        Text(this.computerName)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text($r('app.string.app_list_title'))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 8 })

      Blank()

      // 刷新按钮
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ic_refresh'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.loadApps();
      })
    }
    .width('100%')
    .padding({
      left: 8,
      right: 16,
      top: 48,
      bottom: 16
    })
  }

  @Builder
  LoadingState() {
    Column() {
      LoadingProgress()
        .width(48)
        .height(48)
        .color($r('app.color.primary'))
      Text('加载应用列表...')
        .fontSize(16)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 16 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyState() {
    Column() {
      Image($r('app.media.ic_apps'))
        .width(100)
        .height(100)
        .fillColor($r('app.color.text_secondary'))
        .opacity(0.5)
        .margin({ bottom: 24 })

      Text('没有可用的应用')
        .fontSize(18)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  AppGrid() {
    Grid() {
      ForEach(this.apps, (app: AppInfo) => {
        GridItem() {
          AppCard({
            app: app,
            onTap: () => {
              this.startStream(app);
            }
          })
        }
      }, (app: AppInfo) => app.id.toString())
    }
    .columnsTemplate('1fr 1fr 1fr')
    .columnsGap(12)
    .rowsGap(12)
    .padding(16)
    .layoutWeight(1)
  }

  startStream(app: AppInfo): void {
    router.pushUrl({
      url: 'pages/StreamPage',
      params: {
        computerId: this.computerId,
        appId: app.id
      }
    });
  }
}
