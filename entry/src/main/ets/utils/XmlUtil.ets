/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { xml } from '@kit.ArkTS';
import { StringUtil } from './StringUtil';

class XmlFrame {
  readonly name: string;
  text: string = '';

  constructor(name: string) {
    this.name = name;
  }
}

/**
 * XML 解析工具类
 *
 * 统一处理服务器响应的 XML 解析。服务器响应来自 Sunshine/GFE，
 * 因此必须使用 XML parser 处理实体、CDATA 和嵌套节点，不能用正则匹配标签。
 */
export class XmlUtil {
  private static parseValues(xmlText: string, expectedTag: string): string[] {
    const values: string[] = [];
    const frames: XmlFrame[] = [];
    const bytes = StringUtil.stringToUint8Array(xmlText);
    const inputBuffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(inputBuffer).set(bytes);
    const parser = new xml.XmlPullParser(inputBuffer);

    parser.parse({
      supportDoctype: false,
      ignoreNameSpace: false,
      tokenValueCallbackFunction: (eventType: xml.EventType, info: xml.ParseInfo): boolean => {
        if (eventType === xml.EventType.START_TAG) {
          frames.push(new XmlFrame(info.getName()));
        } else if (eventType === xml.EventType.TEXT ||
          eventType === xml.EventType.CDSECT ||
          eventType === xml.EventType.ENTITY_REFERENCE ||
          eventType === xml.EventType.WHITESPACE) {
          if (frames.length > 0) {
            frames[frames.length - 1].text += info.getText();
          }
        } else if (eventType === xml.EventType.END_TAG && frames.length > 0) {
          const frame = frames.pop();
          if (frame) {
            if (frame.name === expectedTag) {
              values.push(frame.text.trim());
            }
            if (frames.length > 0) {
              frames[frames.length - 1].text += frame.text;
            }
          }
        }
        return true;
      }
    });

    return values;
  }

  /**
   * 从 XML 中获取指定标签的值
   * @param xml XML 字符串
   * @param tag 标签名
   * @param required 是否必需（如果为 true 且未找到则抛出异常）
   * @returns 标签值，未找到返回空字符串
   */
  static getValue(xml: string, tag: string, required: boolean = false): string {
    let value = '';
    try {
      const values = XmlUtil.parseValues(xml, tag);
      if (values.length > 0) {
        value = values[0];
      }
    } catch (error) {
      if (required) {
        throw new Error(`XML 解析失败，未找到必需的标签: ${tag}`);
      }
    }
    
    if (required && !value) {
      throw new Error(`XML 中未找到必需的标签: ${tag}`);
    }
    
    return value;
  }

  /**
   * 从 XML 中获取指定标签的所有值（用于列表）
   * @param xml XML 字符串
   * @param tag 标签名
   * @returns 所有匹配的标签值数组
   */
  static getValues(xml: string, tag: string): string[] {
    try {
      return XmlUtil.parseValues(xml, tag);
    } catch (error) {
      return [];
    }
  }

  /**
   * 从 XML 中获取整数值
   * @param xml XML 字符串
   * @param tag 标签名
   * @param defaultValue 默认值
   * @returns 整数值
   */
  static getIntValue(xml: string, tag: string, defaultValue: number = 0): number {
    const value = XmlUtil.getValue(xml, tag);
    const parsed = parseInt(value);
    return isNaN(parsed) ? defaultValue : parsed;
  }

  /**
   * 从 XML 中获取布尔值
   * @param xml XML 字符串
   * @param tag 标签名
   * @returns 布尔值（'1' 或 'true' 返回 true）
   */
  static getBoolValue(xml: string, tag: string): boolean {
    const value = XmlUtil.getValue(xml, tag).toLowerCase();
    return value === '1' || value === 'true';
  }

  /**
   * 检查 XML 中是否包含指定标签
   * @param xml XML 字符串
   * @param tag 标签名
   * @returns 是否存在该标签
   */
  static hasTag(xml: string, tag: string): boolean {
    try {
      return XmlUtil.parseValues(xml, tag).length > 0;
    } catch (error) {
      return false;
    }
  }
}
