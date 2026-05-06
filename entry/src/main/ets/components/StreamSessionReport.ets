/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2026 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * 串流结束战报
 *
 * 轻量分析本次串流统计，展示可爱的结论、改进建议，并生成可分享 PNG 卡片。
 */
import { componentSnapshot, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { systemShare } from '@kit.ShareKit';
import { ToastQueue } from '../utils/ToastQueue';
import { StreamConfig } from '../model/StreamConfig';

const COLOR_GOOD = '#FF8BC34A';
const COLOR_WARN = '#FFFFB74D';
const COLOR_BAD = '#FFFF7043';
const COLOR_ACCENT = '#FFA8D8EA';
const COLOR_GRADE_S = '#FFFFD166';
const COLOR_GRADE_C = '#FFFF8A80';

const SHARE_CARD_WIDTH = 390;
const SHARE_CARD_HEIGHT = 720;
const REPORT_MAX_WIDTH = 420;
const REPORT_DESIGN_HEIGHT_VP = 740;
const REPORT_SAFE_EDGE_VP = 20;
const REPORT_MIN_FIT_SCALE = 0.82;

export class StreamReportStats {
  fps: number = 0;
  renderedFps: number = 0;
  bitrate: number = 0;
  latency: number = 0;
  hostLatency: number = 0;
  networkLatency: number = 0;
  packetLoss: number = 0;
  decodedFrames: number = 0;
  droppedFrames: number = 0;
  globalAvgDecodeLatency: number = 0;
  globalAvgHostLatency: number = 0;
  globalAvgFps: number = 0;
  droppedByL1: number = 0;
  droppedByL2: number = 0;
  droppedByL3: number = 0;
  droppedByL4: number = 0;
  droppedByL5: number = 0;
}

export interface StreamReportMetric {
  label: string;
  value: string;
  hint: string;
  color: string;
  progress: number;
}

export interface StreamReportData {
  appName: string;
  title: string;
  subtitle: string;
  grade: string;
  gradeColor: string;
  score: number;
  conclusion: string;
  moodIcon: Resource;
  durationText: string;
  durationTease: string;
  metrics: StreamReportMetric[];
  suggestions: string[];
  configLine: string;
  generatedAt: string;
}

export function createEmptyStreamReport(): StreamReportData {
  return {
    appName: '远程游戏',
    title: '串流战报',
    subtitle: '正在整理数据…',
    grade: 'A',
    gradeColor: COLOR_ACCENT,
    score: 85,
    conclusion: '这局串流整体很稳，像小月光一样顺滑。',
    moodIcon: $r('app.media.report_moon_star'),
    durationText: '—',
    durationTease: '本次时长还在整理，别急嘛杂鱼♡',
    metrics: [],
    suggestions: ['保持当前设置，继续快乐串流。'],
    configLine: 'Moonlight V+',
    generatedAt: ''
  };
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function safeNumber(value: number | undefined, fallback: number = 0): number {
  if (value === undefined || value === null || isNaN(value)) return fallback;
  return value;
}

function formatMs(value: number, digits: number = 0): string {
  if (value <= 0) return '—';
  return `${value.toFixed(digits)}ms`;
}

function formatPercent(value: number, digits: number = 2): string {
  return `${Math.max(0, value).toFixed(digits)}%`;
}

function formatBitrateBps(bps: number): string {
  if (bps <= 0) return '—';
  const kbps = bps / 1000;
  if (kbps < 1000) return `${Math.round(kbps)}Kbps`;
  const mbps = kbps / 1000;
  return `${mbps >= 100 ? Math.round(mbps).toString() : mbps.toFixed(1)}Mbps`;
}

function formatConfigBitrate(kbps: number): string {
  if (kbps <= 0) return '自动';
  return formatBitrateBps(kbps * 1000);
}

function formatDuration(durationMs: number): string {
  if (durationMs <= 0) return '—';
  const totalSeconds = Math.max(1, Math.round(durationMs / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) {
    return `${hours}时${minutes.toString().padStart(2, '0')}分`;
  }
  if (minutes > 0) {
    return `${minutes}分${seconds.toString().padStart(2, '0')}秒`;
  }
  return `${seconds}秒`;
}

function buildDurationTease(durationMs: number, durationText: string): string {
  if (durationMs <= 0) return '本次时长没抓到，偷偷溜走的杂鱼局♡';
  const totalSeconds = Math.max(1, Math.round(durationMs / 1000));
  if (totalSeconds < 60) return `才 ${durationText} 就跑啦，杂鱼耐力条见底♡`;
  if (totalSeconds < 5 * 60) return `只玩 ${durationText}，热身都没热完就撤退啦♡`;
  if (totalSeconds < 30 * 60) return `认真玩了 ${durationText}，总算不像秒退杂鱼♡`;
  if (totalSeconds < 2 * 3600) return `玩了 ${durationText}，有点上头嘛，杂鱼♡`;
  if (totalSeconds < 4 * 3600) return `${durationText} 还不休息？沉迷警报响啦杂鱼♡`;
  return `${durationText}！快去喝水伸懒腰，别变成蔫掉杂鱼♡`;
}

function getNowText(): string {
  const now = new Date();
  const month = (now.getMonth() + 1).toString().padStart(2, '0');
  const day = now.getDate().toString().padStart(2, '0');
  const hour = now.getHours().toString().padStart(2, '0');
  const minute = now.getMinutes().toString().padStart(2, '0');
  return `${month}-${day} ${hour}:${minute}`;
}

function buildSuggestions(score: number, networkLatency: number, decodeLatency: number, hostLatency: number,
  packetLoss: number, fpsRatio: number, droppedFrames: number): string[] {
  const suggestions: string[] = [];

  if (packetLoss >= 2 || droppedFrames > 30) {
    suggestions.push('杂鱼网络在掉包啦♡ 先把码率降 15–25%，再换 5GHz / 有线 / 更近的 VPN 节点。');
  }
  if (networkLatency >= 60) {
    suggestions.push('RTT 这么高还想丝滑？杂鱼♡ VPN/异地网络优先选直连成功节点，少走中转弯路。');
  }
  if (decodeLatency >= 16) {
    suggestions.push('解码器都累趴啦，杂鱼画质党♡ 试试 H.264、降分辨率，或关掉 HDR/后处理。');
  }
  if (hostLatency >= 18) {
    suggestions.push('主机在偷偷摸鱼？检查 GPU 占用，降低服务端分辨率/帧率会更稳。');
  }
  if (fpsRatio > 0 && fpsRatio < 0.85) {
    suggestions.push('帧率追不上目标啦，杂鱼调参员♡ 降一点 FPS 或换更保守画质档。');
  }
  if (suggestions.length === 0) {
    if (score >= 90) {
      suggestions.push('哼，居然挺会调嘛♡ 当前配置可以保存成高质量档案。');
      suggestions.push('想继续逞强的话，可以小幅加码率，但丢包敢冒头就立刻降回去喔。');
    } else {
      suggestions.push('勉强算稳定啦，杂鱼♡ 保持当前网络环境，必要时只微调码率。');
    }
  }
  return suggestions.slice(0, 3);
}

class StreamReportGradeMeta {
  grade: string = 'S';
  gradeColor: string = COLOR_GRADE_S;
  title: string = '才、才不是杂鱼局';
  subtitle: string = '哼，这次居然挺丝滑嘛';
  conclusion: string = '这局串流表现很漂亮，延迟和帧率都很乖——勉强夸你一下，杂鱼♡';
  moodIcon: Resource = $r('app.media.report_moon_star');
}

function buildGradeMeta(score: number): StreamReportGradeMeta {
  const meta = new StreamReportGradeMeta();
  if (score < 60) {
    meta.grade = 'C';
    meta.gradeColor = COLOR_GRADE_C;
    meta.title = '杂鱼串流';
    meta.subtitle = '卡顿都写在脸上啦';
    meta.conclusion = '这局瓶颈很明显，网络或解码压力都炸了。快去调参啦，杂鱼♡';
    meta.moodIcon = $r('app.media.report_bandage_heart');
    return meta;
  }
  if (score < 75) {
    meta.grade = 'B';
    meta.gradeColor = COLOR_WARN;
    meta.title = '勉强能玩局';
    meta.subtitle = '杂鱼参数还要再拧拧';
    meta.conclusion = '整体可玩，但还有卡顿/延迟优化空间。照着建议调一下，不许偷懒喔♡';
    meta.moodIcon = $r('app.media.report_pudding');
    return meta;
  }
  if (score < 90) {
    meta.grade = 'A';
    meta.gradeColor = COLOR_ACCENT;
    meta.title = '杂鱼也能稳';
    meta.subtitle = '这局小月光挺争气';
    meta.conclusion = '本次串流整体稳定，偶发波动不太影响体验。继续优化画质或码率也不是不行啦♡';
    meta.moodIcon = $r('app.media.report_ribbon_star');
  }
  return meta;
}

function buildStreamReportMetrics(avgFps: number, targetFps: number, fpsRatio: number, networkLatency: number,
  decodeLatency: number, hostLatency: number, packetLoss: number, bitrateBps: number,
  config: StreamConfig | null | undefined): StreamReportMetric[] {
  const configuredBitrateBps = Math.max(0, config?.bitrate ?? 0) * 1000;
  const bitrateProgressBase = configuredBitrateBps > 0 ? configuredBitrateBps : bitrateBps;
  return [
    {
      label: '平均帧率',
      value: avgFps > 0 ? `${Math.round(avgFps)}fps` : '—',
      hint: targetFps > 0 ? `目标 ${targetFps}fps` : '渲染平均',
      color: fpsRatio >= 0.95 ? COLOR_GOOD : (fpsRatio >= 0.8 ? COLOR_WARN : COLOR_BAD),
      progress: clamp(fpsRatio * 100, 0, 100)
    },
    {
      label: '网络 RTT',
      value: formatMs(networkLatency, 0),
      hint: networkLatency < 30 ? '响应很快' : (networkLatency < 80 ? '可接受' : '偏高'),
      color: networkLatency < 30 ? COLOR_GOOD : (networkLatency < 80 ? COLOR_WARN : COLOR_BAD),
      progress: clamp(100 - networkLatency, 8, 100)
    },
    {
      label: '解码延迟',
      value: formatMs(decodeLatency, 1),
      hint: decodeLatency < 10 ? '很轻松' : (decodeLatency < 16 ? '正常' : '压力偏高'),
      color: decodeLatency < 10 ? COLOR_GOOD : (decodeLatency < 16 ? COLOR_WARN : COLOR_BAD),
      progress: clamp(100 - decodeLatency * 4, 8, 100)
    },
    {
      label: '主机延迟',
      value: formatMs(hostLatency, 1),
      hint: hostLatency < 12 ? '编码顺滑' : (hostLatency < 20 ? '正常' : '主机忙碌'),
      color: hostLatency < 12 ? COLOR_GOOD : (hostLatency < 20 ? COLOR_WARN : COLOR_BAD),
      progress: clamp(100 - hostLatency * 3.5, 8, 100)
    },
    {
      label: '丢包率',
      value: formatPercent(packetLoss, 2),
      hint: packetLoss < 0.5 ? '很干净' : (packetLoss < 2 ? '轻微波动' : '需要关注'),
      color: packetLoss < 0.5 ? COLOR_GOOD : (packetLoss < 2 ? COLOR_WARN : COLOR_BAD),
      progress: clamp(100 - packetLoss * 18, 8, 100)
    },
    {
      label: '视频码率',
      value: formatBitrateBps(bitrateBps),
      hint: config?.bitrate ? `配置 ${formatConfigBitrate(config.bitrate)}` : '实时估算',
      color: COLOR_ACCENT,
      progress: clamp((bitrateBps / Math.max(1, bitrateProgressBase)) * 100, 8, 100)
    }
  ];
}

export function buildStreamReportData(stats: StreamReportStats, config: StreamConfig | null | undefined,
  appName: string, durationMs: number = 0): StreamReportData {
  const targetFps = config?.fps ?? 0;
  const avgFps = safeNumber(stats.globalAvgFps, 0) > 0 ? stats.globalAvgFps : safeNumber(stats.renderedFps, 0);
  const decodeLatency = safeNumber(stats.globalAvgDecodeLatency, 0) > 0 ? stats.globalAvgDecodeLatency : safeNumber(stats.latency, 0);
  const hostLatency = safeNumber(stats.globalAvgHostLatency, 0) > 0 ? stats.globalAvgHostLatency : safeNumber(stats.hostLatency, 0);
  const networkLatency = safeNumber(stats.networkLatency, 0);
  const packetLoss = safeNumber(stats.packetLoss, 0);
  const droppedFrames = safeNumber(stats.droppedFrames, 0);
  const decodedFrames = safeNumber(stats.decodedFrames, 0);
  // native 运行时统计是 bps；StreamConfig.bitrate 是 Kbps。战报统一转换成 bps 再展示/计算。
  const bitrateBps = safeNumber(stats.bitrate, 0) > 0 ? stats.bitrate : (Math.max(0, config?.bitrate ?? 0) * 1000);
  const fpsRatio = targetFps > 0 && avgFps > 0 ? avgFps / targetFps : 1;
  const dropRatio = decodedFrames > 0 ? droppedFrames / Math.max(1, decodedFrames + droppedFrames) : 0;

  let score = 100;
  score -= clamp((networkLatency - 25) * 0.55, 0, 22);
  score -= clamp(packetLoss * 8, 0, 28);
  score -= clamp((decodeLatency - 10) * 1.2, 0, 18);
  score -= clamp((hostLatency - 12) * 0.9, 0, 16);
  score -= clamp((1 - clamp(fpsRatio, 0, 1)) * 24, 0, 24);
  score -= clamp(dropRatio * 100, 0, 15);
  score = Math.round(clamp(score, 0, 100));

  const gradeMeta = buildGradeMeta(score);
  const metrics = buildStreamReportMetrics(avgFps, targetFps, fpsRatio, networkLatency, decodeLatency, hostLatency,
    packetLoss, bitrateBps, config);

  const resolution = config ? `${config.width}×${config.height}@${config.fps}` : 'Moonlight V+';
  const codec = config?.codec ?? 'Auto';
  const hdr = config?.hdr ? 'HDR' : 'SDR';
  const durationText = formatDuration(durationMs);

  return {
    appName: appName || '远程游戏',
    title: gradeMeta.title,
    subtitle: gradeMeta.subtitle,
    grade: gradeMeta.grade,
    gradeColor: gradeMeta.gradeColor,
    score,
    conclusion: gradeMeta.conclusion,
    moodIcon: gradeMeta.moodIcon,
    durationText,
    durationTease: buildDurationTease(durationMs, durationText),
    metrics,
    suggestions: buildSuggestions(score, networkLatency, decodeLatency, hostLatency, packetLoss, fpsRatio, droppedFrames),
    configLine: `${resolution} · ${codec} · ${hdr}`,
    generatedAt: getNowText()
  };
}

@Component
export struct StreamSessionReport {
  @Prop data: StreamReportData = createEmptyStreamReport();
  onClose?: () => void;

  @State private overlayOpacity: number = 0;
  @State private cardScale: number = 0.92;
  @State private cardOffsetY: number = 28;
  @State private mascotBounce: number = 0;
  @State private metricReveal: number = 0;
  @State private sparkleSpin: number = 0;
  @State private heartScale: number = 1;
  @State private sparkleDrift: number = 0;
  @State private fitScale: number = 1;
  @State private isSharing: boolean = false;

  aboutToAppear(): void {
    this.fitScale = this.calculateFitScale();
    this.metricReveal = 0;
    this.sparkleSpin = 0;
    this.heartScale = 1;
    this.sparkleDrift = 0;
    setTimeout(() => {
      animateTo({ duration: 360, curve: Curve.FastOutSlowIn }, () => {
        this.overlayOpacity = 1;
        this.cardScale = 1;
        this.cardOffsetY = 0;
      });
    }, 30);
    setTimeout(() => {
      animateTo({ duration: 920, curve: Curve.FastOutSlowIn }, () => {
        this.metricReveal = 1;
      });
    }, 260);
    setTimeout(() => {
      animateTo({ duration: 900, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate }, () => {
        this.mascotBounce = -8;
      });
    }, 420);
    setTimeout(() => {
      animateTo({ duration: 1100, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate }, () => {
        this.sparkleSpin = 12;
        this.heartScale = 1.18;
        this.sparkleDrift = -10;
      });
    }, 520);
  }

  private calculateFitScale(): number {
    try {
      const info = display.getDefaultDisplaySync();
      const heightVp = Math.min(info.width, info.height) / info.densityPixels;
      // 大屏尽量完整展示，小屏保留可读性；溢出内容交给容器内滚动兜底。
      return clamp((heightVp - REPORT_SAFE_EDGE_VP) / REPORT_DESIGN_HEIGHT_VP, REPORT_MIN_FIT_SCALE, 1);
    } catch (_) {
      return 1;
    }
  }

  private async shareReportImage(): Promise<void> {
    if (this.isSharing) return;
    this.isSharing = true;
    try {
      this.metricReveal = 1;
      ToastQueue.show({ message: '正在生成分享图片…', duration: 1200 });
      const context = getContext(this) as common.UIAbilityContext;
      const cardPixelMap = await componentSnapshot.createFromBuilder((): void => {
        this.ShareCardBuilder(this.data);
      }, 300, true);

      const tempPath = `${context.tempDir}/moonlight_stream_report_${Date.now()}.png`;
      const packer = image.createImagePacker();
      const buffer = await packer.packing(cardPixelMap, { format: 'image/png', quality: 100 });
      packer.release();
      cardPixelMap.release();

      const file = fileIo.openSync(tempPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, buffer);
      fileIo.closeSync(file.fd);

      const shareData = new systemShare.SharedData({
        utd: 'general.png',
        uri: fileUri.getUriFromPath(tempPath),
        title: `Moonlight 杂鱼串流战报 · ${this.data.appName}`,
        description: `${this.data.grade} 级体验 · ${this.data.score} 分 · ${this.data.durationTease}`
      });

      const controller = new systemShare.ShareController(shareData);
      await controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT
      });
    } catch (err) {
      console.error('[StreamSessionReport] 分享战报失败:', JSON.stringify(err));
      ToastQueue.show({ message: '分享图片生成失败', duration: 1600 });
    } finally {
      this.isSharing = false;
    }
  }

  @Builder
  MetricRow(metric: StreamReportMetric, snapshotMode: boolean) {
    Column({ space: 5 }) {
      Row() {
        Text(metric.label)
          .fontSize(12)
          .fontColor('#B8FFFFFF')
        Blank()
        Text(metric.value)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(metric.color)
      }
      .width('100%')

      Stack({ alignContent: Alignment.Start }) {
        Column()
          .width('100%')
          .height(7)
          .borderRadius(4)
          .backgroundColor('#22FFFFFF')
        Column()
          .width(`${clamp(metric.progress * (snapshotMode ? 1 : this.metricReveal), 0, 100)}%`)
          .height(7)
          .borderRadius(4)
          .backgroundColor(metric.color)
      }
      .width('100%')
      .height(7)

      Text(metric.hint)
        .fontSize(10)
        .fontColor('#70FFFFFF')
        .alignSelf(ItemAlign.Start)
    }
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(14)
    .backgroundColor('#18FFFFFF')
    .border({ width: 1, color: '#12FFFFFF' })
  }

  @Builder
  SuggestionLine(text: string) {
    Row({ space: 8 }) {
      Text('✦')
        .fontSize(12)
        .fontColor('#FFA8D8EA')
      Text(text)
        .fontSize(12)
        .fontColor('#D8FFFFFF')
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  ReportFooter(data: StreamReportData, showIcon: boolean, fontSize: number, fontColor: string) {
    Row({ space: 8 }) {
      if (showIcon) {
        Image($r('app.media.report_moon_star'))
          .width(18)
          .height(18)
          .fillColor('#B8FFFFFF')
      }
      Text('Moonlight V+ · 杂鱼串流战报')
        .fontSize(fontSize)
        .fontColor(fontColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Blank()
      Text(data.generatedAt)
        .fontSize(fontSize)
        .fontColor(fontColor)
        .maxLines(1)
    }
    .width('100%')
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#DD050816')
        .backdropBlur(40)

      Scroll() {
        Column({ space: 8 }) {
          this.ReportCard(false)

          Column() {
            this.ReportFooter(this.data, false, 10, '#70FFFFFF')
          }
          .width('88%')
          .constraintSize({ maxWidth: REPORT_MAX_WIDTH })
          .padding({ left: 2, right: 2 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 16, bottom: 18 })
      }
      .width('100%')
      .height('100%')
      .scrollable(ScrollDirection.Vertical)
      .edgeEffect(EdgeEffect.Spring)
      .clip(true)
      .scale({ x: this.cardScale * this.fitScale, y: this.cardScale * this.fitScale })
      .translate({ y: this.cardOffsetY })
      .opacity(this.overlayOpacity)
    }
    .width('100%')
    .height('100%')
    .opacity(this.overlayOpacity)
    .transition(TransitionEffect.OPACITY.animation({ duration: 260 }))
  }

  @Builder
  ReportCard(snapshotMode: boolean) {
    Stack() {
      // 背景光晕
      Circle()
        .width(240)
        .height(240)
        .fill('#00000000')
        .radialGradient({
          center: [120, 120],
          radius: 120,
          colors: [['#22A8D8EA', 0], ['#00A8D8EA', 1]]
        })
        .position({ right: -72, top: -70 })

      Circle()
        .width(180)
        .height(180)
        .fill('#00000000')
        .radialGradient({
          center: [90, 90],
          radius: 90,
          colors: [['#20D7A574', 0], ['#00D7A574', 1]]
        })
        .position({ left: -60, bottom: -58 })

      Text('♡')
        .fontSize(30)
        .fontColor('#66FFD1DC')
        .scale({ x: snapshotMode ? 1 : this.heartScale, y: snapshotMode ? 1 : this.heartScale })
        .rotate({ angle: snapshotMode ? -8 : -8 + this.sparkleSpin })
        .translate({ y: snapshotMode ? 0 : this.sparkleDrift })
        .position({ right: 30, top: 34 })

      Text('✦')
        .fontSize(22)
        .fontColor('#88A8D8EA')
        .rotate({ angle: snapshotMode ? 10 : 10 - this.sparkleSpin })
        .translate({ y: snapshotMode ? 0 : -this.sparkleDrift })
        .position({ left: 34, top: 72 })

      Text('杂鱼♡')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor('#88FFD1DC')
        .scale({ x: snapshotMode ? 1 : this.heartScale, y: snapshotMode ? 1 : this.heartScale })
        .position({ right: 62, top: 72 })

      Column({ space: 12 }) {
        Row({ space: 12 }) {
          Stack() {
            Circle()
              .width(42)
              .height(42)
              .fill('#20FFFFFF')
            Image(this.data.moodIcon)
              .width(30)
              .height(30)
              .fillColor(this.data.gradeColor)
              .translate({ y: snapshotMode ? 0 : this.mascotBounce })
          }
          .width(58)
          .height(58)
          .borderRadius(20)
          .backgroundColor('#22FFFFFF')
          .border({ width: 1, color: '#20FFFFFF' })
          .alignContent(Alignment.Center)

          Column({ space: 4 }) {
            Text(this.data.title)
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFFFF')
            Text(this.data.subtitle)
              .fontSize(12)
              .fontColor('#A8FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.data.appName)
              .fontSize(11)
              .fontColor('#80FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Column({ space: 2 }) {
            Text(this.data.grade)
              .fontSize(34)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.data.gradeColor)
            Text(`${this.data.score}`)
              .fontSize(12)
              .fontColor('#A8FFFFFF')
          }
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')

        Column({ space: 6 }) {
          Row() {
            Text('整体评分')
              .fontSize(11)
              .fontColor('#90FFFFFF')
            Blank()
            Text(`${this.data.score}/100`)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.data.gradeColor)
          }
          .width('100%')

          Stack({ alignContent: Alignment.Start }) {
            Column()
              .width('100%')
              .height(8)
              .borderRadius(5)
              .backgroundColor('#22FFFFFF')
            Column()
              .width(`${clamp(this.data.score * (snapshotMode ? 1 : this.metricReveal), 0, 100)}%`)
              .height(8)
              .borderRadius(5)
              .backgroundColor(this.data.gradeColor)
          }
          .width('100%')
          .height(8)
        }
        .width('100%')

        Column({ space: 8 }) {
          Text(this.data.conclusion)
            .fontSize(13)
            .fontColor('#E8FFFFFF')
            .lineHeight(20)
            .width('100%')
          Text(`${this.data.durationTease} · ${this.data.configLine}`)
            .fontSize(11)
            .fontColor('#80FFFFFF')
            .width('100%')
        }
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .borderRadius(16)
        .backgroundColor('#18FFFFFF')
        .border({ width: 1, color: '#12FFFFFF' })

        if (this.data.metrics.length >= 6) {
          Column({ space: 10 }) {
            Row({ space: 10 }) {
              Column() {
                this.MetricRow(this.data.metrics[0], snapshotMode)
              }
              .layoutWeight(1)
              Column() {
                this.MetricRow(this.data.metrics[1], snapshotMode)
              }
              .layoutWeight(1)
            }
            .width('100%')

            Row({ space: 10 }) {
              Column() {
                this.MetricRow(this.data.metrics[2], snapshotMode)
              }
              .layoutWeight(1)
              Column() {
                this.MetricRow(this.data.metrics[3], snapshotMode)
              }
              .layoutWeight(1)
            }
            .width('100%')

            Row({ space: 10 }) {
              Column() {
                this.MetricRow(this.data.metrics[4], snapshotMode)
              }
              .layoutWeight(1)
              Column() {
                this.MetricRow(this.data.metrics[5], snapshotMode)
              }
              .layoutWeight(1)
            }
            .width('100%')
          }
          .width('100%')
        }

        Column({ space: 8 }) {
          Text('调教建议')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFFFF')
            .width('100%')
          ForEach(this.data.suggestions, (item: string) => {
            this.SuggestionLine(item)
          }, (item: string) => item)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .borderRadius(16)
        .backgroundColor('#16A8D8EA')
        .border({ width: 1, color: '#24A8D8EA' })

        if (!snapshotMode) {
          Row({ space: 8 }) {
            Button() {
              Text('分享杂鱼战报♡')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Center)
                .width('100%')
            }
            .layoutWeight(1)
            .constraintSize({ minWidth: 0 })
            .height(40)
            .borderRadius(22)
            .fontColor('#FF101828')
            .backgroundColor('#FFA8D8EA')
            .clip(true)
            .enabled(!this.isSharing)
            .onClick(() => {
              this.shareReportImage();
            })

            Button() {
              Text('知道啦，返回')
                .fontSize(13)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Center)
                .width('100%')
            }
              .layoutWeight(1)
              .constraintSize({ minWidth: 0 })
              .height(40)
              .borderRadius(22)
              .fontColor('#E8FFFFFF')
              .backgroundColor('#22FFFFFF')
              .clip(true)
              .onClick(() => {
                if (this.onClose) this.onClose();
              })
          }
          .width('100%')
          .clip(true)
        }

      }
      .width(snapshotMode ? 360 : '88%')
      .constraintSize({ maxWidth: REPORT_MAX_WIDTH })
      .padding({ left: 18, right: 18, top: 16, bottom: 14 })
      .borderRadius(28)
      .linearGradient({
        angle: 135,
        colors: [['#FF111827', 0], ['#FF18213A', 0.42], ['#FF271A36', 0.78], ['#FF15111E', 1]]
      })
      .border({ width: 1, color: '#22FFFFFF' })
      .shadow({ radius: snapshotMode ? 0 : 26, color: '#80000000', offsetY: 10 })
      .clip(true)
    }
    .width(snapshotMode ? SHARE_CARD_WIDTH : '100%')
    .constraintSize({ minHeight: snapshotMode ? SHARE_CARD_HEIGHT : 0 })
    .alignContent(Alignment.Center)
  }

  @Builder
  ShareCardBuilder(data: StreamReportData) {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 135,
          colors: [['#FF07111F', 0], ['#FF10233E', 0.36], ['#FF24153A', 0.7], ['#FF0F111E', 1]]
        })

      this.ReportCard(true)

      Column() {
        this.ReportFooter(data, true, 11, '#B8FFFFFF')
      }
      .width(SHARE_CARD_WIDTH - 44)
      .position({ left: 22, bottom: 18 })
    }
    .width(SHARE_CARD_WIDTH)
    .height(SHARE_CARD_HEIGHT)
  }
}
