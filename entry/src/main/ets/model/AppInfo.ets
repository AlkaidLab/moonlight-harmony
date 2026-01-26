/**
 * 应用信息模型
 */
export interface AppInfo {
  id: number;
  name: string;
  isRunning: boolean;
  isHdrSupported?: boolean;
}

export interface AppAsset {
  appId: number;
  computerId: string;
  boxArt?: string;  // Base64 或 URL
}
