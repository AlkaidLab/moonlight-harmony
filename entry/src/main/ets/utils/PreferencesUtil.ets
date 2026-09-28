/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';

/**
 * Preferences 工具类
 */
export class PreferencesUtil {
  private static readonly PREFERENCES_NAME = 'moonlight_settings';
  private static preferencesInstance: preferences.Preferences | null = null;
  private static contextRef: Context | null = null;

  /**
   * 初始化（需要在应用启动时调用）
   */
  static init(context: Context): void {
    PreferencesUtil.contextRef = context;
  }

  /**
   * 获取应用沙箱文件目录路径
   */
  static getFilesDir(): string {
    return PreferencesUtil.contextRef?.filesDir ?? '';
  }

  /**
   * 获取已保存的 Context 引用
   */
  static getContext(): Context | null {
    return PreferencesUtil.contextRef;
  }

  static async getPreferences(context?: Context): Promise<preferences.Preferences> {
    const ctx = context || PreferencesUtil.contextRef;
    if (!ctx) {
      throw new Error('PreferencesUtil: context not initialized');
    }
    if (!PreferencesUtil.preferencesInstance) {
      try {
        PreferencesUtil.preferencesInstance = await preferences.getPreferences(
          ctx,
          PreferencesUtil.PREFERENCES_NAME
        );
      } catch (e) {
        throw new Error(`PreferencesUtil: failed to get preferences - ${e}`);
      }
    }
    return PreferencesUtil.preferencesInstance;
  }

  /**
   * 通用获取方法
   * 注意：对于数字类型，如果存储的是字符串会自动转换
   */
  static async get<T>(key: string, defaultValue: T): Promise<T> {
    const prefs = await PreferencesUtil.getPreferences();
    let value: preferences.ValueType;
    try {
      value = await prefs.get(key, defaultValue as preferences.ValueType);
    } catch (e) {
      // 读取失败按默认值处理，保持调用方拿到可用的兜底值
      return defaultValue;
    }
    
    // 如果期望返回数字但得到字符串，尝试转换
    if (typeof defaultValue === 'number' && typeof value === 'string') {
      const parsed = Number(value);
      if (!isNaN(parsed)) {
        return parsed as T;
      }
    }
    
    return value as T;
  }

  /**
   * 通用设置方法
   */
  static async put(key: string, value: preferences.ValueType): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences();
    try {
      await prefs.put(key, value);
      await prefs.flush();
    } catch (e) {
      // 写入失败上抛，调用方可感知（CustomKeyStore.save 等依赖此契约）
      Logger.error('PreferencesUtil', `PreferencesUtil: put(${key}) 失败`, e);
      throw new Error(`PreferencesUtil: put(${key}) 失败: ${e}`);
    }
  }

  static async getString(context: Context, key: string, defaultValue: string = ''): Promise<string> {
    const prefs = await PreferencesUtil.getPreferences(context);
    let value: preferences.ValueType;
    try {
      value = await prefs.get(key, defaultValue);
    } catch (e) {
      // 读取失败按默认值处理，保持调用方拿到可用的兜底值
      return defaultValue;
    }
    return value as string;
  }

  static async setString(context: Context, key: string, value: string): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(context);
    try {
      await prefs.put(key, value);
      await prefs.flush();
    } catch (e) {
      // 写入失败上抛，调用方可感知
      Logger.error('PreferencesUtil', `PreferencesUtil: setString(${key}) 失败`, e);
      throw new Error(`PreferencesUtil: setString(${key}) 失败: ${e}`);
    }
  }

  static async getNumber(context: Context, key: string, defaultValue: number = 0): Promise<number> {
    const prefs = await PreferencesUtil.getPreferences(context);
    let value: preferences.ValueType;
    try {
      value = await prefs.get(key, defaultValue);
    } catch (e) {
      // 读取失败按默认值处理，保持调用方拿到可用的兜底值
      return defaultValue;
    }
    return value as number;
  }

  static async setNumber(context: Context, key: string, value: number): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(context);
    try {
      await prefs.put(key, value);
      await prefs.flush();
    } catch (e) {
      // 写入失败上抛，调用方可感知
      Logger.error('PreferencesUtil', `PreferencesUtil: setNumber(${key}) 失败`, e);
      throw new Error(`PreferencesUtil: setNumber(${key}) 失败: ${e}`);
    }
  }

  static async getBoolean(context: Context, key: string, defaultValue: boolean = false): Promise<boolean> {
    const prefs = await PreferencesUtil.getPreferences(context);
    let value: preferences.ValueType;
    try {
      value = await prefs.get(key, defaultValue);
    } catch (e) {
      // 读取失败按默认值处理，保持调用方拿到可用的兜底值
      return defaultValue;
    }
    return value as boolean;
  }

  static async setBoolean(context: Context, key: string, value: boolean): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(context);
    try {
      await prefs.put(key, value);
      await prefs.flush();
    } catch (e) {
      // 写入失败上抛，调用方可感知
      Logger.error('PreferencesUtil', `PreferencesUtil: setBoolean(${key}) 失败`, e);
      throw new Error(`PreferencesUtil: setBoolean(${key}) 失败: ${e}`);
    }
  }

  static async remove(context: Context, key: string): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(context);
    try {
      await prefs.delete(key);
      await prefs.flush();
    } catch (e) {
      // 删除失败上抛，调用方可感知
      Logger.error('PreferencesUtil', `PreferencesUtil: remove(${key}) 失败`, e);
      throw new Error(`PreferencesUtil: remove(${key}) 失败: ${e}`);
    }
  }

  static async clear(context: Context): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(context);
    try {
      await prefs.clear();
      await prefs.flush();
    } catch (e) {
      // 清空失败上抛，调用方可感知
      Logger.error('PreferencesUtil', 'PreferencesUtil: clear 失败', e);
      throw new Error(`PreferencesUtil: clear 失败: ${e}`);
    }
  }
}
