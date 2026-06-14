/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * GitHub Star 验证器
 * 使用 GitHub OAuth Device Flow 获取当前用户授权，再通过
 * /user/starred/{owner}/{repo} 检查该账号是否 Star 了项目。
 */

import { HttpClient, HttpResponse } from './HttpClient';
import {
  GITHUB_OAUTH_CLIENT_ID,
  GITHUB_STAR_REPO_NAME,
  GITHUB_STAR_REPO_OWNER
} from '../config/GitHubOAuthConfig';

type JsonPrimitive = string | number | boolean | null | undefined;
type JsonMap = Record<string, JsonPrimitive>;

export class GitHubDeviceCode {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  verificationUriComplete?: string;
  expiresInSeconds: number;
  intervalSeconds: number;

  constructor(
    deviceCode: string,
    userCode: string,
    verificationUri: string,
    verificationUriComplete: string | undefined,
    expiresInSeconds: number,
    intervalSeconds: number
  ) {
    this.deviceCode = deviceCode;
    this.userCode = userCode;
    this.verificationUri = verificationUri;
    this.verificationUriComplete = verificationUriComplete;
    this.expiresInSeconds = expiresInSeconds;
    this.intervalSeconds = intervalSeconds;
  }
}

export class GitHubStarCheck {
  starred: boolean;
  login?: string;

  constructor(starred: boolean, login?: string) {
    this.starred = starred;
    this.login = login;
  }
}

export enum GitHubTokenPollStatus {
  AUTHORIZED = 'authorized',
  PENDING = 'pending',
  SLOW_DOWN = 'slow_down',
  FAILED = 'failed'
}

export class GitHubTokenPollResult {
  status: GitHubTokenPollStatus;
  accessToken?: string;
  intervalSeconds?: number;
  message?: string;

  constructor(
    status: GitHubTokenPollStatus,
    accessToken?: string,
    intervalSeconds?: number,
    message?: string
  ) {
    this.status = status;
    this.accessToken = accessToken;
    this.intervalSeconds = intervalSeconds;
    this.message = message;
  }
}

export class GitHubStarVerifier {
  private static readonly DEVICE_CODE_URL = 'https://github.com/login/device/code';
  private static readonly ACCESS_TOKEN_URL = 'https://github.com/login/oauth/access_token';
  private static readonly API_USER_URL = 'https://api.github.com/user';
  private static readonly API_VERSION = '2022-11-28';
  private static readonly USER_AGENT = 'Moonlight-Harmony';

  static isConfigured(): boolean {
    return GITHUB_OAUTH_CLIENT_ID.trim().length > 0;
  }

  static projectUrl(): string {
    return `https://github.com/${GITHUB_STAR_REPO_OWNER}/${GITHUB_STAR_REPO_NAME}`;
  }

  static projectFullName(): string {
    return `${GITHUB_STAR_REPO_OWNER}/${GITHUB_STAR_REPO_NAME}`;
  }

  static async requestDeviceCode(): Promise<GitHubDeviceCode> {
    GitHubStarVerifier.ensureConfigured();
    const values: Record<string, string> = {};
    values.client_id = GITHUB_OAUTH_CLIENT_ID;
    values.scope = '';
    const response = await GitHubStarVerifier.postForm(
      GitHubStarVerifier.DEVICE_CODE_URL,
      values
    );

    if (response.statusCode !== 200) {
      throw new Error(GitHubStarVerifier.errorMessage(response.body, `GitHub device code request failed (${response.statusCode})`));
    }

    const json = GitHubStarVerifier.parseJson(response.body);
    return new GitHubDeviceCode(
      GitHubStarVerifier.stringValue(json, 'device_code'),
      GitHubStarVerifier.stringValue(json, 'user_code'),
      GitHubStarVerifier.stringValue(json, 'verification_uri'),
      GitHubStarVerifier.optionalStringValue(json, 'verification_uri_complete'),
      GitHubStarVerifier.numberValue(json, 'expires_in', 900),
      Math.max(1, GitHubStarVerifier.numberValue(json, 'interval', 5))
    );
  }

  static async pollAccessToken(deviceCode: GitHubDeviceCode): Promise<GitHubTokenPollResult> {
    GitHubStarVerifier.ensureConfigured();
    const values: Record<string, string> = {};
    values.client_id = GITHUB_OAUTH_CLIENT_ID;
    values.device_code = deviceCode.deviceCode;
    values.grant_type = 'urn:ietf:params:oauth:grant-type:device_code';
    const response = await GitHubStarVerifier.postForm(
      GitHubStarVerifier.ACCESS_TOKEN_URL,
      values
    );

    const json = response.body ? GitHubStarVerifier.parseJson(response.body) : GitHubStarVerifier.emptyJsonMap();
    const accessToken = GitHubStarVerifier.optionalStringValue(json, 'access_token');
    if (response.statusCode === 200 && accessToken) {
      return new GitHubTokenPollResult(GitHubTokenPollStatus.AUTHORIZED, accessToken);
    }

    const error = GitHubStarVerifier.optionalStringValue(json, 'error') ?? '';
    switch (error) {
      case 'authorization_pending':
        return new GitHubTokenPollResult(GitHubTokenPollStatus.PENDING);
      case 'slow_down':
        return new GitHubTokenPollResult(
          GitHubTokenPollStatus.SLOW_DOWN,
          undefined,
          Math.max(
            deviceCode.intervalSeconds + 5,
            GitHubStarVerifier.numberValue(json, 'interval', 0)
          )
        );
      case 'expired_token':
        return new GitHubTokenPollResult(GitHubTokenPollStatus.FAILED, undefined, undefined, 'GitHub 授权码已过期');
      case 'access_denied':
        return new GitHubTokenPollResult(GitHubTokenPollStatus.FAILED, undefined, undefined, 'GitHub 授权已取消');
      case 'device_flow_disabled':
        return new GitHubTokenPollResult(GitHubTokenPollStatus.FAILED, undefined, undefined, '当前 OAuth App 未启用 Device Flow');
      default:
        return new GitHubTokenPollResult(
          GitHubTokenPollStatus.FAILED,
          undefined,
          undefined,
          GitHubStarVerifier.errorMessage(response.body, `GitHub 授权失败 (${response.statusCode}${error ? ', ' + error : ''})`)
        );
    }
  }

  static async checkStar(accessToken: string): Promise<GitHubStarCheck> {
    const login = await GitHubStarVerifier.fetchLogin(accessToken);
    const headers = GitHubStarVerifier.githubApiHeaders(accessToken);
    const response = await HttpClient.requestRaw(
      `https://api.github.com/user/starred/${GITHUB_STAR_REPO_OWNER}/${GITHUB_STAR_REPO_NAME}`,
      'GET',
      undefined,
      {
        connectTimeout: 10000,
        transferTimeout: 15000,
        skipServerValidation: false,
        headers: headers
      }
    );

    switch (response.statusCode) {
      case 204:
        return new GitHubStarCheck(true, login);
      case 404:
        return new GitHubStarCheck(false, login);
      case 401:
        throw new Error('GitHub 授权已失效');
      case 403:
        throw new Error(GitHubStarVerifier.errorMessage(response.body, 'GitHub 拒绝了 Star 检查请求'));
      default:
        throw new Error(GitHubStarVerifier.errorMessage(response.body, `GitHub Star 检查失败 (${response.statusCode})`));
    }
  }

  private static async fetchLogin(accessToken: string): Promise<string | undefined> {
    try {
      const headers = GitHubStarVerifier.githubApiHeaders(accessToken);
      const response = await HttpClient.requestRaw(
        GitHubStarVerifier.API_USER_URL,
        'GET',
        undefined,
        {
          connectTimeout: 10000,
          transferTimeout: 15000,
          skipServerValidation: false,
          headers: headers
        }
      );

      if (response.statusCode === 200 && response.body) {
        return GitHubStarVerifier.optionalStringValue(GitHubStarVerifier.parseJson(response.body), 'login');
      }
    } catch (err) {
      console.warn(`GitHubStarVerifier: 获取 GitHub 登录名失败: ${err}`);
    }
    return undefined;
  }

  private static async postForm(url: string, values: Record<string, string>): Promise<HttpResponse> {
    const entries = Object.entries(values);
    const body = entries.map((entry: [string, string]) => {
      return `${encodeURIComponent(entry[0])}=${encodeURIComponent(entry[1])}`;
    }).join('&');

    const headers: Record<string, string> = {};
    headers.Accept = 'application/json';
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
    headers['User-Agent'] = GitHubStarVerifier.USER_AGENT;

    return HttpClient.requestRaw(url, 'POST', body, {
      connectTimeout: 10000,
      transferTimeout: 15000,
      skipServerValidation: false,
      headers: headers
    });
  }

  private static githubApiHeaders(accessToken: string): Record<string, string> {
    const headers: Record<string, string> = {};
    headers.Accept = 'application/vnd.github+json';
    headers.Authorization = `Bearer ${accessToken}`;
    headers['X-GitHub-Api-Version'] = GitHubStarVerifier.API_VERSION;
    headers['User-Agent'] = GitHubStarVerifier.USER_AGENT;
    return headers;
  }

  private static ensureConfigured(): void {
    if (!GitHubStarVerifier.isConfigured()) {
      throw new Error('GitHub OAuth Client ID 未配置');
    }
  }

  private static parseJson(body: string): JsonMap {
    return JSON.parse(body) as JsonMap;
  }

  private static emptyJsonMap(): JsonMap {
    const json: JsonMap = {};
    return json;
  }

  private static stringValue(json: JsonMap, key: string): string {
    const value = json[key];
    return typeof value === 'string' ? value : '';
  }

  private static optionalStringValue(json: JsonMap, key: string): string | undefined {
    const value = GitHubStarVerifier.stringValue(json, key);
    return value.length > 0 ? value : undefined;
  }

  private static numberValue(json: JsonMap, key: string, fallback: number): number {
    const value = json[key];
    return typeof value === 'number' ? value : fallback;
  }

  private static errorMessage(body: string, fallback: string): string {
    if (!body) {
      return fallback;
    }
    try {
      const json = GitHubStarVerifier.parseJson(body);
      return GitHubStarVerifier.optionalStringValue(json, 'error_description') ??
        GitHubStarVerifier.optionalStringValue(json, 'message') ??
        fallback;
    } catch (_) {
      return fallback;
    }
  }
}
