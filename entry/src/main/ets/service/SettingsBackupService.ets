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
 * 备份文件保存在用户公共存储（如 Documents），不随应用卸载删除。
 */

import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { promptAction } from '@kit.ArkUI';

const TAG = '[SettingsBackup]';

/** 备份文件格式 */
interface BackupData {
  version: number;
  timestamp: string;
  settings: Record<string, string | number | boolean>;
  customKeyProfiles?: string;
  customKeyActiveProfile?: string;
  customKeyGameProfiles?: string;
  savedComputers?: string;
}

export class SettingsBackupService {

  /**
   * 导出所有设置为 JSON 字符串
   */
  static async exportAll(): Promise<string> {
    const prefs = await PreferencesUtil.getPreferences();
    const all = await prefs.getAll();

    const settings: Record<string, string | number | boolean> = {};
    const entries = Object.entries(all);
    for (const [key, value] of entries) {
      if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
        settings[key] = value;
      }
    }

    // 自定义按键和电脑列表已经存在 settings 中（以 JSON string 形式）
    // 它们的 key 分别是:
    //   custom_key_profiles, custom_key_active_profile, custom_key_game_profiles
    //   saved_computers
    // 通过 getAll() 已经全部包含，无需单独处理

    const backup: BackupData = {
      version: 1,
      timestamp: new Date().toISOString(),
      settings: settings,
    };

    return JSON.stringify(backup, null, 2);
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
      let count = 0;

      const entries = Object.entries(backup.settings);
      for (const [key, value] of entries) {
        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
          await prefs.put(key, value);
          count++;
        }
      }

      await prefs.flush();
      console.info(`${TAG} 已导入 ${count} 项设置`);
      return count;
    } catch (e) {
      console.error(`${TAG} 导入失败: ${JSON.stringify(e)}`);
      return -1;
    }
  }

  /**
   * 通过系统文件选择器导出设置到文件
   */
  static async exportToFile(): Promise<boolean> {
    try {
      const json = await SettingsBackupService.exportAll();

      const documentPicker = new picker.DocumentViewPicker();
      const saveOptions = new picker.DocumentSaveOptions();
      const dateStr = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
      saveOptions.newFileNames = [`moonlight-backup-${dateStr}.json`];
      saveOptions.fileSuffixChoices = ['.json'];
      const uris = await documentPicker.save(saveOptions);

      if (uris && uris.length > 0) {
        const file = fileIo.openSync(uris[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, json);
        fileIo.closeSync(file);

        const entries = Object.entries(JSON.parse(json).settings || {});
        promptAction.showToast({ message: `已导出 ${entries.length} 项设置`, duration: 2000 });
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
   * @returns 是否成功导入
   */
  static async importFromFile(): Promise<boolean> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const selectOptions = new picker.DocumentSelectOptions();
      selectOptions.maxSelectNumber = 1;
      selectOptions.fileSuffixFilters = ['.json'];
      const uris = await documentPicker.select(selectOptions);

      if (uris && uris.length > 0) {
        const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
        const stat = fileIo.statSync(file.fd);
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buf);
        fileIo.closeSync(file);

        const json = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
        const count = await SettingsBackupService.importAll(json);

        if (count >= 0) {
          promptAction.showToast({ message: `已导入 ${count} 项设置，重启应用生效`, duration: 3000 });
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

  /**
   * 检查当前是否有已保存的设置（用于判断是否为全新安装）
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
}
