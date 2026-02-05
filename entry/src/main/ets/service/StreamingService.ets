/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { Want, ExtensionAbility } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'StreamingService';
const DOMAIN = 0x0000;

/**
 * 串流后台服务
 * 
 * 用于保持串流在后台运行
 * 
 * 注意: HarmonyOS 4.0+ 不再支持 ServiceExtensionAbility，
 * 改用 ExtensionAbility 或 BackgroundTaskManager API
 */
export default class StreamingService extends ExtensionAbility {
  onCreate(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'StreamingService onCreate');
  }

  onRequest(want: Want, startId: number): void {
    hilog.info(DOMAIN, TAG, '%{public}s', `StreamingService onRequest, startId: ${startId}`);
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'StreamingService onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'StreamingService onBackground');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'StreamingService onDestroy');
  }
}
