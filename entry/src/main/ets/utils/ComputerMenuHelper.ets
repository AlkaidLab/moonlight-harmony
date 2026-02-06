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
 * 电脑菜单辅助类
 * 
 * 负责生成电脑操作菜单的配置
 */
import { OptionItem } from '../components/OptionPickerDialog';
import { ObservableComputer } from '../viewmodel/ComputerViewModel';

/**
 * 菜单动作回调接口
 */
export interface ComputerMenuCallbacks {
  /** 发送唤醒包 */
  onWake: (computer: ObservableComputer) => void;
  /** 配对 */
  onPair: (computer: ObservableComputer) => void;
  /** 恢复游戏 */
  onResumeGame: (computer: ObservableComputer) => void;
  /** 退出游戏 */
  onQuitGame: (computer: ObservableComputer) => void;
  /** 应用列表 */
  onAppList: (computer: ObservableComputer) => void;
  /** 取消配对 */
  onUnpair: (computer: ObservableComputer) => void;
  /** 休眠电脑 */
  onSleep: (computer: ObservableComputer) => void;
  /** 网络测试 */
  onTestNetwork: (computer: ObservableComputer) => void;
  /** 查看详情 */
  onShowDetails: (computer: ObservableComputer) => void;
  /** 删除电脑 */
  onDelete: (computer: ObservableComputer) => void;
}

/**
 * 菜单生成结果
 */
export interface ComputerMenuResult {
  /** 菜单选项 */
  options: OptionItem[];
  /** 动作映射 */
  actionMap: Map<string, () => void>;
}

/**
 * 电脑菜单辅助类
 */
export class ComputerMenuHelper {
  /**
   * 生成电脑操作菜单
   */
  static generateMenu(computer: ObservableComputer, callbacks: ComputerMenuCallbacks): ComputerMenuResult {
    const options: OptionItem[] = [];
    const actionMap = new Map<string, () => void>();
    let actionIndex = 0;
    
    // 离线状态 - 显示唤醒选项
    if (!computer.isOnline) {
      const key = `action_${actionIndex++}`;
      actionMap.set(key, () => callbacks.onWake(computer));
      options.push({
        title: '发送唤醒包 (WOL)',
        subtitle: '尝试通过网络唤醒电脑',
        value: key
      });
    } 
    // 在线未配对 - 显示配对选项
    else if (!computer.isPaired) {
      const key = `action_${actionIndex++}`;
      actionMap.set(key, () => callbacks.onPair(computer));
      options.push({
        title: '配对',
        subtitle: '与电脑建立安全连接',
        value: key
      });
    } 
    // 已配对
    else {
      // 正在游戏 - 显示游戏相关选项
      if (computer.isGaming) {
        const resumeKey = `action_${actionIndex++}`;
        actionMap.set(resumeKey, () => callbacks.onResumeGame(computer));
        options.push({
          title: '恢复游戏',
          subtitle: '继续之前的游戏会话',
          value: resumeKey
        });
        
        const quitKey = `action_${actionIndex++}`;
        actionMap.set(quitKey, () => callbacks.onQuitGame(computer));
        options.push({
          title: '退出游戏',
          subtitle: '结束当前运行的游戏',
          value: quitKey
        });
      }
      
      // 应用列表
      const appListKey = `action_${actionIndex++}`;
      actionMap.set(appListKey, () => callbacks.onAppList(computer));
      options.push({
        title: '应用列表',
        subtitle: '查看可串流的应用',
        value: appListKey
      });
      
      // 取消配对
      const unpairKey = `action_${actionIndex++}`;
      actionMap.set(unpairKey, () => callbacks.onUnpair(computer));
      options.push({
        title: '取消配对',
        subtitle: '断开与电脑的配对',
        value: unpairKey
      });
      
      // 休眠电脑
      const sleepKey = `action_${actionIndex++}`;
      actionMap.set(sleepKey, () => callbacks.onSleep(computer));
      options.push({
        title: '休眠电脑',
        subtitle: '让电脑进入休眠状态',
        value: sleepKey
      });
    }
    
    // 通用选项
    const networkKey = `action_${actionIndex++}`;
    actionMap.set(networkKey, () => callbacks.onTestNetwork(computer));
    options.push({
      title: '网络测试',
      subtitle: '测试与电脑的网络连接',
      value: networkKey
    });
    
    const detailsKey = `action_${actionIndex++}`;
    actionMap.set(detailsKey, () => callbacks.onShowDetails(computer));
    options.push({
      title: '查看详情',
      subtitle: '显示电脑的详细信息',
      value: detailsKey
    });
    
    const deleteKey = `action_${actionIndex++}`;
    actionMap.set(deleteKey, () => callbacks.onDelete(computer));
    options.push({
      title: '删除电脑',
      subtitle: '从列表中移除此电脑',
      value: deleteKey
    });
    
    return { options, actionMap };
  }
}
