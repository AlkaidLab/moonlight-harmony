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

import { PreferencesUtil } from '../../utils/PreferencesUtil';
import { display } from '@kit.ArkUI';
import { UI } from '../../common/UI';
import { SettingsBackupService } from '../SettingsBackupService';
import { ToastQueue } from '../../utils/ToastQueue';
import {
  CustomKeyProfile,
  CustomKeyDef,
  createDefaultProfile,
  cloneKeyDef,
  generateKeyId,
  KeyAction,
} from './CustomKeyTypes';
import { Logger } from '../../common/Logger';

/** 导出数据格式 */
interface ExportData {
  version: number;
  profile: CustomKeyProfile;
}

/** 存储键 */
const STORAGE_KEY_PROFILES = 'custom_key_profiles';
const STORAGE_KEY_ACTIVE = 'custom_key_active_profile';
const STORAGE_KEY_GAME_PROFILES = 'custom_key_game_profiles';

/**
 * 自定义按键配置存储管理
 *
 * 负责配置的 CRUD 和持久化。所有方法都是 async 的。
 */
export class CustomKeyStore {

  // ── 缓存 ──
  private static profiles: CustomKeyProfile[] | null = null;
  private static activeProfileName: string = '';
  /** 游戏→配置映射缓存: { "appId": "profileName" } */
  private static gameProfiles: Record<string, string> | null = null;
  /** 初始化读取失败标志：置位期间拒绝持久化，避免用内存默认配置覆盖盘上原数据 */
  private static loadFailed: boolean = false;

  /**
   * 初始化：从持久化加载数据
   */
  static async init(): Promise<void> {
    try {
      // 直连 prefs 读取：读取失败（数据库异常）落入外层 catch 走内存默认且不落盘，
      // 与"键不存在"（正常首次使用，建默认配置并保存）区分开
      const prefs = await PreferencesUtil.getPreferences();
      const json = await prefs.get(STORAGE_KEY_PROFILES, '') as string;
      if (json) {
        CustomKeyStore.profiles = JSON.parse(json) as CustomKeyProfile[];
      } else {
        CustomKeyStore.profiles = [];
      }
      CustomKeyStore.activeProfileName = await prefs.get(STORAGE_KEY_ACTIVE, '') as string;

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
        Logger.info('CustomKeyStore', '[CustomKeyStore] 坐标迁移完成: absolute vp → percent');
      }

      // 加载游戏→配置映射
      const gameJson = await prefs.get(STORAGE_KEY_GAME_PROFILES, '') as string;
      if (gameJson) {
        CustomKeyStore.gameProfiles = JSON.parse(gameJson) as Record<string, string>;
      } else {
        CustomKeyStore.gameProfiles = {};
      }
      CustomKeyStore.loadFailed = false;
    } catch (e) {
      Logger.error('CustomKeyStore', '[CustomKeyStore] init failed:', JSON.stringify(e));
      CustomKeyStore.profiles = [createDefaultProfile('默认')];
      CustomKeyStore.activeProfileName = '默认';
      // 读取失败：内存态仅供本次会话展示，禁止写盘以防覆盖原有配置
      CustomKeyStore.loadFailed = true;
    }
  }

  /** 确保已初始化 */
  private static async ensureInit(): Promise<void> {
    if (CustomKeyStore.profiles === null) {
      await CustomKeyStore.init();
    }
  }

  /**
   * 持久化到 Preferences
   * @returns 是否成功落盘（读取失败保护期或写入失败返回 false）
   */
  private static async save(): Promise<boolean> {
    if (CustomKeyStore.loadFailed) {
      Logger.warn('CustomKeyStore', '[CustomKeyStore] save 拒绝: 初始化读取失败，写盘会覆盖原数据，待下次启动重试读取');
      ToastQueue.show({ message: '配置读取异常，本次修改暂不会保存（已保护原数据）', duration: 3000 });
      return false;
    }
    const json = JSON.stringify(CustomKeyStore.profiles);
    try {
      await PreferencesUtil.put(STORAGE_KEY_PROFILES, json);
      await PreferencesUtil.put(STORAGE_KEY_ACTIVE, CustomKeyStore.activeProfileName);
      SettingsBackupService.scheduleAutoSave();
      return true;
    } catch (e) {
      // 保存失败时跳过备份调度（避免备份到旧数据），编辑操作不被打断
      Logger.error('CustomKeyStore', '[CustomKeyStore] save failed:', JSON.stringify(e));
      ToastQueue.show({ message: '配置保存失败，重启后可能丢失本次修改', duration: 3000 });
      return false;
    }
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
    let displayInfo: display.Display;
    try {
      displayInfo = display.getDefaultDisplaySync();
    } catch (e) {
      // 获取屏幕信息失败：跳过本次迁移，保留旧数据等下次启动重试
      return false;
    }
    const screenWVp = UI.get().px2vp(displayInfo.width);
    const screenHVp = UI.get().px2vp(displayInfo.height);
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
    let displayInfo: display.Display;
    try {
      displayInfo = display.getDefaultDisplaySync();
    } catch (e) {
      // 获取屏幕信息失败：跳过本档案迁移，保留旧数据等下次启动重试
      return false;
    }
    const screenWVp = UI.get().px2vp(displayInfo.width);
    const screenHVp = UI.get().px2vp(displayInfo.height);
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

  /** 档案中是否仍有未迁移的旧绝对坐标按键（迁移失败的标志） */
  private static hasLegacyKeys(profile: CustomKeyProfile): boolean {
    return profile.keys.some(k => k.x !== undefined && k.x > 1 && (k.xPercent === undefined || k.xPercent === 0));
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

  /** 循环切换到下一个配置，并返回切换后的配置 */
  static async cycleNextProfile(): Promise<CustomKeyProfile | null> {
    await CustomKeyStore.ensureInit();
    if (CustomKeyStore.profiles!.length <= 1) return null;
    const currentIdx = CustomKeyStore.profiles!.findIndex(p => p.name === CustomKeyStore.activeProfileName);
    const nextIdx = (currentIdx + 1) % CustomKeyStore.profiles!.length;
    const next = CustomKeyStore.profiles![nextIdx];
    CustomKeyStore.activeProfileName = next.name;
    await PreferencesUtil.put(STORAGE_KEY_ACTIVE, next.name);
    return next;
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

  /** 复制当前活跃配置为新配置并切换过去 */
  static async duplicateProfile(newName: string): Promise<CustomKeyProfile | null> {
    await CustomKeyStore.ensureInit();
    if (CustomKeyStore.profiles!.find(p => p.name === newName)) {
      return null; // 名称重复
    }
    const source = await CustomKeyStore.getActiveProfile();
    const cloned: CustomKeyProfile = {
      name: newName,
      keys: source.keys.map(k => {
        const copy = cloneKeyDef(k);
        copy.id = generateKeyId();
        return copy;
      }),
    };
    CustomKeyStore.profiles!.push(cloned);
    CustomKeyStore.activeProfileName = newName;
    await CustomKeyStore.save();
    return cloned;
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
      // 导入数据也可能是旧的绝对坐标格式，做一次迁移；
      // 迁移失败（屏幕信息暂不可用）时中止导入，避免旧坐标键落 0.5 兜底后永远失去迁移机会
      if (!CustomKeyStore.migrateProfileKeys(data.profile) && CustomKeyStore.hasLegacyKeys(data.profile)) {
        Logger.warn('CustomKeyStore', '[CustomKeyStore] 导入中止: 旧坐标迁移失败，请稍后重试');
        return false;
      }
      CustomKeyStore.profiles!.push(data.profile);
      CustomKeyStore.activeProfileName = name;
      await CustomKeyStore.save();
      return true;
    } catch (e) {
      Logger.error('CustomKeyStore', '[CustomKeyStore] import failed:', JSON.stringify(e));
      return false;
    }
  }

  /**
   * 合并导入：将 JSON 中的按键合并到当前活跃配置
   * 与 importProfile 不同，不创建新配置，而是将按键追加到当前配置中。
   * 每个导入按键分配新 ID，略微偏移位置避免完全重叠。
   * @returns 合并的按键数量，失败返回 -1
   */
  static async mergeImportKeys(json: string): Promise<number> {
    try {
      const data = JSON.parse(json) as ExportData;
      if (!data.profile || !Array.isArray(data.profile.keys) || data.profile.keys.length === 0) {
        return -1;
      }
      // 迁移失败（屏幕信息暂不可用）时中止合并：0.5 兜底坐标一旦写入 xPercent，
      // 下次启动便不再视为旧数据，导入按键位置将无法恢复
      if (!CustomKeyStore.migrateProfileKeys(data.profile) && CustomKeyStore.hasLegacyKeys(data.profile)) {
        Logger.warn('CustomKeyStore', '[CustomKeyStore] 合并导入中止: 旧坐标迁移失败，请稍后重试');
        return -1;
      }
      const profile = await CustomKeyStore.getActiveProfile();
      let count = 0;
      for (const key of data.profile.keys) {
        key.id = generateKeyId();
        // 略微偏移避免完全重叠
        key.xPercent = Math.max(0, Math.min(1, (key.xPercent ?? 0.5) + 0.02));
        key.yPercent = Math.max(0, Math.min(1, (key.yPercent ?? 0.5) + 0.02));
        profile.keys.push(key);
        count++;
      }
      await CustomKeyStore.save();
      return count;
    } catch (e) {
      Logger.error('CustomKeyStore', '[CustomKeyStore] merge import failed:', JSON.stringify(e));
      return -1;
    }
  }

  // ── 游戏→配置自动关联 ──

  /**
   * 获取游戏关联的配置名称。
   * @returns 配置名称，未关联则返回 null
   */
  static async getGameProfileName(appId: number): Promise<string | null> {
    await CustomKeyStore.ensureInit();
    const name = CustomKeyStore.gameProfiles?.[String(appId)];
    if (!name) return null;
    // 验证配置仍然存在
    if (!CustomKeyStore.profiles!.find(p => p.name === name)) {
      CustomKeyStore.gameProfiles![String(appId)] = '';
      await PreferencesUtil.put(STORAGE_KEY_GAME_PROFILES, JSON.stringify(CustomKeyStore.gameProfiles));
      return null;
    }
    return name;
  }

  /**
   * 保存游戏→配置关联
   */
  static async setGameProfile(appId: number, profileName: string): Promise<void> {
    await CustomKeyStore.ensureInit();
    if (!CustomKeyStore.gameProfiles) {
      CustomKeyStore.gameProfiles = {};
    }
    CustomKeyStore.gameProfiles[String(appId)] = profileName;
    await PreferencesUtil.put(STORAGE_KEY_GAME_PROFILES, JSON.stringify(CustomKeyStore.gameProfiles));
  }

  /**
   * 根据游戏自动加载关联配置。
   * 如果该游戏有记忆的配置，自动切换到该配置。
   * @returns 加载的配置，无关联则返回 null（不改变当前配置）
   */
  static async loadGameProfile(appId: number): Promise<CustomKeyProfile | null> {
    const name = await CustomKeyStore.getGameProfileName(appId);
    if (!name) return null;
    // 已经是当前配置则不重复切换
    if (name === CustomKeyStore.activeProfileName) return null;
    return CustomKeyStore.switchProfile(name);
  }
}
