/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { NvHttpHost, selectBestAddress } from '../model/ComputerInfo';
import { formatAddressForUrl, parseAddressAndPort } from './NetHelper';

/**
 * Sunshine Web UI 默认使用 HTTPS 47990；如果用户使用了自定义
 * GameStream HTTP 端口，则按 Sunshine 相邻端口规则推导 Web UI 端口。
 */
export const DEFAULT_HOST_WEBUI_PORT = 47990;

export function buildHostWebUiUrl(computer: NvHttpHost): string {
  const selectedAddress = selectBestAddress(computer);
  const parsed = parseAddressAndPort(selectedAddress);
  if (!parsed.host) {
    return '';
  }

  const configuredHttpPort = parsed.port || computer.httpPort;
  const webUiPort = configuredHttpPort ? configuredHttpPort + 1 : DEFAULT_HOST_WEBUI_PORT;
  return `https://${formatAddressForUrl(parsed.host)}:${webUiPort}`;
}
