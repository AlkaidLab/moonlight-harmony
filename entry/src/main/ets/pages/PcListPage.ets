import { router } from '@kit.ArkUI';
import { ComputerInfo, ComputerState } from '../model/ComputerInfo';
import { ComputerManager } from '../service/ComputerManager';
import { ComputerCard } from '../components/ComputerCard';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct PcListPage {
  @State computers: ComputerInfo[] = [];
  @State isRefreshing: boolean = false;
  @State isScanning: boolean = false;
  private computerManager: ComputerManager = ComputerManager.getInstance();

  aboutToAppear(): void {
    // 初始化 ComputerManager，传入 Context
    const context = getContext(this) as common.UIAbilityContext;
    this.computerManager.init(context);

    // 设置电脑列表变化监听
    this.computerManager.setOnComputerListChangedListener(() => {
      this.loadComputers();
    });

    this.loadComputers();

    // 启动后台 mDNS 扫描
    this.computerManager.startBackgroundScan();
  }

  aboutToDisappear(): void {
    // 停止后台扫描
    this.computerManager.stopBackgroundScan();
  }

  async loadComputers(): Promise<void> {
    this.computers = await this.computerManager.getComputers();
  }

  async refreshComputers(): Promise<void> {
    this.isRefreshing = true;
    await this.computerManager.refreshAllComputers();
    await this.loadComputers();
    this.isRefreshing = false;
  }

  async scanNetwork(): Promise<void> {
    this.isScanning = true;
    await this.computerManager.scanNetwork();
    await this.loadComputers();
    this.isScanning = false;
  }

  build() {
    Column() {
      // 标题栏
      this.TitleBar()

      // 电脑列表
      if (this.computers.length === 0) {
        this.EmptyState()
      } else {
        this.ComputerList()
      }

      // 底部操作栏
      this.BottomBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
  }

  @Builder
  TitleBar() {
    Row() {
      Text($r('app.string.pc_list_title'))
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      Blank()

      // 设置按钮
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ic_settings'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        router.pushUrl({ url: 'pages/SettingsPage' });
      })
    }
    .width('100%')
    .padding({
      left: 16,
      right: 16,
      top: 48,
      bottom: 16
    })
  }

  @Builder
  ComputerList() {
    Refresh({ refreshing: $$this.isRefreshing }) {
      List({ space: 12 }) {
        ForEach(this.computers, (computer: ComputerInfo) => {
          ListItem() {
            ComputerCard({
              computer: computer,
              onTap: () => {
                if (computer.state === ComputerState.ONLINE) {
                  router.pushUrl({
                    url: 'pages/AppListPage',
                    params: { computerId: computer.uuid }
                  });
                }
              },
              onLongPress: () => {
                this.showComputerMenu(computer);
              }
            })
          }
        }, (computer: ComputerInfo) => computer.uuid)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
      .scrollBar(BarState.Off)
    }
    .onRefreshing(() => {
      this.refreshComputers();
    })
  }

  @Builder
  EmptyState() {
    Column() {
      Image($r('app.media.ic_computer'))
        .width(100)
        .height(100)
        .fillColor($r('app.color.text_secondary'))
        .opacity(0.5)
        .margin({ bottom: 24 })

      Text('没有发现电脑')
        .fontSize(18)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 8 })

      Text('请确保您的电脑已安装 Sunshine 或 GeForce Experience')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .opacity(0.7)
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  BottomBar() {
    Row() {
      // 扫描网络按钮
      Button({ type: ButtonType.Normal }) {
        Row() {
          if (this.isScanning) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color(Color.White)
              .margin({ right: 8 })
          } else {
            Image($r('app.media.ic_scan'))
              .width(20)
              .height(20)
              .fillColor(Color.White)
              .margin({ right: 8 })
          }
          Text(this.isScanning ? '扫描中...' : $r('app.string.scan_network'))
            .fontSize(16)
            .fontColor(Color.White)
        }
      }
      .width('45%')
      .height(48)
      .borderRadius(12)
      .backgroundColor($r('app.color.primary'))
      .enabled(!this.isScanning)
      .onClick(() => {
        this.scanNetwork();
      })

      // 手动添加按钮
      Button({ type: ButtonType.Normal }) {
        Row() {
          Image($r('app.media.ic_add'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.primary'))
            .margin({ right: 8 })
          Text($r('app.string.add_manually'))
            .fontSize(16)
            .fontColor($r('app.color.primary'))
        }
      }
      .width('45%')
      .height(48)
      .borderRadius(12)
      .backgroundColor(Color.Transparent)
      .borderWidth(1)
      .borderColor($r('app.color.primary'))
      .onClick(() => {
        router.pushUrl({ url: 'pages/AddPcPage' });
      })
    }
    .width('100%')
    .padding(16)
    .justifyContent(FlexAlign.SpaceBetween)
  }

  showComputerMenu(computer: ComputerInfo): void {
    // TODO: 显示电脑操作菜单（配对、唤醒、删除等）
  }
}
