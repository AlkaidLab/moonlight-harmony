/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { SettingsKeys } from './SettingsService';
import {
  GitHubDeviceCode,
  GitHubStarVerifier,
  GitHubTokenPollResult,
  GitHubTokenPollStatus
} from '../utils/GitHubStarVerifier';
import { PreferencesUtil } from '../utils/PreferencesUtil';

export enum DeveloperUnlockStatus {
  REQUESTED = 'requested',
  PENDING = 'pending',
  VERIFIED = 'verified',
  NOT_STARRED = 'not_starred',
  EXPIRED = 'expired',
  FAILED = 'failed'
}

export class DeveloperUnlockResult {
  status: DeveloperUnlockStatus;
  deviceCode?: GitHubDeviceCode;
  login?: string;
  message?: string;

  constructor(
    status: DeveloperUnlockStatus,
    deviceCode?: GitHubDeviceCode,
    login?: string,
    message?: string
  ) {
    this.status = status;
    this.deviceCode = deviceCode;
    this.login = login;
    this.message = message;
  }
}

export class DeveloperUnlockService {
  private static pendingDeviceCode: GitHubDeviceCode | null = null;
  private static lastPollMs: number = 0;
  private static readonly MIN_POLL_INTERVAL_MS = 1500;

  static isGitHubConfigured(): boolean {
    return GitHubStarVerifier.isConfigured();
  }

  static projectUrl(): string {
    return GitHubStarVerifier.projectUrl();
  }

  static projectFullName(): string {
    return GitHubStarVerifier.projectFullName();
  }

  static async requestDeviceCode(): Promise<DeveloperUnlockResult> {
    try {
      const deviceCode = await GitHubStarVerifier.requestDeviceCode();
      DeveloperUnlockService.pendingDeviceCode = deviceCode;
      await DeveloperUnlockService.savePendingDeviceCode(deviceCode);
      return new DeveloperUnlockResult(DeveloperUnlockStatus.REQUESTED, deviceCode);
    } catch (err) {
      return DeveloperUnlockService.failedResult(err, 'GitHub 授权失败');
    }
  }

  static async pollPendingDeviceCode(enforceThrottle: boolean): Promise<DeveloperUnlockResult> {
    const deviceCode = DeveloperUnlockService.pendingDeviceCode ??
      await DeveloperUnlockService.loadPendingDeviceCode();
    if (!deviceCode) {
      return new DeveloperUnlockResult(DeveloperUnlockStatus.EXPIRED, undefined, undefined, 'GitHub 授权已过期，请重新开始');
    }

    const nowMs = Date.now();
    if (enforceThrottle && nowMs - DeveloperUnlockService.lastPollMs < DeveloperUnlockService.MIN_POLL_INTERVAL_MS) {
      return new DeveloperUnlockResult(DeveloperUnlockStatus.PENDING, deviceCode);
    }
    DeveloperUnlockService.lastPollMs = nowMs;

    try {
      const poll = await GitHubStarVerifier.pollAccessToken(deviceCode);
      return await DeveloperUnlockService.handleTokenPollResult(poll, deviceCode);
    } catch (err) {
      await DeveloperUnlockService.clearPendingDeviceCode();
      return DeveloperUnlockService.failedResult(err, 'GitHub 授权失败');
    }
  }

  static async restorePendingDeviceCode(): Promise<GitHubDeviceCode | null> {
    DeveloperUnlockService.pendingDeviceCode = await DeveloperUnlockService.loadPendingDeviceCode();
    return DeveloperUnlockService.pendingDeviceCode;
  }

  static async loadPendingDeviceCode(): Promise<GitHubDeviceCode | null> {
    const expiresAt = await PreferencesUtil.get<number>(SettingsKeys.DEV_GITHUB_PENDING_EXPIRES_AT, 0);
    const remainingSeconds = Math.floor((expiresAt - Date.now()) / 1000);
    if (remainingSeconds <= 0) {
      await DeveloperUnlockService.clearPendingDeviceCode();
      return null;
    }

    const deviceCode = await PreferencesUtil.get<string>(SettingsKeys.DEV_GITHUB_PENDING_DEVICE_CODE, '');
    const userCode = await PreferencesUtil.get<string>(SettingsKeys.DEV_GITHUB_PENDING_USER_CODE, '');
    const verificationUri = await PreferencesUtil.get<string>(SettingsKeys.DEV_GITHUB_PENDING_VERIFICATION_URI, '');
    if (!deviceCode || !userCode || !verificationUri) {
      await DeveloperUnlockService.clearPendingDeviceCode();
      return null;
    }

    const verificationUriComplete = await PreferencesUtil.get<string>(
      SettingsKeys.DEV_GITHUB_PENDING_VERIFICATION_URI_COMPLETE,
      ''
    );
    const intervalSeconds = await PreferencesUtil.get<number>(SettingsKeys.DEV_GITHUB_PENDING_INTERVAL, 5);
    return new GitHubDeviceCode(
      deviceCode,
      userCode,
      verificationUri,
      verificationUriComplete || undefined,
      remainingSeconds,
      Math.max(1, intervalSeconds)
    );
  }

  static async clearPendingDeviceCode(): Promise<void> {
    DeveloperUnlockService.pendingDeviceCode = null;
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_DEVICE_CODE, '');
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_USER_CODE, '');
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_VERIFICATION_URI, '');
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_VERIFICATION_URI_COMPLETE, '');
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_EXPIRES_AT, 0);
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_INTERVAL, 0);
  }

  private static async handleTokenPollResult(
    poll: GitHubTokenPollResult,
    deviceCode: GitHubDeviceCode
  ): Promise<DeveloperUnlockResult> {
    switch (poll.status) {
      case GitHubTokenPollStatus.AUTHORIZED:
        return await DeveloperUnlockService.handleAuthorizedPoll(poll);
      case GitHubTokenPollStatus.PENDING:
      case GitHubTokenPollStatus.SLOW_DOWN:
        return await DeveloperUnlockService.handlePendingPoll(poll, deviceCode);
      case GitHubTokenPollStatus.FAILED:
        await DeveloperUnlockService.clearPendingDeviceCode();
        return new DeveloperUnlockResult(
          DeveloperUnlockStatus.FAILED,
          undefined,
          undefined,
          poll.message ?? 'GitHub 授权失败'
        );
    }
    await DeveloperUnlockService.clearPendingDeviceCode();
    return new DeveloperUnlockResult(DeveloperUnlockStatus.FAILED, undefined, undefined, 'GitHub 授权失败');
  }

  private static async handleAuthorizedPoll(poll: GitHubTokenPollResult): Promise<DeveloperUnlockResult> {
    if (!poll.accessToken) {
      await DeveloperUnlockService.clearPendingDeviceCode();
      return new DeveloperUnlockResult(
        DeveloperUnlockStatus.FAILED,
        undefined,
        undefined,
        'GitHub 未返回 access token'
      );
    }

    const starCheck = await GitHubStarVerifier.checkStar(poll.accessToken);
    await DeveloperUnlockService.clearPendingDeviceCode();
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_LOGIN, starCheck.login ?? '');

    if (starCheck.starred) {
      await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_VERIFIED_AT, Date.now());
      return new DeveloperUnlockResult(DeveloperUnlockStatus.VERIFIED, undefined, starCheck.login);
    }
    return new DeveloperUnlockResult(DeveloperUnlockStatus.NOT_STARRED, undefined, starCheck.login);
  }

  private static async handlePendingPoll(
    poll: GitHubTokenPollResult,
    deviceCode: GitHubDeviceCode
  ): Promise<DeveloperUnlockResult> {
    if (poll.intervalSeconds) {
      deviceCode.intervalSeconds = poll.intervalSeconds;
      await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_INTERVAL, deviceCode.intervalSeconds);
    }
    DeveloperUnlockService.pendingDeviceCode = deviceCode;
    return new DeveloperUnlockResult(DeveloperUnlockStatus.PENDING, deviceCode);
  }

  private static async savePendingDeviceCode(deviceCode: GitHubDeviceCode): Promise<void> {
    const expiresAt = Date.now() + deviceCode.expiresInSeconds * 1000;
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_DEVICE_CODE, deviceCode.deviceCode);
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_USER_CODE, deviceCode.userCode);
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_VERIFICATION_URI, deviceCode.verificationUri);
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_VERIFICATION_URI_COMPLETE, deviceCode.verificationUriComplete ?? '');
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_EXPIRES_AT, expiresAt);
    await PreferencesUtil.put(SettingsKeys.DEV_GITHUB_PENDING_INTERVAL, deviceCode.intervalSeconds);
  }

  private static failedResult(err: Error | string, fallback: string): DeveloperUnlockResult {
    const message = (err as Error).message ?? String(err) ?? fallback;
    return new DeveloperUnlockResult(DeveloperUnlockStatus.FAILED, undefined, undefined, message);
  }
}
