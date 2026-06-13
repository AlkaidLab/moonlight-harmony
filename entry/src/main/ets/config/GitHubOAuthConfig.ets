/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * GitHub OAuth Device Flow 配置。
 *
 * GITHUB_OAUTH_CLIENT_ID 为空时，设置页会继续使用原有激活码流程。
 * 若要启用 GitHub Star 验证，请创建 GitHub OAuth App，启用 Device Flow，
 * 并将公开的 Client ID 填入此处。
 */

export const GITHUB_OAUTH_CLIENT_ID = '';
export const GITHUB_STAR_REPO_OWNER = 'AlkaidLab';
export const GITHUB_STAR_REPO_NAME = 'moonlight-harmony';
