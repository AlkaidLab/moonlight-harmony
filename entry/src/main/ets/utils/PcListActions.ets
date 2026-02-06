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
 * PC 列表页面业务逻辑处理类
 * 
 * 封装电脑相关的业务操作，如唤醒、配对、退出游戏等
 */
import { promptAction } from '@kit.ArkUI';
import { common, bundleManager, Want } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ObservableComputer } from '../viewmodel/ComputerViewModel';
import { ComputerManager } from '../service/ComputerManager';
import { PairingManager, PairState as PMPairState } from '../service/PairingManager';
import { NvHttp } from '../service/NvHttp';
import { PairState, ComputerState } from '../model/ComputerInfo';
import { ConfirmDialogConfig, InfoDialogConfig } from '../components/ConfirmDialog';
import { AppColors } from '../common/Theme';

/**
 * 配对结果
 */
export interface PairResult {
  success: boolean;
  serverCertBase64?: string;
  pairName?: string;
  error?: string;
}

/**
 * 快速串流应用信息
 */
export interface QuickStreamAppInfo {
  appId: number;
  appName: string;
  resume: boolean;
}

/**
 * PC 列表业务逻辑处理类
 */
export class PcListActions {
  private computerManager: ComputerManager;
  private context: common.UIAbilityContext;
  
  constructor(context: common.UIAbilityContext) {
    this.computerManager = ComputerManager.getInstance();
    this.context = context;
  }
  
  /**
   * 获取版本信息
   */
  getVersionInfo(): string {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const versionName = bundleInfo.versionName;
      const versionCode = bundleInfo.versionCode;
      return `版本 ${versionName} (Build ${versionCode})`;
    } catch (err) {
      console.error('获取版本信息失败', err);
      return '版本未知';
    }
  }
  
  /**
   * 打开 URL
   */
  openUrl(url: string): void {
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url
      };
      this.context.startAbility(want);
    } catch (err) {
      console.error('打开 URL 失败', err);
      promptAction.showToast({ message: '无法打开链接' });
    }
  }
  
  /**
   * 加入 QQ 群
   */
  joinQQGroup(key: string): void {
    try {
      const qqUri = `mqqopensdkapi://bizAgent/qm/qr?url=http%3A%2F%2Fqm.qq.com%2Fcgi-bin%2Fqm%2Fqr%3Ffrom%3Dapp%26p%3Dandroid%26jump_from%3Dwebapi%26k%3D${key}`;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: qqUri
      };
      this.context.startAbility(want).catch((err: BusinessError) => {
        console.info('QQ 未安装，打开网页版', err);
        this.openUrl('https://qm.qq.com/cgi-bin/qm/qr?k=' + key);
      });
    } catch (err) {
      console.error('加入 QQ 群失败', err);
      promptAction.showToast({ message: '无法打开 QQ' });
    }
  }
  
  /**
   * 唤醒电脑
   */
  async wakeComputer(computer: ObservableComputer): Promise<boolean> {
    console.info(`PcListActions: wakeComputer - ${computer.name}, MAC: ${computer.macAddress}`);
    
    if (!computer.macAddress || computer.macAddress === '00:00:00:00:00:00') {
      promptAction.showToast({ message: '缺少有效的 MAC 地址。请先在电脑在线时配对，以获取 MAC 地址。' });
      return false;
    }
    
    try {
      await this.computerManager.wakeComputer(computer.uuid);
      promptAction.showToast({ message: '唤醒包已发送' });
      return true;
    } catch (err) {
      const errMessage = err instanceof Error ? err.message : String(err);
      promptAction.showToast({ message: `发送失败: ${errMessage}` });
      return false;
    }
  }
  
  /**
   * 执行配对
   * @returns PIN 码用于显示给用户
   */
  async pairWithComputer(computer: ObservableComputer, pin: string): Promise<PairResult> {
    if (!computer.isOnline) {
      return { success: false, error: '电脑离线，无法配对' };
    }
    
    try {
      console.info(`PcListActions: 开始配对 ${computer.name}, PIN: ${pin}`);
      
      const pairingManager = new PairingManager(computer.address, computer.uuid, this.context, computer.httpPort);
      const result = await pairingManager.pair(pin);
      
      console.info(`PcListActions: 配对结果 ${result.state}`);
      
      if (result.state === PMPairState.PAIRED) {
        let serverCertBase64 = '';
        if (result.serverCert) {
          const buf = buffer.from(result.serverCert);
          serverCertBase64 = buf.toString('base64');
        }
        
        await this.computerManager.updateComputer(computer.uuid, {
          pairState: PairState.PAIRED,
          serverCert: serverCertBase64,
          pairName: result.pairName || ''
        });
        
        return { 
          success: true, 
          serverCertBase64,
          pairName: result.pairName
        };
      } else if (result.state === PMPairState.PIN_WRONG) {
        return { success: false, error: 'PIN 码错误，请重试' };
      } else if (result.state === PMPairState.ALREADY_IN_PROGRESS) {
        return { success: false, error: '另一个设备正在配对中' };
      } else {
        return { success: false, error: `配对失败: ${result.state}` };
      }
    } catch (error) {
      const err = error as Error;
      console.error('PcListActions: 配对异常', err);
      return { success: false, error: `配对失败: ${err.message}` };
    }
  }
  
  /**
   * 退出游戏
   */
  async quitGame(computer: ObservableComputer): Promise<boolean> {
    if (!computer.isOnline || !computer.isPaired) {
      promptAction.showToast({ message: computer.isOnline ? '未配对' : '电脑离线' });
      return false;
    }
    
    if (!computer.runningGameId || computer.runningGameId <= 0) {
      promptAction.showToast({ message: '没有正在运行的游戏' });
      return false;
    }
    
    try {
      promptAction.showToast({ message: '正在退出游戏...' });
      
      const nvHttp = new NvHttp(computer.address, computer.serverCert || null, this.context, computer.httpPort);
      const success = await nvHttp.quitApp();
      
      if (success) {
        promptAction.showToast({ message: '游戏已退出' });
        await this.computerManager.pollComputer(computer.toComputerInfo());
        return true;
      } else {
        promptAction.showToast({ message: '退出游戏失败' });
        return false;
      }
    } catch (error) {
      const err = error as Error;
      promptAction.showToast({ message: `退出游戏失败: ${err.message}` });
      return false;
    }
  }
  
  /**
   * 休眠电脑
   */
  async sleepComputer(computer: ObservableComputer): Promise<boolean> {
    if (!computer.isOnline || !computer.isPaired) {
      promptAction.showToast({ message: computer.isOnline ? '未配对' : '电脑离线' });
      return false;
    }
    
    try {
      promptAction.showToast({ message: '正在发送休眠命令...' });
      
      const nvHttp = new NvHttp(computer.address, computer.serverCert || null, this.context, computer.httpPort);
      const success = await nvHttp.pcSleep();
      
      if (success) {
        promptAction.showToast({ message: '睡眠命令已发送' });
        return true;
      } else {
        promptAction.showToast({ message: '发送睡眠命令失败' });
        return false;
      }
    } catch (error) {
      const err = error as Error;
      promptAction.showToast({ message: `发送睡眠命令失败: ${err.message}` });
      return false;
    }
  }
  
  /**
   * 取消配对
   */
  async unpairComputer(computer: ObservableComputer): Promise<boolean> {
    try {
      await this.computerManager.unpairComputer(computer.uuid);
      promptAction.showToast({ message: '已取消配对' });
      return true;
    } catch (err) {
      promptAction.showToast({ message: '操作失败' });
      return false;
    }
  }
  
  /**
   * 删除电脑
   */
  async deleteComputer(computer: ObservableComputer): Promise<boolean> {
    try {
      await this.computerManager.removeComputer(computer.uuid);
      promptAction.showToast({ message: '已删除' });
      return true;
    } catch (err) {
      promptAction.showToast({ message: '删除失败' });
      return false;
    }
  }
  
  /**
   * 测试网络
   */
  async testNetwork(computer: ObservableComputer): Promise<boolean> {
    try {
      promptAction.showToast({ message: '正在测试网络...' });
      const computerInfo = computer.toComputerInfo();
      await this.computerManager.pollComputer(computerInfo);
      return true;
    } catch (error) {
      return false;
    }
  }
  
  /**
   * 获取电脑详情文本
   */
  getComputerDetailsText(computer: ObservableComputer): string {
    const stateText = computer.isOnline ? '在线' : '离线';
    const pairText = computer.isPaired ? '已配对' : '未配对';
    const gamingText = computer.isGaming ? `正在运行游戏 (ID: ${computer.runningGameId})` : '空闲';
    
    const addressLines: string[] = [];
    const info = computer.toComputerInfo();
    if (info.manualAddress) {
      addressLines.push(`手动地址: ${info.manualAddress}`);
    }
    if (info.localAddress) {
      addressLines.push(`本地地址: ${info.localAddress}`);
    }
    if (info.remoteAddress) {
      addressLines.push(`远程地址: ${info.remoteAddress}`);
    }
    if (info.address && info.address !== info.localAddress && info.address !== info.remoteAddress && info.address !== info.manualAddress) {
      addressLines.push(`当前地址: ${info.address}`);
    }
    if (addressLines.length === 0) {
      addressLines.push(`地址: 未知`);
    }
    
    return [
      `名称: ${computer.name}`,
      `状态: ${stateText}`,
      `配对: ${pairText}`,
      `游戏: ${gamingText}`,
      ``,
      `UUID: ${computer.uuid}`,
      ...addressLines,
      `MAC 地址: ${computer.macAddress || '未知'}`,
      `HTTPS 端口: ${NvHttp.DEFAULT_HTTPS_PORT}`,
      `HTTP 端口: ${info.httpPort || NvHttp.DEFAULT_HTTP_PORT}`,
    ].join('\n');
  }
  
  /**
   * 获取快速串流应用（第一个应用或正在运行的应用）
   */
  async getQuickStreamApp(computer: ObservableComputer): Promise<QuickStreamAppInfo | null> {
    if (!computer.isOnline || !computer.isPaired) {
      promptAction.showToast({ message: '设备未就绪' });
      return null;
    }
    
    try {
      promptAction.showToast({ message: '正在准备串流...', duration: 1000 });
      
      const computerInfo = this.computerManager.getComputer(computer.uuid);
      if (!computerInfo || computerInfo.pairState !== PairState.PAIRED) {
        promptAction.showToast({ message: '设备未配对' });
        return null;
      }
      
      // 如果有正在运行的游戏，直接恢复
      if (computer.runningGameId > 0) {
        const result: QuickStreamAppInfo = { appId: computer.runningGameId, appName: '正在运行', resume: true };
        return result;
      }
      
      // 获取应用列表
      const nvHttp = new NvHttp(computerInfo.address, computerInfo.serverCert, this.context, computerInfo.httpPort);
      const apps = await nvHttp.getAppList();
      
      if (apps.length === 0) {
        promptAction.showToast({ message: '没有可用的应用' });
        return null;
      }
      
      const firstApp = apps[0];
      const appResult: QuickStreamAppInfo = { appId: firstApp.id, appName: firstApp.name, resume: false };
      return appResult;
    } catch (err) {
      promptAction.showToast({ message: `启动失败: ${(err as Error).message}` });
      return null;
    }
  }
  
  /**
   * 生成配对 PIN 码
   */
  generatePin(): string {
    return PairingManager.generatePin();
  }
}
