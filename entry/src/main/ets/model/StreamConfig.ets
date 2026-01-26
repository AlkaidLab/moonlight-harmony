/**
 * 串流配置模型
 */
export interface StreamConfig {
  width: number;
  height: number;
  fps: number;
  bitrate: number;  // Kbps
  codec: 'H.264' | 'HEVC' | 'AV1';
  hdr: boolean;
  audioEnabled: boolean;
  microphoneEnabled: boolean;
  // 高级选项
  packetSize?: number;
  enableFramePacing?: boolean;
  enableAdaptiveBitrate?: boolean;
  audioConfig?: AudioConfig;
}

export interface AudioConfig {
  channelCount: number;
  sampleRate: number;
}

export function getDefaultStreamConfig(): StreamConfig {
  return {
    width: 1920,
    height: 1080,
    fps: 60,
    bitrate: 20000,
    codec: 'HEVC',
    hdr: false,
    audioEnabled: true,
    microphoneEnabled: false,
    packetSize: 1024,
    enableFramePacing: true,
    enableAdaptiveBitrate: true,
    audioConfig: {
      channelCount: 2,
      sampleRate: 48000
    }
  };
}

export function getResolutionPresets(): { name: string; width: number; height: number }[] {
  return [
    { name: '720p', width: 1280, height: 720 },
    { name: '1080p', width: 1920, height: 1080 },
    { name: '1440p', width: 2560, height: 1440 },
    { name: '4K', width: 3840, height: 2160 }
  ];
}
