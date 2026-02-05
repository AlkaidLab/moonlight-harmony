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
 * XML 解析工具类
 * 
 * 统一处理服务器响应的 XML 解析
 */
export class XmlUtil {
  /**
   * 从 XML 中获取指定标签的值
   * @param xml XML 字符串
   * @param tag 标签名
   * @param required 是否必需（如果为 true 且未找到则抛出异常）
   * @returns 标签值，未找到返回空字符串
   */
  static getValue(xml: string, tag: string, required: boolean = false): string {
    const regex = new RegExp(`<${tag}>(.*?)</${tag}>`, 's');
    const match = xml.match(regex);
    const value = match ? match[1].trim() : '';
    
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
    const regex = new RegExp(`<${tag}>(.*?)</${tag}>`, 'gs');
    const matches: string[] = [];
    let match: RegExpExecArray | null;
    
    while ((match = regex.exec(xml)) !== null) {
      matches.push(match[1].trim());
    }
    
    return matches;
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
    const regex = new RegExp(`<${tag}>.*?</${tag}>`, 's');
    return regex.test(xml);
  }
}
