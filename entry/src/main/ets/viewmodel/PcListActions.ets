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
 * PC 列表业务逻辑处理类
 *
 * 封装电脑相关的业务操作，如唤醒、配对、退出游戏等。
 * 通过回调接口与 UI 层解耦。
 */
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { ObservableComputer } from './ComputerViewModel';
import { ComputerManager } from '../service/ComputerManager';
import { PairingManager, PairState as PMPairState } from '../service/network/PairingManager';
import { NvHttp, ServerInfo } from '../service/streaming/NvHttp';
import { PairState, ComputerState, selectBestAddress, ComputerInfo } from '../model/ComputerInfo';
import { ConfirmDialogConfig, InfoDialogConfig } from '../components/dialogs/ConfirmDialog';
import { AppColors } from '../common/Theme';
import { isLoopbackIPv4 } from '../utils/NetHelper';
import { ToastQueue } from '../utils/ToastQueue';

/** 单地址网络测试结果 */
interface AddressTestResult {
  address: string;
  reachable: boolean;
  latencyMs: number;
  serverInfo: ServerInfo | null;
  error: string;
}

/**
 * UI 回调接口 — PcListActions 操作中需要触发 UI 变更时使用
 */
export interface PcListUICallbacks {
  showConfirmDialog: (config: ConfirmDialogConfig) => void;
  showInfoDialog: (config: InfoDialogConfig) => void;
  syncViewModel: () => void;
  showPinDialog: (pin: string, computerName: string) => void;
  hidePinDialog: () => void;
}

/**
 * 电脑操作业务逻辑
 */
export class PcListActions {
  private computerManager: ComputerManager;
  private ui: PcListUICallbacks;

  constructor(ui: PcListUICallbacks) {
    this.computerManager = ComputerManager.getInstance();
    this.ui = ui;
  }

  /** 处理电脑卡片点击 */
  handleComputerTap(computer: ObservableComputer): void {
    if (!computer.isOnline) {
      return; // 调用方负责显示菜单
    }
    if (computer.isPaired) {
      router.pushUrl({ url: 'pages/AppListPageV2', params: { computerId: computer.uuid } });
      return;
    }
    this.pairWithComputer(computer);
  }

  /** 快速串流 */
  async handleQuickStream(computer: ObservableComputer): Promise<void> {
    if (!computer.isOnline || !computer.isPaired) {
      ToastQueue.show({ message: '设备未就绪' });
      return;
    }
    try {
      ToastQueue.show({ message: '正在准备串流...', duration: 1000 });
      const computerInfo = this.computerManager.getComputer(computer.uuid);
      if (!computerInfo || computerInfo.pairState !== PairState.PAIRED) {
        ToastQueue.show({ message: '设备未配对' });
        return;
      }
      const context = getContext() as common.UIAbilityContext;
      const nvHttp = NvHttp.fromComputer(computerInfo, context);
      const apps = await nvHttp.getAppList();
      if (computer.runningGameId > 0) {
        const runningApp = apps.find(a => a.id === computer.runningGameId);
        const cmdList = runningApp?.cmdList;
        router.pushUrl({
          url: 'pages/StreamPage',
          params: {
            computerId: computer.uuid,
            appId: computer.runningGameId,
            appName: runningApp?.name || '正在运行',
            cmdList: cmdList && cmdList.length > 0 ? JSON.stringify(cmdList) : undefined,
            resume: true
          }
        });
        return;
      }
      if (apps.length === 0) {
        ToastQueue.show({ message: '没有可用的应用' });
        return;
      }
      const firstApp = apps[0];
      router.pushUrl({
        url: 'pages/StreamPage',
        params: {
          computerId: computer.uuid,
          appId: firstApp.id,
          appName: firstApp.name,
          cmdList: firstApp.cmdList && firstApp.cmdList.length > 0 ? JSON.stringify(firstApp.cmdList) : undefined,
          resume: false
        }
      });
    } catch (err) {
      ToastQueue.show({ message: `启动失败: ${(err as Error).message}` });
    }
  }

  /** 配对 */
  async pairWithComputer(computer: ObservableComputer): Promise<void> {
    if (!computer.isOnline) {
      ToastQueue.show({ message: '电脑离线，无法配对' });
      return;
    }
    const pin = PairingManager.generatePin();
    this.ui.showPinDialog(pin, computer.name);
    try {
      const context = getContext() as common.UIAbilityContext;
      const pairingManager = new PairingManager(selectBestAddress(computer), computer.uuid, context, computer.httpPort);
      const result = await pairingManager.pair(pin);
      this.ui.hidePinDialog();
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
        this.ui.syncViewModel();
        ToastQueue.show({ message: '配对成功！' });
        router.pushUrl({ url: 'pages/AppListPageV2', params: { computerId: computer.uuid } });
      } else if (result.state === PMPairState.PIN_WRONG) {
        ToastQueue.show({ message: 'PIN 码错误，请重试' });
      } else if (result.state === PMPairState.ALREADY_IN_PROGRESS) {
        ToastQueue.show({ message: '另一个设备正在配对中' });
      } else {
        ToastQueue.show({ message: `配对失败: ${result.state}` });
      }
    } catch (error) {
      this.ui.hidePinDialog();
      ToastQueue.show({ message: `配对失败: ${(error as Error).message}` });
    }
  }

  /** 唤醒 */
  async wakeComputer(computer: ObservableComputer): Promise<void> {
    if (!computer.macAddress || computer.macAddress === '00:00:00:00:00:00') {
      ToastQueue.show({ message: '缺少有效的 MAC 地址。请先在电脑在线时配对，以获取 MAC 地址。' });
      return;
    }
    try {
      await this.computerManager.wakeComputer(computer.uuid);
      ToastQueue.show({ message: '唤醒包已发送' });
    } catch (err) {
      ToastQueue.show({ message: `发送失败: ${err instanceof Error ? err.message : String(err)}` });
    }
  }

  /** 退出游戏 */
  quitGame(computer: ObservableComputer): void {
    if (!computer.isOnline) {
      ToastQueue.show({ message: '电脑离线，无法退出游戏' });
      return;
    }
    if (!computer.isPaired) {
      ToastQueue.show({ message: '未配对，无法退出游戏' });
      return;
    }
    if (!computer.runningGameId || computer.runningGameId <= 0) {
      ToastQueue.show({ message: '没有正在运行的游戏' });
      return;
    }
    this.ui.showConfirmDialog({
      title: '退出游戏',
      message: '确定要退出当前运行的游戏吗？',
      confirmButton: {
        text: '退出',
        color: AppColors.Error,
        onClick: async () => {
          try {
            ToastQueue.show({ message: '正在退出游戏...' });
            const context = getContext() as common.UIAbilityContext;
            const nvHttp = NvHttp.fromComputer(computer, context);
            const success = await nvHttp.quitApp();
            if (success) {
              ToastQueue.show({ message: '游戏已退出' });
              await this.computerManager.pollComputer(computer.toComputerInfo());
              this.ui.syncViewModel();
            } else {
              ToastQueue.show({ message: '退出游戏失败' });
            }
          } catch (error) {
            ToastQueue.show({ message: `退出游戏失败: ${(error as Error).message}` });
          }
        }
      }
    });
  }

  /** 休眠 */
  sleepComputer(computer: ObservableComputer): void {
    if (!computer.isOnline) {
      ToastQueue.show({ message: '电脑离线，无法休眠' });
      return;
    }
    if (!computer.isPaired) {
      ToastQueue.show({ message: '未配对，无法发送休眠命令' });
      return;
    }
    this.ui.showConfirmDialog({
      title: '休眠电脑',
      message: `确定要让 "${computer.name}" 进入睡眠模式吗？`,
      confirmButton: {
        text: '休眠',
        onClick: async () => {
          try {
            ToastQueue.show({ message: '正在发送休眠命令...' });
            const context = getContext() as common.UIAbilityContext;
            const nvHttp = NvHttp.fromComputer(computer, context);
            const success = await nvHttp.pcSleep();
            if (success) {
              ToastQueue.show({ message: '睡眠命令已发送' });
              computer.state = ComputerState.OFFLINE;
              this.ui.syncViewModel();
            } else {
              ToastQueue.show({ message: '发送睡眠命令失败' });
            }
          } catch (error) {
            ToastQueue.show({ message: `发送睡眠命令失败: ${(error as Error).message}` });
          }
        }
      }
    });
  }

  /** 恢复游戏 */
  async resumeGame(computer: ObservableComputer): Promise<void> {
    // 获取应用列表以获取超级指令（cmdList）
    try {
      const computerInfo = this.computerManager.getComputer(computer.uuid);
      if (computerInfo) {
        const context = getContext() as common.UIAbilityContext;
        const nvHttp = NvHttp.fromComputer(computerInfo, context);
        const apps = await nvHttp.getAppList();
        const runningApp = apps.find(a => a.id === computer.runningGameId);
        const cmdList = runningApp?.cmdList;
        router.pushUrl({
          url: 'pages/StreamPage',
          params: {
            computerId: computer.uuid,
            appId: computer.runningGameId,
            appName: runningApp?.name,
            cmdList: cmdList && cmdList.length > 0 ? JSON.stringify(cmdList) : undefined,
            resume: true
          }
        });
        return;
      }
    } catch {
      // 获取失败时仍然恢复游戏，只是没有超级指令
    }
    router.pushUrl({
      url: 'pages/StreamPage',
      params: { computerId: computer.uuid, appId: computer.runningGameId, resume: true }
    });
  }

  /** 取消配对 */
  unpairComputer(computer: ObservableComputer): void {
    this.ui.showConfirmDialog({
      title: '取消配对',
      message: `确定要取消与 ${computer.name} 的配对吗？`,
      confirmButton: {
        text: '确定',
        color: AppColors.Error,
        onClick: async () => {
          try {
            await this.computerManager.unpairComputer(computer.uuid);
            ToastQueue.show({ message: '已取消配对' });
            this.ui.syncViewModel();
          } catch (_e) {
            ToastQueue.show({ message: '操作失败' });
          }
        }
      }
    });
  }

  /** 删除电脑 */
  deleteComputer(computer: ObservableComputer): void {
    this.ui.showConfirmDialog({
      title: '删除电脑',
      message: `确定要删除 ${computer.name} 吗？`,
      confirmButton: {
        text: '删除',
        color: AppColors.Error,
        onClick: async () => {
          try {
            await this.computerManager.removeComputer(computer.uuid);
            ToastQueue.show({ message: '已删除' });
            this.ui.syncViewModel();
          } catch (_e) {
            ToastQueue.show({ message: '删除失败' });
          }
        }
      }
    });
  }

  /** 测试网络 */
  async testNetwork(computer: ObservableComputer): Promise<void> {
    ToastQueue.show({ message: '正在检测网络…' });
    const computerInfo = computer.toComputerInfo();
    const context = getContext() as common.UIAbilityContext;

    // 收集所有可用地址（过滤 127.x 回环地址）
    const addressSet = new Set<string>();
    const addIfValid = (addr: string | undefined) => {
      if (addr && !isLoopbackIPv4(addr)) addressSet.add(addr);
    };
    addIfValid(computerInfo.preferredAddress);
    addIfValid(computerInfo.manualAddress);
    addIfValid(computerInfo.address);
    addIfValid(computerInfo.localAddress);
    addIfValid(computerInfo.remoteAddress);
    addIfValid(computerInfo.ipv6Address);
    const addresses = Array.from(addressSet);

    if (addresses.length === 0) {
      this.ui.showInfoDialog({ title: '网络测试', content: '没有可用的连接地址' });
      return;
    }

    // 对每个地址分别测试延迟（3 轮取平均）
    const TEST_ROUNDS = 3;
    const results: AddressTestResult[] = [];

    for (const addr of addresses) {
      const roundLatencies: number[] = [];
      let lastServerInfo: ServerInfo | null = null;
      let lastError = '';

      for (let i = 0; i < TEST_ROUNDS; i++) {
        const startMs = Date.now();
        try {
          // 基础可达性使用 HTTP，避免把证书/HTTPS 故障误判成整个网络不可达。
          // 此处刻意不传 context：不配置客户端证书文件时 getServerInfo() 才走 HTTP。
          const nvHttp = NvHttp.fromAddress(addr, computerInfo);
          const info = await nvHttp.getServerInfo();
          if (!info.uniqueId) {
            throw new Error('服务器响应缺少主机 UUID');
          }
          if (info.uniqueId !== computerInfo.uuid && !computerInfo.uuid.startsWith('discovered-')) {
            throw new Error(`主机身份不匹配 (${info.uniqueId})`);
          }
          const elapsed = Date.now() - startMs;
          roundLatencies.push(elapsed);
          lastServerInfo = info;
        } catch (err) {
          lastError = (err as Error).message || String(err);
          break; // 失败则不继续后续轮次
        }
      }

      const avgLatency = roundLatencies.length > 0
        ? roundLatencies.reduce((a, b) => a + b, 0) / roundLatencies.length
        : 0;

      results.push({
        address: addr,
        reachable: roundLatencies.length > 0,
        latencyMs: Math.round(avgLatency),
        serverInfo: lastServerInfo,
        error: lastError
      });
    }

    // 汇总结果
    const lines: string[] = [];
    const reachableResults = results.filter(r => r.reachable);
    const unreachableResults = results.filter(r => !r.reachable);

    const currentPreferred = computerInfo.preferredAddress;

    // 基础信息取延迟最低的可达地址；实际认证链路必须遵循用户锁定地址。
    let displayResult: AddressTestResult | undefined;
    for (const result of reachableResults) {
      if (!displayResult || result.latencyMs < displayResult.latencyMs) {
        displayResult = result;
      }
    }
    const connectionAddress = selectBestAddress(computerInfo);
    const connectionAddressTested = !!connectionAddress && addressSet.has(connectionAddress);
    const connectionAddressUntested = !!connectionAddress && !connectionAddressTested;
    const connectionResult = reachableResults.find(result => result.address === connectionAddress);
    const connectionAddressUnavailable = connectionAddressTested && !connectionResult;

    const serverInfo = displayResult?.serverInfo || undefined;
    let appListReachable: boolean | undefined;
    let appListError = '';
    if (computer.isPaired && connectionResult) {
      // serverinfo 可由 HTTP 回退成功，不能据此宣称配对链路完整可用。
      // 只验证真正会被 AppList/串流使用的地址，不用备用地址制造假阳性。
      try {
        const latestComputer = this.computerManager.getComputer(computer.uuid) || computerInfo;
        const nvHttp = NvHttp.fromAddress(connectionResult.address, latestComputer, context);
        await nvHttp.getAppList();
        appListReachable = true;
      } catch (err) {
        appListReachable = false;
        appListError = (err as Error).message || String(err);
      }
    }

    if (reachableResults.length > 0) {
      lines.push('[OK] 基础网络可达');
      if (computer.isPaired) {
        if (connectionAddressUntested) {
          const addressKind = currentPreferred ? '锁定地址' : '当前连接地址';
          lines.push(`[!] ${addressKind}为本机回环地址，未执行诊断`);
        } else if (connectionAddressUnavailable) {
          const addressKind = currentPreferred ? '锁定地址' : '当前连接地址';
          lines.push(`[!] ${addressKind}不可达，备用地址仅用于网络诊断`);
        } else if (appListReachable) {
          lines.push('[OK] 应用列表认证可用');
        } else {
          lines.push('[!] 主机可达，但应用列表认证不可用');
          if (appListError) {
            const shortAppError = appListError.length > 80 ? appListError.substring(0, 80) + '…' : appListError;
            lines.push(`    ${shortAppError}`);
          }
        }
      }
      lines.push('');

      // 地址延迟
      for (const r of reachableResults) {
        const label = this.getAddressLabel(r.address, computerInfo);
        const quality = r.latencyMs < 10 ? '极佳' : r.latencyMs < 30 ? '良好' : r.latencyMs < 80 ? '一般' : '较高';
        const pin = r.address === computerInfo.preferredAddress ? ' 📌' : '';
        lines.push(`${label}: ${r.latencyMs}ms (${quality})${pin}`);
      }

      // 服务器信息
      if (serverInfo) {
        lines.push('');
        lines.push(`主机名: ${serverInfo.hostname}`);
        if (serverInfo.gpuType) lines.push(`GPU: ${serverInfo.gpuType}`);
        let pairText = '未配对';
        if (computer.isPaired) {
          if (appListReachable) {
            pairText = '已配对（已验证）';
          } else if (connectionAddressUntested) {
            pairText = '本地已配对（连接地址未测试）';
          } else if (connectionAddressUnavailable) {
            pairText = currentPreferred
              ? '本地已配对（锁定地址不可达）'
              : '本地已配对（当前连接地址不可达）';
          } else {
            pairText = '本地已配对（认证未通过）';
          }
        }
        lines.push(`配对: ${pairText}`);
        if (serverInfo.currentGame > 0) lines.push(`运行中游戏 ID: ${serverInfo.currentGame}`);
      }
    } else {
      lines.push('所有地址均无法连接');
    }

    // 不可达地址
    if (unreachableResults.length > 0) {
      lines.push('');
      for (const r of unreachableResults) {
        const label = this.getAddressLabel(r.address, computerInfo);
        const shortErr = r.error.length > 60 ? r.error.substring(0, 60) + '…' : r.error;
        lines.push(`[X] ${label}: ${shortErr || '超时'}`);
      }
    }

    // 当前锁定的地址
    if (currentPreferred) {
      lines.push('');
      lines.push(`📌 已锁定: ${currentPreferred}`);
    }

    // 显示结果后提供锁定/解锁操作
    if (reachableResults.length > 0) {
      this.ui.showInfoDialog({
        title: '网络测试 — ' + computer.name,
        content: lines.join('\n'),
        closeButtonText: '关闭',
        onClose: () => {
          this.showAddressPinMenu(computer, reachableResults, currentPreferred);
        }
      });
    } else {
      this.ui.showInfoDialog({ title: '网络测试 — ' + computer.name, content: lines.join('\n') });
    }
  }

  /** 显示地址锁定/解锁菜单 */
  private showAddressPinMenu(
    computer: ObservableComputer,
    reachableResults: AddressTestResult[],
    currentPreferred: string | undefined
  ): void {
    const computerInfo = computer.toComputerInfo();

    // 构建按钮列表（showDialog 最多 3 个按钮，我们用前几个可达地址 + 解锁）
    interface DialogBtn {
      text: string;
      color: string;
    }
    const dialogButtons: DialogBtn[] = [];
    // 记录每个按钮对应的动作
    const actions: string[] = []; // 'unlock' | address string

    // 如果已锁定，提供解锁选项
    if (currentPreferred) {
      dialogButtons.push({ text: '解除锁定', color: '#E57373' });
      actions.push('unlock');
    }

    // 提供可达地址（最多填满到 3 个按钮）
    for (const r of reachableResults) {
      if (dialogButtons.length >= 3) break;
      const label = this.getAddressLabel(r.address, computerInfo);
      const pinned = r.address === currentPreferred ? ' ✓' : '';
      dialogButtons.push({ text: `${label}${pinned}`, color: '#4CAF50' });
      actions.push(r.address);
    }

    if (dialogButtons.length === 0) return;

    promptAction.showDialog({
      title: '锁定优先连接地址',
      message: currentPreferred ? `当前锁定: ${currentPreferred}` : '选择要锁定的地址',
      buttons: dialogButtons
    }).then(async (result) => {
      const action = actions[result.index];
      if (!action) return;
      const nextAddress = action === 'unlock' ? '' : action;
      try {
        await this.computerManager.updateComputer(computer.uuid, { preferredAddress: nextAddress });
      } catch (err) {
        const message = (err as Error).message || String(err);
        ToastQueue.show({ message: `保存地址锁定失败: ${message}` });
        return;
      }
      computer.preferredAddress = nextAddress;
      this.ui.syncViewModel();
      ToastQueue.show({ message: nextAddress ? `已锁定: ${nextAddress}` : '已解除地址锁定' });
    }).catch(() => {
      // 用户取消
    });
  }

  /** 根据地址匹配返回易读标签 */
  private getAddressLabel(address: string, computerInfo: ComputerInfo): string {
    if (address === computerInfo.manualAddress) return `手动 (${address})`;
    if (address === computerInfo.localAddress) return `局域网 (${address})`;
    if (address === computerInfo.remoteAddress) return `远程 (${address})`;
    if (address === computerInfo.ipv6Address) return `IPv6 (${address})`;
    return address;
  }

  /** 显示电脑详情 */
  showComputerDetails(computer: ObservableComputer): void {
    const stateText = computer.isOnline ? '在线' : '离线';
    const pairText = computer.isPaired ? '已配对' : '未配对';
    const gamingText = computer.isGaming ? `正在运行游戏 (ID: ${computer.runningGameId})` : '空闲';

    const addressLines: string[] = [];
    const info = computer.toComputerInfo();
    const notLoopback = (a: string | undefined) => a && !isLoopbackIPv4(a);
    if (notLoopback(info.manualAddress)) { addressLines.push(`手动地址: ${info.manualAddress}`); }
    if (notLoopback(info.localAddress)) { addressLines.push(`本地地址: ${info.localAddress}`); }
    if (notLoopback(info.remoteAddress)) { addressLines.push(`远程地址: ${info.remoteAddress}`); }
    if (notLoopback(info.address) && info.address !== info.localAddress && info.address !== info.remoteAddress && info.address !== info.manualAddress) {
      addressLines.push(`当前地址: ${info.address}`);
    }
    if (addressLines.length === 0) { addressLines.push(`地址: 未知`); }

    const details = [
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

    this.ui.showInfoDialog({ title: computer.name, content: details });
  }
}
