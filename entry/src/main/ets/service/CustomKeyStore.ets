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
 * 自定义按键配置存储
 *
 * 使用 Preferences (JSON) 持久化自定义按键配置。
 * 替代 Android 的 SQLite 方案，更轻量且适配 ArkUI 声明式架构。
 *
 * 存储结构:
 *   custom_key_profiles: JSON string of CustomKeyProfile[]
 *   custom_key_active_profile: string (当前活跃配置名称)
 */

import { PreferencesUtil } from '../utils/PreferencesUtil';
import { display } from '@kit.ArkUI';
import {
  CustomKeyProfile,
  CustomKeyDef,
  createDefaultProfile,
  KeyAction,
} from './CustomKeyTypes';

/** 导出数据格式 */
interface ExportData {
  version: number;
  profile: CustomKeyProfile;
}

/** 存储键 */
const STORAGE_KEY_PROFILES = 'custom_key_profiles';
const STORAGE_KEY_ACTIVE = 'custom_key_active_profile';

/**
 * 自定义按键配置存储管理
 *
 * 负责配置的 CRUD 和持久化。所有方法都是 async 的。
 */
export class CustomKeyStore {

  // ── 缓存 ──
  private static profiles: CustomKeyProfile[] | null = null;
  private static activeProfileName: string = '';

  /**
   * 初始化：从持久化加载数据
   */
  static async init(): Promise<void> {
    try {
      const json = await PreferencesUtil.get<string>(STORAGE_KEY_PROFILES, '');
      if (json) {
        CustomKeyStore.profiles = JSON.parse(json) as CustomKeyProfile[];
      } else {
        CustomKeyStore.profiles = [];
      }
      CustomKeyStore.activeProfileName = await PreferencesUtil.get<string>(STORAGE_KEY_ACTIVE, '');

      // 如果没有任何配置，创建一个默认的
      if (CustomKeyStore.profiles.length === 0) {
        const defaultProfile = createDefaultProfile('默认');
        CustomKeyStore.profiles.push(defaultProfile);
        CustomKeyStore.activeProfileName = defaultProfile.name;
        await CustomKeyStore.save();
      }

      // 校验活跃配置名是否有效
      if (!CustomKeyStore.profiles.find(p => p.name === CustomKeyStore.activeProfileName)) {
        CustomKeyStore.activeProfileName = CustomKeyStore.profiles[0].name;
        await PreferencesUtil.put(STORAGE_KEY_ACTIVE, CustomKeyStore.activeProfileName);
      }

      // 数据迁移：旧的绝对坐标 (x,y vp) → 百分比坐标 (xPercent,yPercent)
      if (CustomKeyStore.migrateAbsoluteToPercent()) {
        await CustomKeyStore.save();
        console.info('[CustomKeyStore] 坐标迁移完成: absolute vp → percent');
      }
    } catch (e) {
      console.error('[CustomKeyStore] init failed:', JSON.stringify(e));
      CustomKeyStore.profiles = [createDefaultProfile('默认')];
      CustomKeyStore.activeProfileName = '默认';
    }
  }

  /** 确保已初始化 */
  private static async ensureInit(): Promise<void> {
    if (CustomKeyStore.profiles === null) {
      await CustomKeyStore.init();
    }
  }

  /** 持久化到 Preferences */
  private static async save(): Promise<void> {
    const json = JSON.stringify(CustomKeyStore.profiles);
    await PreferencesUtil.put(STORAGE_KEY_PROFILES, json);
    await PreferencesUtil.put(STORAGE_KEY_ACTIVE, CustomKeyStore.activeProfileName);
  }

  /**
   * 数据迁移：旧的绝对坐标 (x,y vp) → 百分比坐标 (xPercent,yPercent)
   * 检测逻辑：如果 key 有 x/y 字段但没有 xPercent/yPercent（或 xPercent 为 0 且 x > 1），
   *           则认为是旧数据，需要迁移。
   * @returns true 如果发生了迁移
   */
  private static migrateAbsoluteToPercent(): boolean {
    if (!CustomKeyStore.profiles) return false;

    // 获取当前屏幕尺寸作为参考（假设旧数据是在当前设备上保存的）
    const displayInfo = display.getDefaultDisplaySync();
    const screenWVp = px2vp(displayInfo.width);
    const screenHVp = px2vp(displayInfo.height);
    if (screenWVp <= 0 || screenHVp <= 0) return false;

    let migrated = false;
    for (const profile of CustomKeyStore.profiles) {
      if (CustomKeyStore.migrateProfileKeys(profile)) {
        migrated = true;
      }
    }
    return migrated;
  }

  /**
   * 对单个配置档案中的按键做旧坐标迁移
   * @returns true 如果有按键被迁移
   */
  private static migrateProfileKeys(profile: CustomKeyProfile): boolean {
    const displayInfo = display.getDefaultDisplaySync();
    const screenWVp = px2vp(displayInfo.width);
    const screenHVp = px2vp(displayInfo.height);
    if (screenWVp <= 0 || screenHVp <= 0) return false;

    let migrated = false;
    for (const key of profile.keys) {
      const oldX = key.x;
      const oldY = key.y;
      if (oldX !== undefined && oldX > 1 && (key.xPercent === undefined || key.xPercent === 0)) {
        key.xPercent = Math.max(0, Math.min(1, oldX / screenWVp));
        key.yPercent = Math.max(0, Math.min(1, (oldY ?? 0) / screenHVp));
        key.x = undefined;
        key.y = undefined;
        migrated = true;
      }
    }
    return migrated;
  }

  // ── 配置档案管理 ──

  /** 获取所有配置名称 */
  static async getProfileNames(): Promise<string[]> {
    await CustomKeyStore.ensureInit();
    return CustomKeyStore.profiles!.map(p => p.name);
  }

  /** 获取当前活跃配置名称 */
  static async getActiveProfileName(): Promise<string> {
    await CustomKeyStore.ensureInit();
    return CustomKeyStore.activeProfileName;
  }

  /** 获取当前活跃配置 */
  static async getActiveProfile(): Promise<CustomKeyProfile> {
    await CustomKeyStore.ensureInit();
    const profile = CustomKeyStore.profiles!.find(p => p.name === CustomKeyStore.activeProfileName);
    return profile ?? CustomKeyStore.profiles![0];
  }

  /** 切换到指定配置 */
  static async switchProfile(name: string): Promise<CustomKeyProfile | null> {
    await CustomKeyStore.ensureInit();
    const profile = CustomKeyStore.profiles!.find(p => p.name === name);
    if (!profile) return null;
    CustomKeyStore.activeProfileName = name;
    await PreferencesUtil.put(STORAGE_KEY_ACTIVE, name);
    return profile;
  }

  /** 创建新配置 */
  static async createProfile(name: string): Promise<CustomKeyProfile | null> {
    await CustomKeyStore.ensureInit();
    if (CustomKeyStore.profiles!.find(p => p.name === name)) {
      return null; // 名称重复
    }
    const profile = createDefaultProfile(name);
    CustomKeyStore.profiles!.push(profile);
    CustomKeyStore.activeProfileName = name;
    await CustomKeyStore.save();
    return profile;
  }

  /** 删除配置（不允许删除最后一个） */
  static async deleteProfile(name: string): Promise<boolean> {
    await CustomKeyStore.ensureInit();
    if (CustomKeyStore.profiles!.length <= 1) return false;
    const idx = CustomKeyStore.profiles!.findIndex(p => p.name === name);
    if (idx === -1) return false;
    CustomKeyStore.profiles!.splice(idx, 1);
    if (CustomKeyStore.activeProfileName === name) {
      CustomKeyStore.activeProfileName = CustomKeyStore.profiles![0].name;
    }
    await CustomKeyStore.save();
    return true;
  }

  /** 重命名配置 */
  static async renameProfile(oldName: string, newName: string): Promise<boolean> {
    await CustomKeyStore.ensureInit();
    if (CustomKeyStore.profiles!.find(p => p.name === newName)) return false;
    const profile = CustomKeyStore.profiles!.find(p => p.name === oldName);
    if (!profile) return false;
    profile.name = newName;
    if (CustomKeyStore.activeProfileName === oldName) {
      CustomKeyStore.activeProfileName = newName;
    }
    await CustomKeyStore.save();
    return true;
  }

  // ── 按键管理 ──

  /** 获取当前配置的所有按键 */
  static async getKeys(): Promise<CustomKeyDef[]> {
    const profile = await CustomKeyStore.getActiveProfile();
    return profile.keys;
  }

  /** 添加按键到当前配置 */
  static async addKey(key: CustomKeyDef): Promise<void> {
    const profile = await CustomKeyStore.getActiveProfile();
    profile.keys.push(key);
    await CustomKeyStore.save();
  }

  /** 更新按键 */
  static async updateKey(key: CustomKeyDef): Promise<void> {
    const profile = await CustomKeyStore.getActiveProfile();
    const idx = profile.keys.findIndex(k => k.id === key.id);
    if (idx !== -1) {
      profile.keys[idx] = key;
      await CustomKeyStore.save();
    }
  }

  /** 删除按键 */
  static async deleteKey(keyId: string): Promise<void> {
    const profile = await CustomKeyStore.getActiveProfile();
    const idx = profile.keys.findIndex(k => k.id === keyId);
    if (idx !== -1) {
      profile.keys.splice(idx, 1);
      await CustomKeyStore.save();
    }
  }

  /** 批量更新按键（编辑模式完成后一次性保存） */
  static async saveKeys(keys: CustomKeyDef[]): Promise<void> {
    const profile = await CustomKeyStore.getActiveProfile();
    profile.keys = keys;
    await CustomKeyStore.save();
  }

  // ── 导入/导出 ──

  /** 导出当前配置为 JSON 字符串 */
  static async exportProfile(): Promise<string> {
    const profile = await CustomKeyStore.getActiveProfile();
    const exportData: ExportData = {
      version: 1,
      profile: profile,
    };
    return JSON.stringify(exportData);
  }

  /** 从 JSON 字符串导入配置 */
  static async importProfile(json: string): Promise<boolean> {
    try {
      const data = JSON.parse(json) as ExportData;
      if (!data.profile || !data.profile.name || !Array.isArray(data.profile.keys)) {
        return false;
      }
      // 避免名称冲突
      await CustomKeyStore.ensureInit();
      let name = data.profile.name;
      let suffix = 1;
      while (CustomKeyStore.profiles!.find(p => p.name === name)) {
        name = `${data.profile.name} (${suffix++})`;
      }
      data.profile.name = name;
      // 导入数据也可能是旧的绝对坐标格式，做一次迁移
      CustomKeyStore.migrateProfileKeys(data.profile);
      CustomKeyStore.profiles!.push(data.profile);
      CustomKeyStore.activeProfileName = name;
      await CustomKeyStore.save();
      return true;
    } catch (e) {
      console.error('[CustomKeyStore] import failed:', JSON.stringify(e));
      return false;
    }
  }
}
