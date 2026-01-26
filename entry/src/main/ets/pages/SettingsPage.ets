import { router } from '@kit.ArkUI';
import { PreferencesUtil } from '../utils/PreferencesUtil';

@Entry
@Component
struct SettingsPage {
  @State resolution: string = '1080p';
  @State fps: number = 60;
  @State bitrate: number = 20;
  @State codec: string = 'HEVC';
  @State hdrEnabled: boolean = false;
  @State audioEnabled: boolean = true;
  @State micEnabled: boolean = false;
  @State vibrationEnabled: boolean = true;
  @State showPerformanceOverlay: boolean = true;

  private resolutionOptions: string[] = ['720p', '1080p', '1440p', '4K'];
  private fpsOptions: number[] = [30, 60, 90, 120, 144];
  private codecOptions: string[] = ['H.264', 'HEVC', 'AV1'];

  aboutToAppear(): void {
    this.loadSettings();
  }

  async loadSettings(): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(getContext(this));
    this.resolution = await prefs.get('resolution', '1080p') as string;
    this.fps = await prefs.get('fps', 60) as number;
    this.bitrate = await prefs.get('bitrate', 20) as number;
    this.codec = await prefs.get('codec', 'HEVC') as string;
    this.hdrEnabled = await prefs.get('hdrEnabled', false) as boolean;
    this.audioEnabled = await prefs.get('audioEnabled', true) as boolean;
    this.micEnabled = await prefs.get('micEnabled', false) as boolean;
    this.vibrationEnabled = await prefs.get('vibrationEnabled', true) as boolean;
    this.showPerformanceOverlay = await prefs.get('showPerformanceOverlay', true) as boolean;
  }

  async saveSetting(key: string, value: string | number | boolean): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(getContext(this));
    await prefs.put(key, value);
    await prefs.flush();
  }

  build() {
    Column() {
      // 标题栏
      this.TitleBar()

      // 设置列表
      Scroll() {
        Column() {
          // 视频设置
          this.SectionHeader('视频设置')
          this.ResolutionSetting()
          this.FpsSetting()
          this.BitrateSetting()
          this.CodecSetting()
          this.HdrSetting()

          // 音频设置
          this.SectionHeader('音频设置')
          this.AudioSetting()
          this.MicSetting()

          // 输入设置
          this.SectionHeader('输入设置')
          this.VibrationSetting()

          // 显示设置
          this.SectionHeader('显示设置')
          this.OverlaySetting()

          // 关于
          this.SectionHeader('关于')
          this.AboutSection()
        }
        .padding({ left: 16, right: 16, bottom: 32 })
      }
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

      Text($r('app.string.settings_title'))
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

  @Builder
  SectionHeader(title: string) {
    Text(title)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.primary'))
      .width('100%')
      .margin({ top: 24, bottom: 8 })
  }

  @Builder
  SettingRow(title: string, content: () => void) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))

      Blank()

      content()
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(12)
    .margin({ top: 8 })
  }

  @Builder
  ResolutionSetting() {
    this.SettingRow('分辨率', () => {
      Select(this.resolutionOptions.map(r => ({ value: r })))
        .value(this.resolution)
        .font({ size: 14 })
        .fontColor($r('app.color.text_secondary'))
        .onSelect((index) => {
          this.resolution = this.resolutionOptions[index];
          this.saveSetting('resolution', this.resolution);
        })
    })
  }

  @Builder
  FpsSetting() {
    this.SettingRow('帧率', () => {
      Select(this.fpsOptions.map(f => ({ value: `${f} FPS` })))
        .value(`${this.fps} FPS`)
        .font({ size: 14 })
        .fontColor($r('app.color.text_secondary'))
        .onSelect((index) => {
          this.fps = this.fpsOptions[index];
          this.saveSetting('fps', this.fps);
        })
    })
  }

  @Builder
  BitrateSetting() {
    Row() {
      Text('码率')
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))

      Blank()

      Text(`${this.bitrate} Mbps`)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16 })
    .backgroundColor($r('app.color.card_background'))
    .borderRadius({ topLeft: 12, topRight: 12 })
    .margin({ top: 8 })

    Slider({
      value: this.bitrate,
      min: 1,
      max: 150,
      step: 1
    })
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
      .backgroundColor($r('app.color.card_background'))
      .borderRadius({ bottomLeft: 12, bottomRight: 12 })
      .onChange((value) => {
        this.bitrate = Math.round(value);
        this.saveSetting('bitrate', this.bitrate);
      })
  }

  @Builder
  CodecSetting() {
    this.SettingRow('编解码器', () => {
      Select(this.codecOptions.map(c => ({ value: c })))
        .value(this.codec)
        .font({ size: 14 })
        .fontColor($r('app.color.text_secondary'))
        .onSelect((index) => {
          this.codec = this.codecOptions[index];
          this.saveSetting('codec', this.codec);
        })
    })
  }

  @Builder
  HdrSetting() {
    this.SettingRow('HDR', () => {
      Toggle({ type: ToggleType.Switch, isOn: this.hdrEnabled })
        .onChange((isOn) => {
          this.hdrEnabled = isOn;
          this.saveSetting('hdrEnabled', this.hdrEnabled);
        })
    })
  }

  @Builder
  AudioSetting() {
    this.SettingRow('音频', () => {
      Toggle({ type: ToggleType.Switch, isOn: this.audioEnabled })
        .onChange((isOn) => {
          this.audioEnabled = isOn;
          this.saveSetting('audioEnabled', this.audioEnabled);
        })
    })
  }

  @Builder
  MicSetting() {
    this.SettingRow('麦克风重定向', () => {
      Toggle({ type: ToggleType.Switch, isOn: this.micEnabled })
        .onChange((isOn) => {
          this.micEnabled = isOn;
          this.saveSetting('micEnabled', this.micEnabled);
        })
    })
  }

  @Builder
  VibrationSetting() {
    this.SettingRow('震动反馈', () => {
      Toggle({ type: ToggleType.Switch, isOn: this.vibrationEnabled })
        .onChange((isOn) => {
          this.vibrationEnabled = isOn;
          this.saveSetting('vibrationEnabled', this.vibrationEnabled);
        })
    })
  }

  @Builder
  OverlaySetting() {
    this.SettingRow('性能监控', () => {
      Toggle({ type: ToggleType.Switch, isOn: this.showPerformanceOverlay })
        .onChange((isOn) => {
          this.showPerformanceOverlay = isOn;
          this.saveSetting('showPerformanceOverlay', this.showPerformanceOverlay);
        })
    })
  }

  @Builder
  AboutSection() {
    Column() {
      Row() {
        Text('版本')
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('1.0.0')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .height(48)

      Divider().color($r('app.color.background'))

      Row() {
        Text('基于 Moonlight')
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('GPL v3')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .height(48)
    }
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(12)
    .margin({ top: 8 })
  }
}
