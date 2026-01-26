import { router } from '@kit.ArkUI';
import { ComputerManager } from '../service/ComputerManager';

@Entry
@Component
struct AddPcPage {
  @State ipAddress: string = '';
  @State isAdding: boolean = false;
  @State errorMessage: string = '';
  private computerManager: ComputerManager = ComputerManager.getInstance();

  build() {
    Column() {
      // 标题栏
      this.TitleBar()

      // 内容
      Column() {
        // 说明文字
        Text('请输入运行 Sunshine 或 GeForce Experience 的电脑 IP 地址')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16 })
          .margin({ bottom: 32 })

        // IP 输入框
        TextInput({ placeholder: '例如: 192.168.1.100', text: this.ipAddress })
          .type(InputType.Normal)
          .width('100%')
          .height(56)
          .fontSize(18)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(12)
          .padding({ left: 16, right: 16 })
          .onChange((value) => {
            this.ipAddress = value;
            this.errorMessage = '';
          })

        // 错误提示
        if (this.errorMessage) {
          Text(this.errorMessage)
            .fontSize(14)
            .fontColor($r('app.color.error_red'))
            .margin({ top: 8 })
        }

        // 添加按钮
        Button({ type: ButtonType.Normal }) {
          if (this.isAdding) {
            LoadingProgress()
              .width(24)
              .height(24)
              .color(Color.White)
          } else {
            Text('添加电脑')
              .fontSize(16)
              .fontColor(Color.White)
          }
        }
        .width('100%')
        .height(52)
        .borderRadius(12)
        .backgroundColor($r('app.color.primary'))
        .margin({ top: 24 })
        .enabled(!this.isAdding && this.ipAddress.length > 0)
        .onClick(() => {
          this.addComputer();
        })

        // 提示
        Column() {
          Text('提示:')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .margin({ bottom: 8 })

          Text('1. 确保电脑和手机在同一网络下')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: 4 })

          Text('2. 电脑需要安装并运行 Sunshine 或 GeForce Experience')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: 4 })

          Text('3. 首次连接需要在电脑上确认配对')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(12)
        .margin({ top: 32 })
      }
      .padding({ left: 16, right: 16 })
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
  }

  @Builder
  TitleBar() {
    Row() {
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

      Text($r('app.string.add_pc_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 8 })

      Blank()
    }
    .width('100%')
    .padding({
      left: 8,
      right: 16,
      top: 48,
      bottom: 16
    })
  }

  async addComputer(): Promise<void> {
    if (!this.validateIpAddress(this.ipAddress)) {
      this.errorMessage = '请输入有效的 IP 地址';
      return;
    }

    this.isAdding = true;
    this.errorMessage = '';

    try {
      await this.computerManager.addComputer(this.ipAddress);
      router.back();
    } catch (err) {
      this.errorMessage = `添加失败: ${err}`;
    } finally {
      this.isAdding = false;
    }
  }

  validateIpAddress(ip: string): boolean {
    const ipRegex = /^(\d{1,3}\.){3}\d{1,3}$/;
    if (!ipRegex.test(ip)) {
      return false;
    }
    const parts = ip.split('.');
    return parts.every(part => {
      const num = parseInt(part);
      return num >= 0 && num <= 255;
    });
  }
}
