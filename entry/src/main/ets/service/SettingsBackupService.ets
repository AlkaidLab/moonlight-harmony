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
 * 设置备份与恢复服务
 *
 * 将全部用户设置（Preferences + 自定义按键 + 电脑列表）导出为 JSON 文件，
 * 支持通过系统 FilePicker 保存/读取，实现跨版本（侧载/测试/正式）数据迁移。
 *
 * 自动备份模式：
 *   1. 用户首次通过 FilePicker 选择保存位置
 *   2. 调用 persistPermission 持久化文件访问权限
 *   3. 之后每次设置变更自动静默写入，无需用户交互
 *   4. 卸载重装后文件保留，但权限丢失，需用户选一次文件恢复
 */

import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import fileShare from '@ohos.fileshare';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { promptAction } from '@kit.ArkUI';
import { CryptoService } from './CryptoService';
import { NvHttp } from './NvHttp';
import { ComputerManager } from './ComputerManager';

const TAG = '[SettingsBackup]';

/** 存储自动备份 URI 的 Preferences key */
const AUTO_BACKUP_URI_KEY = 'settings_auto_backup_uri';

/** 不参与导出的内部 key */
const INTERNAL_KEYS: string[] = [AUTO_BACKUP_URI_KEY, 'backup_restore_prompted'];

/** 备份文件格式 */
interface BackupData {
  version: number;
  timestamp: string;
  settings: Record<string, string | number | boolean>;
  /** 客户端 SSL 证书 PEM（v2 新增） */
  clientCert?: string;
  /** 客户端 SSL 私钥 PEM（v2 新增） */
  clientKey?: string;
  /** 客户端唯一标识（v2 新增） */
  uniqueId?: string;
  /** 快捷键配置（独立 Preferences 存储，v2 新增） */
  shortcutConfig?: Record<string, string | number | boolean>;
}

/** 自动备份防抖定时器 */
let autoSaveTimer: number | undefined;

export class SettingsBackupService {

  /**
   * 导出所有设置为 JSON 字符串
   */
  static async exportAll(): Promise<string> {
    const prefs = await PreferencesUtil.getPreferences();
    const allObj = await prefs.getAll();
    // 转为可索引的 Record（getAll 返回 Object，ArkTS 不支持直接索引访问）
    const all = JSON.parse(JSON.stringify(allObj)) as Record<string, string | number | boolean>;

    const settings: Record<string, string | number | boolean> = {};
    const keys = Object.keys(all);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = all[key];
      // 跳过内部 key（不需要导出到备份文件中）
      if (INTERNAL_KEYS.includes(key)) continue;
      if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
        settings[key] = value;
      }
    }

    const backup: BackupData = {
      version: 2,
      timestamp: new Date().toISOString(),
      settings: settings,
    };

    // 读取客户端 SSL 证书/私钥/唯一标识（用于恢复配对关系）
    const filesDir = PreferencesUtil.getFilesDir();
    if (filesDir) {
      backup.clientCert = SettingsBackupService.readFileText(`${filesDir}/client_cert.pem`);
      backup.clientKey = SettingsBackupService.readFileText(`${filesDir}/client_key.pem`);
     

    // 读取快捷键配置（独立 Preferences 存储）
    const ctx = PreferencesUtil.getContext();
    if (ctx) {
      try {
        const shortcutPrefs = await preferences.getPreferences(ctx, 'shortcut_config');
        const shortcutAll = await shortcutPrefs.getAll();
        backup.shortcutConfig = JSON.parse(JSON.stringify(shortcutAll)) as Record<string, string | number | boolean>;
      } catch {
        // 快捷键配置可能不存在，忽略
      }
    } backup.uniqueId = SettingsBackupService.readFileText(`${filesDir}/unique_id.txt`);
    }

    return JSON.stringify(backup, null, 2);
  }

  /**
   * 读取文本文件内容，失败返回 undefined
   */
  private static readFileText(path: string): string | undefined {
    try {
      if (!fileIo.accessSync(path)) return undefined;
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      return new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
    } catch {
      return undefined;
    }
  }

  /**
   * 写入文本文件内容
   */
  private static writeFileText(path: string, content: string): void {
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const encoded = new util.TextEncoder().encodeInto(content);
      fileIo.writeSync(file.fd, encoded.buffer);
      fileIo.closeSync(file);
    } catch (e) {
      console.error(`${TAG} 写入文件失败 ${path}: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 从 JSON 字符串导入所有设置
   * @returns 导入的设置项数量，失败返回 -1
   */
  static async importAll(json: string): Promise<number> {
    try {
      const backup = JSON.parse(json) as BackupData;
      if (!backup.version || !backup.settings) {
        console.error(`${TAG} 无效的备份文件格式`);
        return -1;
      }

      const prefs = await PreferencesUtil.getPreferences();
      
      // 保留内部 key 的值
      const preserved: Record<string, string | number | boolean> = {};
      for (const key of INTERNAL_KEYS) {
        try {
          const val = await prefs.get(key, undefined);
          if (val !== undefined) {
            preserved[key] = val as string | number | boolean;
          }
        } catch {
          // ignore
        }
      }
      
      // 清除所有旧数据再导入，避免残留 key 产生混合数据
      await prefs.clear();
      
      // 恢复内部 key
      const preservedKeys = Object.keys(preserved);
      for (let i = 0; i < preservedKeys.length; i++) {
        await prefs.put(preservedKeys[i], preserved[preservedKeys[i]]);
      }
      
      let count = 0;
      const settingKeys = Object.keys(backup.settings);
      for (let i = 0; i < settingKeys.length; i++) {
        const key = settingKeys[i];
        const value = backup.settings[key];
        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
          await prefs.put(key, value);
          count++;
        }
      }

      await prefs.flush();

      // 恢复客户端 SSL 证书/私钥/唯一标识（保持配对关系）
      const filesDir = PreferencesUtil.getFilesDir();
      if (filesDir) {
        if (backup.clientCert) {
          SettingsBackupService.writeFileText(`${filesDir}/client_cert.pem`, backup.clientCert);
          console.info(`${TAG} 已恢复客户端证书`);
        }
        if (backup.clientKey) {
          SettingsBackupService.writeFileText(`${filesDir}/client_key.pem`, backup.clientKey);
          console.info(`${TAG} 已恢复客户端私钥`);
        }
        if (backup.uniqueId) {
          SettingsBackupService.writeFileText(`${filesDir}/unique_id.txt`, backup.uniqueId);
          console.info(`${TAG} 已恢复客户端唯一标识`);
        }
      }

      // 恢复快捷键配置（独立 Preferences 存储）
      if (backup.shortcutConfig) {
        const ctx = PreferencesUtil.getContext();
        if (ctx) {
          try {
            const shortcutPrefs = await preferences.getPreferences(ctx, 'shortcut_config');
            await shortcutPrefs.clear();
            const scKeys = Object.keys(backup.shortcutConfig);
            for (let i = 0; i < scKeys.length; i++) {
              const scKey = scKeys[i];
              const scVal = backup.shortcutConfig[scKey];
              if (typeof scVal === 'string' || typeof scVal === 'number' || typeof scVal === 'boolean') {
                await shortcutPrefs.put(scKey, scVal);
              }
            }
            await shortcutPrefs.flush();
            console.info(`${TAG} 已恢复快捷键配置 (${scKeys.length} 项)`);
          } catch (e) {
            console.warn(`${TAG} 恢复快捷键配置失败: ${JSON.stringify(e)}`);
          }
        }
      }

      console.info(`${TAG} 已导入 ${count} 项设置`);
      return count;
    } catch (e) {
      console.error(`${TAG} 导入失败: ${JSON.stringify(e)}`);
      return -1;
    }
  }

  // ── 手动导出/导入（通过 FilePicker）──

  /**
   * 通过系统文件选择器导出设置到文件
   */
  static async exportToFile(): Promise<boolean> {
    try {
      const json = await SettingsBackupService.exportAll();

      // 加密备份数据
      const encrypted = await CryptoService.encrypt(json);

      const documentPicker = new picker.DocumentViewPicker();
      const saveOptions = new picker.DocumentSaveOptions();
      const dateStr = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
      saveOptions.newFileNames = [`moonlight-backup-${dateStr}.mlbk`];
      saveOptions.fileSuffixChoices = ['.mlbk'];
      const uris = await documentPicker.save(saveOptions);

      if (uris && uris.length > 0) {
        const file = fileIo.openSync(uris[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, encrypted.buffer as ArrayBuffer);
        fileIo.closeSync(file);

        const parsed = JSON.parse(json) as BackupData;
        const settingsCount = Object.keys(parsed.settings).length;
        promptAction.showToast({ message: `已导出 ${settingsCount} 项设置（已加密）`, duration: 2000 });
        return true;
      }
    } catch (e) {
      console.error(`${TAG} 导出到文件失败: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '导出失败', duration: 2000 });
    }
    return false;
  }

  /**
   * 通过系统文件选择器从文件导入设置
   */
  static async importFromFile(): Promise<boolean> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const selectOptions = new picker.DocumentSelectOptions();
      selectOptions.maxSelectNumber = 1;
      selectOptions.fileSuffixFilters = ['.mlbk', '.json'];
      const uris = await documentPicker.select(selectOptions);

      if (uris && uris.length > 0) {
        const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
        const stat = fileIo.statSync(file.fd);
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buf);
        fileIo.closeSync(file);

        const rawData = new Uint8Array(buf);
        let json: string;
        if (CryptoService.isEncrypted(rawData)) {
          try {
            json = await CryptoService.decrypt(rawData);
          } catch (e) {
            console.error(`${TAG} 解密失败: ${JSON.stringify(e)}`);
            promptAction.showToast({ message: '解密失败：密钥不匹配或文件损坏', duration: 3000 });
            return false;
          }
        } else {
          json = new util.TextDecoder('utf-8').decodeToString(rawData);
        }
        const count = await SettingsBackupService.importAll(json);

        if (count >= 0) {
          // 重新加载内存状态，避免 ComputerManager 轮询覆盖已恢复的数据
          await SettingsBackupService.reloadInMemoryState();
          promptAction.showToast({ message: `已导入 ${count} 项设置`, duration: 2000 });
          return true;
        } else {
          promptAction.showToast({ message: '导入失败：文件格式无效', duration: 2000 });
        }
      }
    } catch (e) {
      console.error(`${TAG} 从文件导入失败: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '导入失败', duration: 2000 });
    }
    return false;
  }

  // ── 自动备份 ──

  /**
   * 启用自动备份：通过 FilePicker 选择保存位置，持久化 URI 权限
   */
  static async enableAutoBackup(): Promise<boolean> {
    try {
      const json = await SettingsBackupService.exportAll();

      const documentPicker = new picker.DocumentViewPicker();
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = ['moonlight-settings.mlbk'];
      saveOptions.fileSuffixChoices = ['.mlbk'];
      const uris = await documentPicker.save(saveOptions);

      if (uris && uris.length > 0) {
        const uri = uris[0];

        // 加密并写入当前设置
        const encrypted = await CryptoService.encrypt(json);
        const file = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, encrypted.buffer as ArrayBuffer);
        fileIo.closeSync(file);

        // 持久化文件 URI 访问权限
        try {
          const policies: fileShare.PolicyInfo[] = [{
            uri: uri,
            operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE,
          }];
          await fileShare.persistPermission(policies);
          console.info(`${TAG} URI 权限已持久化: ${uri}`);
        } catch (e) {
          console.warn(`${TAG} persistPermission 失败（可能不支持），仍保存 URI: ${JSON.stringify(e)}`);
        }

        // 保存 URI 到 Preferences
        await PreferencesUtil.put(AUTO_BACKUP_URI_KEY, uri);
        promptAction.showToast({ message: '自动备份已启用', duration: 2000 });
        return true;
      }
    } catch (e) {
      console.error(`${TAG} 启用自动备份失败: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '启用失败', duration: 2000 });
    }
    return false;
  }

  /**
   * 关闭自动备份
   */
  static async disableAutoBackup(): Promise<void> {
    const uri = await PreferencesUtil.get<string>(AUTO_BACKUP_URI_KEY, '');
    if (uri) {
      try {
        await fileShare.revokePermission([{
          uri: uri,
          operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE,
        }]);
      } catch {
        // 忽略撤销失败
      }
    }
    await PreferencesUtil.put(AUTO_BACKUP_URI_KEY, '');
    promptAction.showToast({ message: '自动备份已关闭', duration: 2000 });
  }

  /**
   * 是否已启用自动备份
   */
  static async isAutoBackupEnabled(): Promise<boolean> {
    const uri = await PreferencesUtil.get<string>(AUTO_BACKUP_URI_KEY, '');
    return uri.length > 0;
  }

  /**
   * 触发自动备份（防抖 3 秒）
   * 调用此方法后 3 秒内如果再次调用，会重置计时器。
   */
  static scheduleAutoSave(): void {
    if (autoSaveTimer !== undefined) {
      clearTimeout(autoSaveTimer);
    }
    autoSaveTimer = setTimeout(async () => {
      autoSaveTimer = undefined;
      await SettingsBackupService.doAutoSave();
    }, 3000);
  }

  /**
   * 执行自动备份（静默写入已授权的文件）
   */
  private static async doAutoSave(): Promise<void> {
    const uri = await PreferencesUtil.get<string>(AUTO_BACKUP_URI_KEY, '');
    if (!uri) return;

    try {
      // 尝试激活持久化权限
      try {
        await fileShare.activatePermission([{
          uri: uri,
          operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE,
        }]);
      } catch {
        // activatePermission 失败不阻断，直接尝试写入
      }

      const json = await SettingsBackupService.exportAll();
      const encrypted = await CryptoService.encrypt(json);
      const file = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, encrypted.buffer as ArrayBuffer);
      fileIo.closeSync(file);
      console.info(`${TAG} 自动备份完成（已加密）`);
    } catch (e) {
      console.warn(`${TAG} 自动备份失败（权限可能已过期）: ${JSON.stringify(e)}`);
      // 不弹 toast，静默失败
    }
  }

  /**
   * 检查当前是否有已保存的设置
   */
  static async hasSettings(): Promise<boolean> {
    try {
      const prefs = await PreferencesUtil.getPreferences();
      const all = await prefs.getAll();
      return Object.keys(all).length > 0;
    } catch {
      return false;
    }
  }

  /**
   * 导入后重新加载内存状态
   * 清除 NvHttp 缓存、重新加载 ComputerManager 的电脑列表，
   * 避免后台轮询用旧的内存状态覆盖已恢复的持久化数据。
   */
  private static async reloadInMemoryState(): Promise<void> {
    try {
      // 1. 清除 NvHttp 的 uniqueId 静态缓存，下次请求从文件重读
      NvHttp.clearCachedUniqueId();

      // 2. 重新加载 ComputerManager 的电脑列表
      const mgr = ComputerManager.getInstance();
      await mgr.reloadFromPersistence();

      console.info(`${TAG} 内存状态已重新加载`);
    } catch (e) {
      console.warn(`${TAG} 重新加载内存状态失败: ${JSON.stringify(e)}`);
    }
  }
}
