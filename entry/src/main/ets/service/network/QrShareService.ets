/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * 二维码分享服务
 *
 * 将自定义按键配置序列化为紧凑 JSON，通过 QR 码分享。
 * 使用 @kit.ScanKit 生成二维码和扫码导入。
 *
 * v2 格式：动作编码为短字符串（K65 代替 {"type":"keyboard","vk":65}），
 * 复合动作用 | 和 : 分隔。总体积减少 70-90%（特别是轮盘/数字摇杆等嵌套类型）。
 *
 * 向后兼容 v1 格式（动作直接存储为 JSON 对象）。
 */

import { scanCore, scanBarcode, generateBarcode } from '@kit.ScanKit';
import { image } from '@kit.ImageKit';
import { zlib } from '@kit.BasicServicesKit';
import { buffer, util } from '@kit.ArkTS';
import { generateQrPixelMap, ECLevel } from './QrCodeGenerator';
import {
  CustomKeyDef,
  KeyAction,
  KeyShape,
  KeyBehavior,
  KeyboardAction,
  MouseButtonAction,
  MouseScrollAction,
  GamepadButtonAction,
  GamepadTriggerAction,
  GamepadStickAction,
  AnalogStickAction,
  DPadAction,
  WheelPadAction,
  WheelPadSegment,
  DigitalStickAction,
  ComboAction,
  ShortcutAction,
  SpecialAction,
  SpecialActionId,
  generateKeyId,
} from '../customkey/CustomKeyTypes';

export interface QrCodeResult {
  pixelMap: image.PixelMap | null;
  error?: string;
}

// =============================================================================
// 紧凑格式类型定义
// =============================================================================

/** v2 紧凑按键定义 — 动作编码为字符串 */
interface CompactKeyV2 {
  l: string;       // label
  a: string;       // action (v2 encoded string)
  s: string;       // shape: 'r' | 'c' | 'h' (hexagon)
  b: string;       // behavior: 'm' | 't'
  x: number;       // xPercent
  y: number;       // yPercent
  w: number;       // width
  h: number;       // height
  // ── 可选：仅在非默认值时序列化 ──
  o?: number;      // opacity (default=80)
  r?: number;      // borderRadius (default=12)
  bg?: string;     // bgColor
  tc?: string;     // textColor
  pc?: string;     // pressedColor
  fs?: number;     // fontSize (default=14)
  ly?: number;     // layer (default=0)
  bw?: number;     // borderWidth (default=1)
  hp?: string;     // haptic (default='light')
  gid?: string;    // groupId
}

/** 紧凑导出包 */
interface CompactExportV2 {
  v: number;       // version (2)
  n: string;       // profile name
  k: CompactKeyV2[]; // keys
}

/** QR 码最大推荐字符数（留余量） */
const QR_MAX_CHARS = 4000;

/** 压缩数据前缀 — Moonlight Compressed */
const COMPRESSED_PREFIX = 'MLC:';

// =============================================================================
// zlib 压缩 / 解压
// =============================================================================

/**
 * 压缩 JSON 字符串 → base64 字符串（带 MLC: 前缀）
 * 压缩率约 50-70%，使 QR 码版本大幅降低
 */
async function compressToBase64(json: string): Promise<string> {
  const encoder = new util.TextEncoder();
  const encResult = encoder.encodeInto(json);
  const sourceBuffer = encResult.buffer as ArrayBuffer;

  // 目标缓冲区：压缩数据通常不会比原始数据大
  const destBuffer = new ArrayBuffer(sourceBuffer.byteLength + 128);
  const zip = zlib.createZipSync();
  const result = await zip.compress2(destBuffer, sourceBuffer,
    zlib.CompressLevel.COMPRESS_LEVEL_BEST_COMPRESSION);

  // 只取实际压缩后的有效数据
  const compressedBytes = new Uint8Array(destBuffer, 0, result.destLen);
  const buf = buffer.from(compressedBytes);
  return COMPRESSED_PREFIX + buf.toString('base64');
}

/**
 * 解压 base64 字符串（带 MLC: 前缀）→ JSON 字符串
 */
async function decompressFromBase64(data: string): Promise<string> {
  const b64 = data.substring(COMPRESSED_PREFIX.length);
  const buf = buffer.from(b64, 'base64');
  const sourceBuffer = buf.buffer as ArrayBuffer;

  // 解压缓冲区：预估原始数据最大为压缩数据的 10 倍
  const destBuffer = new ArrayBuffer(sourceBuffer.byteLength * 10);
  const zip = zlib.createZipSync();
  const result = await zip.uncompress(destBuffer, sourceBuffer);

  const decompressedBytes = new Uint8Array(destBuffer, 0, result.destLen);
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(decompressedBytes);
}

/** 检查是否为压缩格式 */
function isCompressedData(data: string): boolean {
  return data.startsWith(COMPRESSED_PREFIX);
}

// =============================================================================
// v2 动作编码 / 解码
// =============================================================================
// 编码规则：
//   K{vk}                           keyboard
//   M{button}                       mouse
//   S{direction}                    mouseScroll
//   B{mask}                         gamepadButton
//   T,{l|r}                         gamepadTrigger
//   J,{l|r},{u|d|l|r}               gamepadStick
//   A,{l|r}[,{sens}][,i]            analogStick
//   D                               dpad
//   P,{id}                          special
//   W|{label}:{act}|{label}:{act}   wheelPad
//   X|{up}|{dn}|{lt}|{rt}[|{ck}]   digitalStick
//   C|{act}|{act}|...               combo
//   H,{k1},{k2}[/{sk1},{sk2}/...]   shortcut

/** 将 KeyAction 编码为紧凑字符串 */
function encodeAction(a: KeyAction): string {
  switch (a.type) {
    case 'keyboard':
      return `K${(a as KeyboardAction).vk}`;
    case 'mouse':
      return `M${(a as MouseButtonAction).button}`;
    case 'mouseScroll':
      return `S${(a as MouseScrollAction).direction}`;
    case 'gamepadButton':
      return `B${(a as GamepadButtonAction).mask}`;
    case 'gamepadTrigger':
      return `T,${(a as GamepadTriggerAction).trigger === 'left' ? 'l' : 'r'}`;
    case 'gamepadStick': {
      const gs = a as GamepadStickAction;
      const stk = gs.stick === 'left' ? 'l' : 'r';
      const dir = gs.direction.charAt(0); // u/d/l/r
      return `J,${stk},${dir}`;
    }
    case 'analogStick': {
      const as2 = a as AnalogStickAction;
      let s = `A,${as2.stick === 'left' ? 'l' : 'r'}`;
      if (as2.sensitivity !== undefined && as2.sensitivity !== 1.0) {
        s += `,${as2.sensitivity}`;
      }
      if (as2.invisible === true) {
        s += `,i`;
      }
      return s;
    }
    case 'dpad':
      return 'D';
    case 'special':
      return `P,${(a as SpecialAction).id}`;
    case 'wheelPad': {
      const wp = a as WheelPadAction;
      const segs = wp.segments.map((seg: WheelPadSegment) =>
        `${seg.label}:${encodeAction(seg.action)}`
      );
      return `W|${segs.join('|')}`;
    }
    case 'digitalStick': {
      const ds = a as DigitalStickAction;
      let s = `X|${encodeAction(ds.upAction)}|${encodeAction(ds.downAction)}|${encodeAction(ds.leftAction)}|${encodeAction(ds.rightAction)}`;
      if (ds.clickAction) {
        s += `|${encodeAction(ds.clickAction)}`;
      }
      return s;
    }
    case 'combo': {
      const cb = a as ComboAction;
      const acts = cb.actions.map((ca: KeyAction) => encodeAction(ca));
      return `C|${acts.join('|')}`;
    }
    case 'shortcut': {
      const sh = a as ShortcutAction;
      let s = `H,${sh.keys.join(',')}`;
      if (sh.keySequence && sh.keySequence.length > 0) {
        const seqs = sh.keySequence.map((seq: number[]) => seq.join(','));
        s += `/${seqs.join('/')}`;
      }
      return s;
    }
    default:
      return 'D'; // fallback
  }
}

/** 解码简单动作字符串（不含 |） */
function decodeSimpleAction(s: string): KeyAction {
  if (s.startsWith('K')) {
    const vk = parseInt(s.substring(1));
    if (!isNaN(vk)) {
      return { type: 'keyboard', vk: vk } as KeyboardAction;
    }
  }
  if (s.startsWith('M')) {
    const btn = parseInt(s.substring(1));
    if (!isNaN(btn)) {
      return { type: 'mouse', button: btn } as MouseButtonAction;
    }
  }
  if (s.startsWith('S')) {
    const dir = parseInt(s.substring(1));
    if (!isNaN(dir)) {
      return { type: 'mouseScroll', direction: dir } as MouseScrollAction;
    }
  }
  if (s.startsWith('B')) {
    const mask = parseInt(s.substring(1));
    if (!isNaN(mask)) {
      return { type: 'gamepadButton', mask: mask } as GamepadButtonAction;
    }
  }
  if (s.startsWith('T,')) {
    return { type: 'gamepadTrigger', trigger: s.charAt(2) === 'l' ? 'left' : 'right' } as GamepadTriggerAction;
  }
  if (s.startsWith('J,')) {
    const parts = s.split(',');
    const stick = parts[1] === 'l' ? 'left' : 'right';
    const dirMap: Record<string, string> = { 'u': 'up', 'd': 'down', 'l': 'left', 'r': 'right' };
    const dir = dirMap[parts[2]] ?? 'up';
    return { type: 'gamepadStick', stick: stick, direction: dir } as GamepadStickAction;
  }
  if (s.startsWith('A,')) {
    const parts = s.split(',');
    const stick = parts[1] === 'l' ? 'left' : 'right';
    const result: AnalogStickAction = { type: 'analogStick', stick: stick };
    for (let i = 2; i < parts.length; i++) {
      if (parts[i] === 'i') {
        result.invisible = true;
      } else {
        const num = parseFloat(parts[i]);
        if (!isNaN(num)) {
          result.sensitivity = num;
        }
      }
    }
    return result;
  }
  if (s === 'D') {
    return { type: 'dpad' } as DPadAction;
  }
  if (s.startsWith('P,')) {
    return { type: 'special', id: s.substring(2) as SpecialActionId } as SpecialAction;
  }
  if (s.startsWith('H,')) {
    const hBody = s.substring(2);
    const slashIdx = hBody.indexOf('/');
    if (slashIdx >= 0) {
      const keysStr = hBody.substring(0, slashIdx);
      const seqStr = hBody.substring(slashIdx + 1);
      const keys = keysStr.split(',').map((n: string) => parseInt(n)).filter((n: number) => !isNaN(n));
      const keySequence = seqStr.split('/').map((seg: string) =>
        seg.split(',').map((n: string) => parseInt(n)).filter((n: number) => !isNaN(n))
      );
      if (keys.length > 0) {
        return { type: 'shortcut', keys: keys, keySequence: keySequence } as ShortcutAction;
      }
    } else {
      const keys = hBody.split(',').map((n: string) => parseInt(n)).filter((n: number) => !isNaN(n));
      if (keys.length > 0) {
        return { type: 'shortcut', keys: keys } as ShortcutAction;
      }
    }
  }
  // fallback: 返回无操作
  return { type: 'special', id: 'none' } as SpecialAction;
}

/** 将编码字符串解码为 KeyAction */
function decodeAction(s: string): KeyAction {
  // 复合类型以 W|, X|, C| 开头
  if (s.startsWith('W|')) {
    const body = s.substring(2);
    const segParts = body.split('|');
    const segments: WheelPadSegment[] = [];
    for (const sp of segParts) {
      const colonIdx = sp.lastIndexOf(':');
      if (colonIdx >= 0) {
        const label = sp.substring(0, colonIdx);
        const actStr = sp.substring(colonIdx + 1);
        segments.push({ label: label, action: decodeSimpleAction(actStr) });
      }
    }
    return { type: 'wheelPad', segments: segments } as WheelPadAction;
  }
  if (s.startsWith('X|')) {
    const body = s.substring(2);
    const parts = body.split('|');
    const result: DigitalStickAction = {
      type: 'digitalStick',
      upAction: decodeSimpleAction(parts[0] ?? 'K87'),
      downAction: decodeSimpleAction(parts[1] ?? 'K83'),
      leftAction: decodeSimpleAction(parts[2] ?? 'K65'),
      rightAction: decodeSimpleAction(parts[3] ?? 'K68'),
    };
    if (parts.length > 4 && parts[4]) {
      result.clickAction = decodeSimpleAction(parts[4]);
    }
    return result;
  }
  if (s.startsWith('C|')) {
    const body = s.substring(2);
    const parts = body.split('|');
    const actions: KeyAction[] = parts.map((p: string) => decodeSimpleAction(p));
    return { type: 'combo', actions: actions } as ComboAction;
  }
  // 简单类型
  return decodeSimpleAction(s);
}

// =============================================================================
// v3 管道分隔格式 — 比 JSON 更紧凑 (~50% smaller)
// =============================================================================
// 格式: "3\n名称\nl|a|x|y|w|h[|flags]\n..."
// flags: 可选字段用 key=value 对表示，仅非默认值时出现
// 例: "A|K65|0.5|0.3|40|40" 或 "A|K65|0.5|0.3|40|40|s=c|o=60|gid=abc"

/** 序列化为 v3 紧凑管道格式 */
function serializeV3(profileName: string, keys: CustomKeyDef[]): string {
  const lines: string[] = [];
  lines.push('3');  // version
  lines.push(profileName);
  for (const key of keys) {
    const action = encodeAction(key.action);
    const x = Math.round(key.xPercent * 1000) / 1000;
    const y = Math.round(key.yPercent * 1000) / 1000;
    // 必填字段：label|action|x|y|width|height
    const parts: string[] = [];
    parts.push(key.label);
    parts.push(action);
    parts.push(x.toString());
    parts.push(y.toString());
    parts.push(key.width.toString());
    parts.push(key.height.toString());
    // 可选字段：仅非默认值时追加
    if (key.shape !== 'rect') parts.push('s=' + (key.shape === 'circle' ? 'c' : 'h'));
    if (key.behavior === 'toggle') parts.push('b=t');
    if (key.opacity !== 80) parts.push('o=' + key.opacity.toString());
    if (key.borderRadius !== 12) parts.push('r=' + key.borderRadius.toString());
    if (key.bgColor !== '#30FFFFFF') parts.push('bg=' + key.bgColor);
    if (key.textColor !== '#E0FFFFFF') parts.push('tc=' + key.textColor);
    if (key.pressedColor !== '#80A8D8EA') parts.push('pc=' + key.pressedColor);
    if (key.fontSize !== 14) parts.push('fs=' + key.fontSize.toString());
    if (key.layer !== 0) parts.push('ly=' + key.layer.toString());
    if ((key.borderWidth ?? 1) !== 1) parts.push('bw=' + (key.borderWidth ?? 1).toString());
    if (key.haptic !== 'light') parts.push('hp=' + key.haptic);
    if (key.groupId) parts.push('gid=' + key.groupId);
    lines.push(parts.join('|'));
  }
  return lines.join('\n');
}

/** 从 v3 管道格式反序列化 */
function deserializeV3(data: string): [string, CustomKeyDef[]] | null {
  const lines = data.split('\n');
  if (lines.length < 3 || lines[0] !== '3') return null;
  const profileName = lines[1];
  const keys: CustomKeyDef[] = [];
  for (let i = 2; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.length === 0) continue;
    const parts = line.split('|');
    if (parts.length < 6) continue;
    // 解析可选 flags
    let shape: KeyShape = 'rect';
    let behavior: KeyBehavior = 'momentary';
    let opacity = 80;
    let borderRadius = 12;
    let bgColor = '#30FFFFFF';
    let textColor = '#E0FFFFFF';
    let pressedColor = '#80A8D8EA';
    let fontSize = 14;
    let layer = 0;
    let borderWidth = 1;
    let haptic = 'light';
    let groupId: string | undefined = undefined;
    for (let j = 6; j < parts.length; j++) {
      const eqIdx = parts[j].indexOf('=');
      if (eqIdx < 0) continue;
      const k = parts[j].substring(0, eqIdx);
      const v = parts[j].substring(eqIdx + 1);
      if (k === 's') shape = (v === 'c' ? 'circle' : (v === 'h' ? 'hexagon' : 'rect')) as KeyShape;
      else if (k === 'b') behavior = (v === 't' ? 'toggle' : 'momentary') as KeyBehavior;
      else if (k === 'o') opacity = parseInt(v) || 80;
      else if (k === 'r') borderRadius = parseInt(v) || 12;
      else if (k === 'bg') bgColor = v;
      else if (k === 'tc') textColor = v;
      else if (k === 'pc') pressedColor = v;
      else if (k === 'fs') fontSize = parseInt(v) || 14;
      else if (k === 'ly') layer = parseInt(v) || 0;
      else if (k === 'bw') borderWidth = parseInt(v) || 1;
      else if (k === 'hp') haptic = v;
      else if (k === 'gid') groupId = v;
    }
    const keyDef: CustomKeyDef = {
      id: generateKeyId(),
      label: parts[0],
      action: decodeAction(parts[1]),
      shape: shape,
      behavior: behavior,
      xPercent: parseFloat(parts[2]) || 0,
      yPercent: parseFloat(parts[3]) || 0,
      width: parseInt(parts[4]) || 40,
      height: parseInt(parts[5]) || 40,
      layer: layer,
      opacity: opacity,
      borderRadius: borderRadius,
      normalColor: '#60FFFFFF',
      pressedColor: pressedColor,
      bgColor: bgColor,
      textColor: textColor,
      fontSize: fontSize,
      borderWidth: borderWidth,
      haptic: haptic,
      groupId: groupId,
    };
    keys.push(keyDef);
  }
  return keys.length > 0 ? [profileName, keys] : null;
}

// =============================================================================
// 紧凑序列化 / 反序列化 (v2 JSON 格式)
// =============================================================================

/** 将 CustomKeyDef 转为 v2 紧凑格式 */
function toCompact(key: CustomKeyDef): CompactKeyV2 {
  const ck: CompactKeyV2 = {
    l: key.label,
    a: encodeAction(key.action),
    s: key.shape === 'circle' ? 'c' : (key.shape === 'hexagon' ? 'h' : 'r'),
    b: key.behavior === 'toggle' ? 't' : 'm',
    x: Math.round(key.xPercent * 1000) / 1000,
    y: Math.round(key.yPercent * 1000) / 1000,
    w: key.width,
    h: key.height,
  };
  if (key.opacity !== 80) ck.o = key.opacity;
  if (key.borderRadius !== 12) ck.r = key.borderRadius;
  if (key.bgColor !== '#30FFFFFF') ck.bg = key.bgColor;
  if (key.textColor !== '#E0FFFFFF') ck.tc = key.textColor;
  if (key.pressedColor !== '#80A8D8EA') ck.pc = key.pressedColor;
  if (key.fontSize !== 14) ck.fs = key.fontSize;
  if (key.layer !== 0) ck.ly = key.layer;
  if ((key.borderWidth ?? 1) !== 1) ck.bw = key.borderWidth;
  if (key.haptic !== 'light') ck.hp = key.haptic;
  if (key.groupId) ck.gid = key.groupId;
  return ck;
}

/** 将 v2 紧凑格式还原为 CustomKeyDef */
function fromCompactV2(ck: CompactKeyV2): CustomKeyDef {
  return {
    id: generateKeyId(),
    label: ck.l,
    action: decodeAction(ck.a),
    shape: (ck.s === 'c' ? 'circle' : (ck.s === 'h' ? 'hexagon' : 'rect')) as KeyShape,
    behavior: (ck.b === 't' ? 'toggle' : 'momentary') as KeyBehavior,
    xPercent: ck.x,
    yPercent: ck.y,
    width: ck.w,
    height: ck.h,
    layer: ck.ly ?? 0,
    opacity: ck.o ?? 80,
    borderRadius: ck.r ?? 12,
    normalColor: '#60FFFFFF',
    pressedColor: ck.pc ?? '#80A8D8EA',
    bgColor: ck.bg ?? '#30FFFFFF',
    textColor: ck.tc ?? '#E0FFFFFF',
    fontSize: ck.fs ?? 14,
    borderWidth: ck.bw ?? 1,
    haptic: ck.hp ?? 'light',
    groupId: ck.gid,
  };
}

/** v1 兼容：直接从含 KeyAction 对象的紧凑格式还原 */
function fromCompactV1(raw: Record<string, Object>): CustomKeyDef {
  return {
    id: generateKeyId(),
    label: raw['l'] as string ?? '',
    action: raw['a'] as KeyAction,
    shape: ((raw['s'] as string) === 'c' ? 'circle' : ((raw['s'] as string) === 'h' ? 'hexagon' : 'rect')) as KeyShape,
    behavior: ((raw['b'] as string) === 't' ? 'toggle' : 'momentary') as KeyBehavior,
    xPercent: raw['x'] as number ?? 0.5,
    yPercent: raw['y'] as number ?? 0.5,
    width: raw['w'] as number ?? 60,
    height: raw['h'] as number ?? 60,
    layer: (raw['ly'] as number) ?? 0,
    opacity: (raw['o'] as number) ?? 80,
    borderRadius: (raw['r'] as number) ?? 12,
    normalColor: '#60FFFFFF',
    pressedColor: (raw['pc'] as string) ?? '#80A8D8EA',
    bgColor: (raw['bg'] as string) ?? '#30FFFFFF',
    textColor: (raw['tc'] as string) ?? '#E0FFFFFF',
    fontSize: (raw['fs'] as number) ?? 14,
    borderWidth: (raw['bw'] as number) ?? 1,
    haptic: (raw['hp'] as string) ?? 'light',
  };
}

// =============================================================================
// 公共 API
// =============================================================================

export class QrShareService {

  /**
   * 将配置序列化为 v3 管道格式（QR/压缩用，最紧凑）
   */
  static serialize(profileName: string, keys: CustomKeyDef[]): string {
    return serializeV3(profileName, keys);
  }

  /**
   * 将配置序列化为 v2 JSON 字符串（剪贴板用，人类可读）
   */
  static serializeJson(profileName: string, keys: CustomKeyDef[]): string {
    const data: CompactExportV2 = {
      v: 2,
      n: profileName,
      k: keys.map((k: CustomKeyDef) => toCompact(k)),
    };
    return JSON.stringify(data);
  }

  /**
   * 将配置序列化并压缩为 base64 字符串（MLC: 前缀）
   * 压缩率约 50-70%，显著降低 QR 码版本
   */
  static async serializeCompressed(profileName: string, keys: CustomKeyDef[]): Promise<string> {
    const json = QrShareService.serialize(profileName, keys);
    try {
      const compressed = await compressToBase64(json);
      console.info(`[QrShareService] 压缩: ${json.length} -> ${compressed.length} (${Math.round(compressed.length * 100 / json.length)}%)`);
      // 只有压缩后更小才使用压缩格式
      if (compressed.length < json.length) {
        return compressed;
      }
    } catch (e) {
      console.warn('[QrShareService] 压缩失败，回退到未压缩:', JSON.stringify(e));
    }
    return json;
  }

  /**
   * 从紧凑 JSON 反序列化为按键列表（兼容 v1、v2 和压缩格式）
   * @returns [profileName, keys] 或 null（解析失败）
   */
  static async deserialize(data: string): Promise<[string, CustomKeyDef[]] | null> {
    let json = data;
    if (isCompressedData(data)) {
      try {
        json = await decompressFromBase64(data);
      } catch (e) {
        console.error('[QrShareService] 解压失败:', JSON.stringify(e));
        return null;
      }
    }
    return QrShareService.parseData(json);
  }

  /**
   * 解析数据为按键列表（兼容 v3 管道格式、v2 JSON、v1 JSON）
   */
  private static parseData(data: string): [string, CustomKeyDef[]] | null {
    // v3 管道格式：首行为 "3"
    if (data.startsWith('3\n')) {
      return deserializeV3(data);
    }
    // v1/v2 JSON 格式
    try {
      const raw = JSON.parse(data) as Record<string, Object>;
      const version = raw['v'] as number ?? 1;
      const keyArr = raw['k'] as Object[];
      if (!keyArr || !Array.isArray(keyArr) || keyArr.length === 0) {
        return null;
      }
      const profileName = (raw['n'] as string) ?? '导入配置';

      if (version >= 2) {
        // v2: 动作编码为字符串
        const keys: CustomKeyDef[] = keyArr.map((item: Object) =>
          fromCompactV2(item as CompactKeyV2)
        );
        return [profileName, keys];
      }
      // v1: 动作为原始 JSON 对象
      const keys: CustomKeyDef[] = keyArr.map((item: Object) =>
        fromCompactV1(item as Record<string, Object>)
      );
      return [profileName, keys];
    } catch (_e) {
      return null;
    }
  }

  /** 检查数据是否能放入 QR 码 */
  static canFitInQr(json: string): boolean {
    return json.length <= QR_MAX_CHARS;
  }

  /**
   * 生成 QR 码 PixelMap
   * 优先使用 ScanKit generateBarcode（系统级生成，识别率最高）
   * 超过 ScanKit 512 字符限制时回退到自定义生成器
   * @param content 要编码的字符串
   * @param size 图片尺寸 (px)
   * @param ecLevel 纠错级别
   */
  static async generateQrCode(content: string, size: number = 600,
    ecLevel?: ECLevel): Promise<QrCodeResult> {
    // 压缩数据用低纠错（zlib 自带校验）
    const level = ecLevel ?? (isCompressedData(content) ? ECLevel.L : ECLevel.M);

    // ScanKit 限制 512 字符，如果在范围内优先使用系统生成
    if (content.length <= 512) {
      try {
        const scanEcLevel = level === ECLevel.L ? generateBarcode.ErrorCorrectionLevel.LEVEL_L
          : level === ECLevel.Q ? generateBarcode.ErrorCorrectionLevel.LEVEL_Q
          : level === ECLevel.H ? generateBarcode.ErrorCorrectionLevel.LEVEL_H
          : generateBarcode.ErrorCorrectionLevel.LEVEL_M;
        const options: generateBarcode.CreateOptions = {
          scanType: scanCore.ScanType.QR_CODE,
          width: size,
          height: size,
          margin: 2,
          level: scanEcLevel,
        };
        const pixelMap = await generateBarcode.createBarcode(content, options);
        console.info(`[QrShareService] ScanKit 生成 QR: ${content.length} chars, ECLevel=${level}`);
        return { pixelMap };
      } catch (e) {
        console.warn('[QrShareService] ScanKit 生成失败，回退到自定义生成器:', JSON.stringify(e));
      }
    }

    // 回退到自定义 QR 生成器（支持大数据量）
    try {
      const pixelMap = await generateQrPixelMap(content, size, level);
      console.info(`[QrShareService] 自定义生成 QR: ${content.length} chars, ECLevel=${level}`);
      return { pixelMap };
    } catch (e) {
      const errMsg = (e as Record<string, Object>)?.message as string
        ?? (e as Record<string, Object>)?.code as string
        ?? JSON.stringify(e);
      console.error('[QrShareService] 生成二维码失败:', errMsg);
      return { pixelMap: null, error: errMsg };
    }
  }

  /**
   * 启动系统相机扫码
   * @returns 扫码内容字符串，失败返回 null
   */
  static async scanQrCode(): Promise<string | null> {
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true,
      };
      const result = await scanBarcode.startScanForResult(getContext(), options);
      if (result && result.originalValue) {
        return result.originalValue;
      }
      return null;
    } catch (e) {
      console.error('[QrShareService] 扫码失败:', JSON.stringify(e));
      return null;
    }
  }
}
