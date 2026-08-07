#!/usr/bin/env node
/*
 * Foundation Sunshine connection-model mock tests.
 *
 * The fixtures mirror AlkaidLab/foundation-sunshine at HEAD
 * 2f3442ed126aeb17bcc54527b637eecfcae9452c:
 * - src/nvhttp.cpp: /serverinfo fields and HTTP/HTTPS PairStatus/MAC behavior
 * - src/nvhttp/apps.cpp: /applist AppTitle/ID/IsHdrSupported/SuperCmds fields
 * - src/nvhttp/pairing.cpp: /pair phase order and status fields
 *
 * This is intentionally a Node-side protocol contract test. HarmonyOS Kit
 * modules cannot run in plain Node, so the client below mirrors the connection
 * model used by NvHttp/PairingManager without importing ArkTS runtime modules.
 */

const assert = require('assert');
const http = require('http');
const net = require('net');
const { URL } = require('url');

const DEFAULT_HTTP_PORT = 47989;
const DEFAULT_HTTPS_PORT = 47984;
const HOST = '127.0.0.1';
const CLIENT_UNIQUE_ID = 'moonlight-harmony-test-client';
const CLIENT_NAME = 'Moonlight-HarmonyOS-Test';
const DEFAULT_HDR_MIN_BRIGHTNESS_NITS = 0.001;
const BANDWIDTH_PROBE_SAMPLE_SIZES = [65536, 262144, 1048576, 4194304];
const BANDWIDTH_PROBE_TOTAL_BUDGET_MS = 800;
const BANDWIDTH_PROBE_LAUNCH_WAIT_MS = 800;
const METERED_BANDWIDTH_PROBE_MAX_BYTES = 320 * 1024;

function xmlEscape(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function xmlRoot(body, statusCode = 200, statusMessage = '') {
  const messageAttr = statusMessage ? ` status_message="${xmlEscape(statusMessage)}"` : '';
  return `<?xml version="1.0" encoding="utf-8"?>\n<root status_code="${statusCode}"${messageAttr}>${body}</root>`;
}

function tag(name, value) {
  return `<${name}>${xmlEscape(value)}</${name}>`;
}

function getValue(xml, name) {
  const match = xml.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`));
  return match ? match[1].trim() : '';
}

function getIntValue(xml, name, fallback = 0) {
  const parsed = parseInt(getValue(xml, name), 10);
  return Number.isNaN(parsed) ? fallback : parsed;
}

function decodeHtmlEntities(text) {
  return String(text)
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&apos;/g, "'");
}

function parseServerInfo(xml) {
  return {
    hostname: getValue(xml, 'hostname') || 'UNKNOWN',
    uniqueId: getValue(xml, 'uniqueid'),
    macAddress: getValue(xml, 'mac'),
    paired: getValue(xml, 'PairStatus') === '1',
    currentGame: getIntValue(xml, 'currentgame', 0),
    serverCodecModeSupport: getIntValue(xml, 'ServerCodecModeSupport', 0),
    gfeVersion: getValue(xml, 'GfeVersion'),
    appVersion: getValue(xml, 'appversion'),
    sunshineVersion: getValue(xml, 'SunshineVersion'),
    maxLumaPixelsHEVC: getIntValue(xml, 'MaxLumaPixelsHEVC', 0),
    httpsPort: getIntValue(xml, 'HttpsPort', DEFAULT_HTTPS_PORT),
    externalPort: getIntValue(xml, 'ExternalPort', DEFAULT_HTTP_PORT),
    localAddress: getValue(xml, 'LocalIP'),
    appListEtag: getValue(xml, 'appListEtag'),
    aiCapability: getIntValue(xml, 'AiCapability', 0)
  };
}

function parseAppList(xml) {
  const apps = [];
  const appRegex = /<App>([\s\S]*?)<\/App>/g;
  let match;
  while ((match = appRegex.exec(xml)) !== null) {
    const appXml = match[1];
    let cmdList;
    const superCmds = getValue(appXml, 'SuperCmds');
    if (superCmds && superCmds !== 'null') {
      cmdList = JSON.parse(decodeHtmlEntities(superCmds));
    }
    apps.push({
      id: getIntValue(appXml, 'ID', 0),
      name: getValue(appXml, 'AppTitle'),
      isRunning: getValue(appXml, 'IsRunning') === '1',
      isHdrSupported: getValue(appXml, 'IsHdrSupported') === '1',
      cmdList
    });
  }
  return apps;
}

function isTimeoutError(message) {
  const lower = String(message).toLowerCase();
  return lower.includes('timeout') || lower.includes('timed out');
}

function isTransientNetworkError(error) {
  const lower = String(error instanceof Error ? error.message : error).toLowerCase();
  return isTimeoutError(lower) ||
    lower.includes('refused') ||
    lower.includes('unreachable') ||
    lower.includes('dns') ||
    lower.includes('getaddrinfo') ||
    lower.includes('connect failed') ||
    lower.includes('connection reset') ||
    lower.includes('econnreset') ||
    lower.includes('reset by peer') ||
    lower.includes('canceled') ||
    lower.includes('cancelled') ||
    lower.includes('1007900003');
}

function delay(ms, value) {
  return new Promise((resolve) => setTimeout(() => resolve(value), ms));
}

function isIPv4Address(address) {
  const parts = String(address).split('.');
  if (parts.length !== 4) return false;
  return parts.every((part) => {
    const n = parseInt(part, 10);
    return !Number.isNaN(n) && n >= 0 && n <= 255 && part === String(n);
  });
}

function isIPv6Address(address) {
  return String(address).split(':').length >= 3;
}

function isLoopbackIPv4(address) {
  return isIPv4Address(address) && String(address).startsWith('127.');
}

function isPrivateIPv4(address) {
  if (!isIPv4Address(address)) return false;
  const [a, b] = String(address).split('.').map((part) => parseInt(part, 10));
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
}

function isLanAddress(address) {
  const host = String(address).replace(/:\d+$/, '');
  return isPrivateIPv4(host) || isLoopbackIPv4(host) || host.startsWith('169.254.') ||
    host.startsWith('fe80:') || host.startsWith('fc') || host.startsWith('fd') || host === '::1';
}

function resolveHttpPort(address, fallback) {
  const match = String(address).match(/^[^:]+:(\d+)$/);
  if (!match) return fallback;
  const port = parseInt(match[1], 10);
  return port > 0 && port <= 65535 ? port : fallback;
}

function nvHttpFromAddressModel(address, computer) {
  const fallback = computer.httpPort || DEFAULT_HTTP_PORT;
  const targetPort = resolveHttpPort(address, fallback);
  const activePort = computer.address ? resolveHttpPort(computer.address, fallback) : 0;
  const portMatches = activePort > 0 && activePort === targetPort;
  return {
    address,
    httpPort: targetPort,
    httpsPort: portMatches ? (computer.httpsPort || 0) : 0
  };
}

function parseAddressAndPortModel(address) {
  const text = String(address);
  const bracketMatch = text.match(/^\[([^\]]+)\]:(\d+)$/);
  if (bracketMatch) {
    return { host: bracketMatch[1], port: parseInt(bracketMatch[2], 10) };
  }

  const hostPortMatch = text.match(/^([^:]+):(\d+)$/);
  if (hostPortMatch) {
    return { host: hostPortMatch[1], port: parseInt(hostPortMatch[2], 10) };
  }

  return { host: text.replace(/^\[|\]$/g, ''), port: undefined };
}

function pairingBaseUrlFromAddressModel(address, httpPort = undefined) {
  const parsed = parseAddressAndPortModel(address);
  const port = parsed.port || httpPort || DEFAULT_HTTP_PORT;
  const formattedHost = isIPv6Address(parsed.host) ? `[${parsed.host}]` : parsed.host;
  return `http://${formattedHost}:${port}`;
}

function createComputer(overrides = {}) {
  return {
    uuid: 'foundation-sunshine-server-id',
    name: 'Old Name',
    address: '',
    localAddress: '',
    remoteAddress: '',
    manualAddress: undefined,
    ipv6Address: undefined,
    macAddress: '',
    state: 'UNKNOWN',
    pairState: 'NOT_PAIRED',
    runningGameId: 0,
    serverCert: '',
    httpPort: undefined,
    httpsPort: undefined,
    ...overrides
  };
}

function mergeServerInfoModel(target, info, address, httpPort, discoveredIpv6) {
  if (info.hostname) target.name = info.hostname;
  target.address = address;
  if (info.localAddress && !isLoopbackIPv4(info.localAddress)) {
    target.localAddress = info.localAddress;
  } else if (target.localAddress && isLoopbackIPv4(target.localAddress)) {
    target.localAddress = address;
  }
  if (info.externalAddress) target.remoteAddress = info.externalAddress;
  if (isIPv6Address(address)) {
    target.ipv6Address = address;
  } else if (discoveredIpv6) {
    target.ipv6Address = discoveredIpv6;
  }
  if (info.macAddress && info.macAddress !== '00:00:00:00:00:00') {
    target.macAddress = info.macAddress;
  }
  if (httpPort) target.httpPort = httpPort;
  if (info.httpsPort > 0) target.httpsPort = info.httpsPort;
  target.runningGameId = info.currentGame || 0;
  if (info.paired || target.serverCert) {
    target.pairState = 'PAIRED';
  } else {
    target.pairState = 'NOT_PAIRED';
  }
  target.state = 'ONLINE';
}

function raceForFirstSuccessModel(promises, lanWaitMs = 30) {
  return new Promise((resolve) => {
    let completedCount = 0;
    let hasResolved = false;
    let firstSuccessResult = null;
    let lanWaitTimerId = null;

    const tryResolve = (result) => {
      if (hasResolved) return;
      hasResolved = true;
      if (lanWaitTimerId !== null) clearTimeout(lanWaitTimerId);
      resolve(result);
    };

    const checkAllDone = () => {
      if (completedCount === promises.length && !hasResolved) {
        hasResolved = true;
        if (lanWaitTimerId !== null) clearTimeout(lanWaitTimerId);
        resolve(firstSuccessResult);
      }
    };

    for (const promise of promises) {
      promise.then((result) => {
        if (result.serverInfo !== null && !hasResolved) {
          if (isLanAddress(result.address)) {
            tryResolve(result);
            return;
          }
          if (!firstSuccessResult) {
            firstSuccessResult = result;
            lanWaitTimerId = setTimeout(() => {
              if (!hasResolved && firstSuccessResult) {
                tryResolve(firstSuccessResult);
              }
            }, lanWaitMs);
          }
        }
        completedCount++;
        checkAllDone();
      }).catch(() => {
        completedCount++;
        checkAllDone();
      });
    }
  });
}

function requestText(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: 1000 }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        body += chunk;
      });
      res.on('end', () => {
        if (res.statusCode >= 400) {
          reject(new Error(`HTTP ${res.statusCode}: ${body}`));
          return;
        }
        resolve(body);
      });
    });
    req.on('timeout', () => {
      req.destroy(new Error('Connection timeout'));
    });
    req.on('error', reject);
  });
}

function requestBuffer(url, timeoutMs, signal) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: timeoutMs, signal }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        const body = Buffer.concat(chunks);
        if (res.statusCode >= 400) {
          reject(new Error(`HTTP ${res.statusCode}: ${body.toString('utf8')}`));
          return;
        }
        resolve({ body, headers: res.headers });
      });
    });
    req.on('timeout', () => {
      req.destroy(new Error('Connection timeout'));
    });
    req.on('error', reject);
  });
}

function serverInfoXml({ httpsPort, httpPort, paired, mac, failAttrs = {} }) {
  const body = [
    tag('hostname', failAttrs.hostname || 'Foundation Sunshine Mock'),
    tag('appversion', failAttrs.appversion || '2026.615.0-foundation'),
    tag('GfeVersion', '3.27.0.0'),
    tag('SunshineVersion', 'foundation-sunshine-mock'),
    tag('uniqueid', 'foundation-sunshine-server-id'),
    tag('HttpsPort', httpsPort),
    tag('ExternalPort', httpPort),
    tag('MaxLumaPixelsHEVC', '1869449984'),
    tag('mac', mac),
    tag('LocalIP', HOST),
    tag('ServerCodecModeSupport', '65535'),
    tag('PairStatus', paired ? '1' : '0'),
    tag('currentgame', '0'),
    tag('state', 'SUNSHINE_SERVER_FREE'),
    tag('appListEtag', 'apps-etag-42'),
    tag('AiCapability', '1')
  ].join('');
  return xmlRoot(body);
}

function minimalServerInfoXml() {
  return xmlRoot([
    tag('hostname', 'Escaped & Sunshine <Host>'),
    tag('uniqueid', 'minimal-server'),
    tag('PairStatus', '0')
  ].join(''));
}

function appListXml() {
  const superCmds = JSON.stringify([
    { id: 'toggle_hdr', name: 'Toggle HDR' },
    { id: 'open_overlay', name: 'Open Overlay' }
  ], null, 4);
  const apps = [
    [
      tag('IsHdrSupported', '1'),
      tag('AppTitle', 'Steam Big Picture'),
      tag('ID', '1'),
      tag('SuperCmds', superCmds)
    ].join(''),
    [
      tag('IsHdrSupported', '0'),
      tag('AppTitle', 'Desktop'),
      tag('ID', '2'),
      tag('IsRunning', '1'),
      tag('SuperCmds', '[]')
    ].join('')
  ].map((body) => `<App>${body}</App>`).join('');
  return xmlRoot(apps);
}

function pairXml(fields, statusCode = 200, statusMessage = '') {
  const body = Object.entries(fields).map(([key, value]) => tag(key, value)).join('');
  return xmlRoot(body, statusCode, statusMessage);
}

class FoundationSunshineMock {
  constructor({
    httpPort = 0,
    httpsPort = 0,
    startHttp = true,
    startHttps = true,
    probeKbps = 20000,
    capabilityDelayMs = 0,
    bandwidthProbeSupported = true,
    bitrateResponse = 'success'
  } = {}) {
    this.httpPort = httpPort;
    this.httpsPort = httpsPort;
    this.startHttp = startHttp;
    this.startHttps = startHttps;
    this.sessions = new Map();
    this.requests = [];
    this.failNextServerInfo = false;
    this.probeKbps = probeKbps;
    this.capabilityDelayMs = capabilityDelayMs;
    this.bandwidthProbeSupported = bandwidthProbeSupported;
    this.bitrateResponse = bitrateResponse;
    this.probeMinBytes = 65536;
    this.probeMaxBytes = 4194304;
    this.probeRequestedBytes = 0;
    this.httpServer = null;
    this.httpsServer = null;
  }

  async start() {
    if (this.startHttp) {
      this.httpServer = await this.createServer(false, this.httpPort);
      this.httpPort = this.httpServer.address().port;
    }
    if (this.startHttps) {
      this.httpsServer = await this.createServer(true, this.httpsPort);
      this.httpsPort = this.httpsServer.address().port;
    }
    return this;
  }

  async stop() {
    await Promise.all([this.closeServer(this.httpServer), this.closeServer(this.httpsServer)]);
  }

  createServer(isHttps, port) {
    const server = http.createServer((req, res) => this.handleRequest(isHttps, req, res));
    return new Promise((resolve, reject) => {
      server.on('error', reject);
      server.listen(port, HOST, () => resolve(server));
    });
  }

  closeServer(server) {
    return new Promise((resolve) => {
      if (!server) {
        resolve();
        return;
      }
      server.close(() => resolve());
    });
  }

  handleRequest(isHttps, req, res) {
    const url = new URL(req.url, `http://${HOST}`);
    this.requests.push({ isHttps, path: url.pathname, query: Object.fromEntries(url.searchParams.entries()) });

    if (this.failNextServerInfo && url.pathname === '/serverinfo') {
      this.failNextServerInfo = false;
      // Leave the request unanswered so the client observes a timeout, matching
      // NvHttp's robust retry contract without introducing Node-specific
      // "socket hang up" wording into the classifier.
      return;
    }

    if (url.pathname === '/serverinfo') {
      this.writeXml(res, serverInfoXml({
        httpPort: this.httpPort || DEFAULT_HTTP_PORT,
        httpsPort: this.httpsPort || DEFAULT_HTTPS_PORT,
        paired: isHttps && url.searchParams.has('uniqueid'),
        mac: isHttps ? 'AA:BB:CC:DD:EE:FF' : '00:00:00:00:00:00'
      }));
      return;
    }

    if (url.pathname === '/applist') {
      if (!isHttps) {
        this.writeXml(res, pairXml({ error: 'applist requires HTTPS' }, 401, 'HTTPS required'), 401);
        return;
      }
      this.writeXml(res, appListXml());
      return;
    }

    if (url.pathname === '/api/network/capabilities' && this.bandwidthProbeSupported) {
      if (!isHttps) {
        this.writeJson(res, { error: 'HTTPS required' }, 401);
        return;
      }
      const capabilities = {
        version: 1,
        features: ['bandwidth-probe-v1'],
        bandwidthProbe: {
          version: 1,
          endpoint: '/api/network/probe',
          minBytes: this.probeMinBytes,
          maxBytes: this.probeMaxBytes,
          cooldownMs: 5000
        }
      };
      setTimeout(() => {
        if (!res.destroyed) this.writeJson(res, capabilities);
      }, this.capabilityDelayMs).unref();
      return;
    }

    if (url.pathname === '/api/network/probe' && this.bandwidthProbeSupported) {
      if (!isHttps) {
        this.writeJson(res, { error: 'HTTPS required' }, 401);
        return;
      }
      const bytes = Number(url.searchParams.get('bytes'));
      const nonce = url.searchParams.get('nonce') || '';
      if (!Number.isSafeInteger(bytes) || bytes < this.probeMinBytes || bytes > this.probeMaxBytes ||
        !/^[A-Za-z0-9._-]{1,64}$/.test(nonce)) {
        this.writeJson(res, { error: 'invalid_request' }, 400);
        return;
      }
      this.probeRequestedBytes += bytes;
      const durationMs = Math.max(1, Math.round(bytes * 8 / this.probeKbps));
      setTimeout(() => {
        if (!res.destroyed) this.writeBinary(res, bytes, nonce);
      }, durationMs).unref();
      return;
    }

    if (url.pathname === '/pair') {
      this.handlePair(isHttps, url, res);
      return;
    }

    if (url.pathname === '/launch') {
      this.writeXml(res, xmlRoot([
        tag('gamesession', '1'),
        tag('sessionUrl0', 'rtsp://127.0.0.1:48010')
      ].join('')));
      return;
    }

    if (url.pathname === '/resume') {
      this.writeXml(res, xmlRoot([
        tag('resume', '1'),
        tag('sessionUrl0', 'rtsp://127.0.0.1:48010')
      ].join('')));
      return;
    }

    if (url.pathname === '/cancel') {
      this.writeXml(res, xmlRoot(tag('cancel', '1')));
      return;
    }

    if (url.pathname === '/bitrate') {
      if (!isHttps) {
        this.writeXml(res, pairXml({ bitrate: '0' }, 401, 'HTTPS required'), 401);
        return;
      }
      if (this.bitrateResponse === 'missing') {
        this.writeXml(res, xmlRoot(tag('status', 'accepted')));
      } else {
        this.writeXml(res, xmlRoot(tag('bitrate', this.bitrateResponse === 'success' ? '1' : '0')));
      }
      return;
    }

    if (url.pathname === '/unpair') {
      this.writeXml(res, xmlRoot(tag('unpair', '1')));
      return;
    }

    this.writeXml(res, pairXml({ error: 'not found' }, 404, 'Not found'), 404);
  }

  handlePair(isHttps, url, res) {
    const uniqueId = url.searchParams.get('uniqueid');
    const phrase = url.searchParams.get('phrase');

    if (!uniqueId) {
      this.writeXml(res, pairXml({ paired: '0' }, 400, 'Missing uniqueid parameter'), 400);
      return;
    }

    if (phrase === 'getservercert') {
      const salt = url.searchParams.get('salt') || '';
      if (salt.length < 32) {
        this.writeXml(res, pairXml({ paired: '0' }, 400, 'Salt too short'), 400);
        return;
      }
      this.sessions.set(uniqueId, 'GETSERVERCERT');
      this.writeXml(res, pairXml({
        paired: '1',
        pairname: url.searchParams.get('clientname') || 'Named Zako',
        plaincert: '3082010AF00D'
      }));
      return;
    }

    if (phrase === 'pairchallenge') {
      this.writeXml(res, pairXml({ paired: isHttps ? '1' : '0' }, isHttps ? 200 : 400, isHttps ? '' : 'pairchallenge requires HTTPS'), isHttps ? 200 : 400);
      return;
    }

    const phase = this.sessions.get(uniqueId);
    if (!phase) {
      this.writeXml(res, pairXml({ paired: '0' }, 400, 'Invalid uniqueid'), 400);
      return;
    }

    if (url.searchParams.has('clientchallenge')) {
      if (phase !== 'GETSERVERCERT') {
        this.writeXml(res, pairXml({ paired: '0' }, 400, 'Out of order call to clientchallenge'), 400);
        return;
      }
      this.sessions.set(uniqueId, 'CLIENTCHALLENGE');
      this.writeXml(res, pairXml({ paired: '1', challengeresponse: '00112233445566778899AABBCCDDEEFF' }));
      return;
    }

    if (url.searchParams.has('serverchallengeresp')) {
      if (phase !== 'CLIENTCHALLENGE') {
        this.writeXml(res, pairXml({ paired: '0' }, 400, 'Out of order call to serverchallengeresp'), 400);
        return;
      }
      this.sessions.set(uniqueId, 'SERVERCHALLENGERESP');
      this.writeXml(res, pairXml({ paired: '1', pairingsecret: '11223344556677889900AABBCCDDEEFF' }));
      return;
    }

    if (url.searchParams.has('clientpairingsecret')) {
      if (phase !== 'SERVERCHALLENGERESP') {
        this.writeXml(res, pairXml({ paired: '0' }, 400, 'Out of order call to clientpairingsecret'), 400);
        return;
      }
      this.sessions.delete(uniqueId);
      this.writeXml(res, pairXml({ paired: '1' }));
      return;
    }

    this.writeXml(res, pairXml({ paired: '0' }, 404, 'Invalid pairing request'), 404);
  }

  writeXml(res, body, status = 200) {
    res.writeHead(status, { 'Content-Type': 'application/xml; charset=utf-8' });
    res.end(body);
  }

  writeJson(res, body, status = 200) {
    const text = JSON.stringify(body);
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(text),
      'Cache-Control': 'no-store'
    });
    res.end(text);
  }

  writeBinary(res, bytes, nonce) {
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': bytes,
      'Cache-Control': 'no-store, no-transform',
      'X-Bandwidth-Probe-Version': '1',
      'X-Bandwidth-Probe-Nonce': nonce
    });
    res.end(Buffer.alloc(bytes, 0xA5));
  }
}

class ConnectionModelClient {
  constructor({ host = HOST, httpPort, httpsPort = 0 }) {
    this.host = host;
    this.httpPort = httpPort;
    this.httpsPort = httpsPort;
    this.uniqueId = CLIENT_UNIQUE_ID;
    this.clientName = CLIENT_NAME;
    this.lastUrl = '';
  }

  httpBaseUrl() {
    return `http://${this.host}:${this.httpPort}`;
  }

  async httpsBaseUrl() {
    if (this.httpsPort > 0) {
      return `http://${this.host}:${this.httpsPort}`;
    }
    if (this.httpPort !== DEFAULT_HTTP_PORT) {
      return `http://${this.host}:${this.httpPort - 5}`;
    }
    const xml = await requestText(this.buildUrl(this.httpBaseUrl(), 'serverinfo'));
    const info = parseServerInfo(xml);
    this.httpsPort = info.httpsPort;
    return `http://${this.host}:${this.httpsPort}`;
  }

  buildUrl(baseUrl, path, query) {
    let url = `${baseUrl}/${path}?uniqueid=${encodeURIComponent(this.uniqueId)}&clientname=${encodeURIComponent(this.clientName)}&uuid=test-uuid`;
    if (query) {
      url += `&${query}`;
    }
    this.lastUrl = url;
    return url;
  }

  async getServerInfo({ secure = false, maxAttempts = 1 } = {}) {
    let lastError;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        const baseUrl = secure ? await this.httpsBaseUrl() : this.httpBaseUrl();
        return parseServerInfo(await requestText(this.buildUrl(baseUrl, 'serverinfo')));
      } catch (err) {
        lastError = err;
        if (!isTransientNetworkError(err) || attempt === maxAttempts) {
          throw err;
        }
      }
    }
    throw lastError;
  }

  async getAppList() {
    const baseUrl = await this.httpsBaseUrl();
    return parseAppList(await requestText(this.buildUrl(baseUrl, 'applist')));
  }

  async getNetworkProbeCapabilities(signal) {
    try {
      const baseUrl = await this.httpsBaseUrl();
      const response = await requestBuffer(this.buildUrl(baseUrl, 'api/network/capabilities'), 7000, signal);
      const parsed = JSON.parse(response.body.toString('utf8'));
      const probe = parsed.bandwidthProbe;
      if (parsed.version < 1 || !parsed.features || !parsed.features.includes('bandwidth-probe-v1') ||
        !probe || probe.version !== 1 || !probe.endpoint || !probe.endpoint.startsWith('/') || probe.endpoint.includes('://') ||
        probe.endpoint.includes('?') || probe.endpoint.includes('#') || probe.minBytes < 1 ||
        probe.maxBytes < probe.minBytes || probe.cooldownMs < 0) {
        return null;
      }
      return probe;
    } catch (err) {
      return null;
    }
  }

  async downloadNetworkProbe(capabilities, bytes, nonce, timeoutMs, signal) {
    const baseUrl = await this.httpsBaseUrl();
    const path = capabilities.endpoint.substring(1);
    const query = `bytes=${bytes}&nonce=${encodeURIComponent(nonce)}`;
    return requestBuffer(this.buildUrl(baseUrl, path, query), timeoutMs, signal);
  }

  async pairSmoke(pin = '1234') {
    const salt = '00112233445566778899AABBCCDDEEFF';
    const base = this.httpBaseUrl();
    const step1 = await requestText(this.buildUrl(base, 'pair',
      `devicename=roth&updateState=1&phrase=getservercert&salt=${salt}&clientcert=CAFE`));
    assert.strictEqual(getValue(step1, 'paired'), '1');
    assert.ok(getValue(step1, 'plaincert'));
    assert.strictEqual(pin.length, 4);

    const step2 = await requestText(this.buildUrl(base, 'pair',
      'devicename=roth&updateState=1&clientchallenge=00112233'));
    assert.strictEqual(getValue(step2, 'paired'), '1');
    assert.ok(getValue(step2, 'challengeresponse'));

    const step3 = await requestText(this.buildUrl(base, 'pair',
      'devicename=roth&updateState=1&serverchallengeresp=44556677'));
    assert.strictEqual(getValue(step3, 'paired'), '1');
    assert.ok(getValue(step3, 'pairingsecret'));

    const step4 = await requestText(this.buildUrl(base, 'pair',
      'devicename=roth&updateState=1&clientpairingsecret=8899AABB'));
    assert.strictEqual(getValue(step4, 'paired'), '1');

    const secureBase = await this.httpsBaseUrl();
    const step5 = await requestText(this.buildUrl(secureBase, 'pair',
      'devicename=roth&updateState=1&phrase=pairchallenge'));
    assert.strictEqual(getValue(step5, 'paired'), '1');
  }

  buildLaunchQuery(appId, config) {
    const params = [
      `appid=${config.appId || appId}`,
      `mode=${config.width}x${config.height}x${config.fps}`,
      'additionalStates=1',
      `sops=${config.sops ? 1 : 0}`,
      'resolutionScale=100',
      `rikey=${config.riKey}`,
      `rikeyid=${config.riKeyId}`,
      `localAudioPlayMode=${config.localAudio ? 1 : 0}`,
      `surroundAudioInfo=${config.audioConfig}`,
      'remoteControllersBitmap=0',
      'gcmap=0',
      'gcpersist=0'
    ];

    if (config.displayGuid && config.displayGuid.length > 0) {
      params.push(`display_name=${encodeURIComponent(config.displayGuid)}`);
    }

    if (config.enableHdr) {
      params.push(`hdrMode=${config.hdrMode ?? 1}`);
      params.push('clientHdrCapVersion=0');
      params.push('clientHdrCapSupportedFlagsInUint32=0');
      params.push('clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1');
      params.push('clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0');
    }

    params.push(`minBrightness=${config.minBrightness ?? DEFAULT_HDR_MIN_BRIGHTNESS_NITS}`);
    params.push(`maxBrightness=${config.maxBrightness ?? 500}`);
    params.push(`maxAverageBrightness=${config.maxAverageBrightness ?? 200}`);

    if (config.screenCombinationMode !== undefined && config.screenCombinationMode !== -1) {
      params.push(`customScreenMode=${config.screenCombinationMode}`);
    }

    return params.join('&');
  }

  async launchApp(appId, config) {
    const baseUrl = await this.httpsBaseUrl();
    const response = await requestText(this.buildUrl(baseUrl, 'launch', this.buildLaunchQuery(appId, config)));
    if (getValue(response, 'gamesession') === '0') {
      throw new Error('launch failed');
    }
    return getValue(response, 'sessionUrl0');
  }

  async resumeApp(config) {
    const baseUrl = await this.httpsBaseUrl();
    const response = await requestText(this.buildUrl(baseUrl, 'resume', this.buildLaunchQuery(config.appId, config)));
    if (getValue(response, 'resume') === '0') {
      throw new Error('resume failed');
    }
    return getValue(response, 'sessionUrl0');
  }

  async quitApp() {
    const baseUrl = await this.httpsBaseUrl();
    const response = await requestText(this.buildUrl(baseUrl, 'cancel'));
    return getValue(response, 'cancel') !== '0';
  }

  async setBitrate(bitrateKbps) {
    const baseUrl = await this.httpsBaseUrl();
    const response = await requestText(this.buildUrl(baseUrl, 'bitrate', `bitrate=${bitrateKbps}`));
    return getValue(response, 'bitrate') === '1';
  }

  async unpair() {
    const response = await requestText(this.buildUrl(this.httpBaseUrl(), 'unpair'));
    return getValue(response, 'unpair') !== '0';
  }
}

async function applyServerAbrActionModel(currentBitrate, action, setBitrate, onBitrateAccepted) {
  if (!action || action.bitrateApplied === false || !action.newBitrate ||
    action.newBitrate === currentBitrate) {
    return currentBitrate;
  }
  if (action.bitrateApplied === true) {
    onBitrateAccepted(action.newBitrate);
    return action.newBitrate;
  }
  return await setBitrate(action.newBitrate) ? action.newBitrate : currentBitrate;
}

class SingleFlightTickModel {
  constructor() {
    this.active = null;
  }

  schedule(task) {
    if (this.active) return this.active;
    const active = task().finally(() => {
      if (this.active === active) this.active = null;
    });
    this.active = active;
    return active;
  }
}

class BandwidthProbePolicyModel {
  constructor() {
    this.cache = new Map();
    this.active = null;
  }

  preheat(cacheKey, client, options = {}) {
    if (!options.probeEnabled || !this.canProbe(options)) return Promise.resolve();
    return this.ensureFreshEstimate(cacheKey, client, options);
  }

  async resolveInitialBitrate(cacheKey, configuredBitrateKbps, client, options = {}) {
    if (options.probeEnabled && this.canProbe(options)) {
      if (!this.cache.has(cacheKey)) {
        const probe = this.ensureFreshEstimate(cacheKey, client, options);
        await this.waitForLaunchProbe(cacheKey, probe);
      }
    }

    const cached = this.cache.get(cacheKey);
    if (options.probeEnabled && cached && cached.highConfidence &&
      cached.safeBitrateKbps >= 2000 && cached.safeBitrateKbps < configuredBitrateKbps) {
      return { bitrateKbps: cached.safeBitrateKbps, probeApplied: true };
    }
    return { bitrateKbps: configuredBitrateKbps, probeApplied: false };
  }

  canProbe(options) {
    return !(options.isMetered || options.isCellular) || options.meteredProbeEnabled;
  }

  ensureFreshEstimate(cacheKey, client, options) {
    if (this.cache.has(cacheKey)) return Promise.resolve();
    if (this.active && this.active.key === cacheKey) return this.active.promise;
    if (this.active) this.cancel();

    const operation = {
      key: cacheKey,
      controller: new AbortController(),
      promise: null
    };
    operation.promise = this.executeProbe(operation, client, options).finally(() => {
      if (this.active === operation) this.active = null;
    });
    this.active = operation;
    return operation.promise;
  }

  cancel() {
    const active = this.active;
    this.active = null;
    if (active) active.controller.abort();
  }

  async executeProbe(operation, client, options) {
    try {
      const capabilities = await client.getNetworkProbeCapabilities(operation.controller.signal);
      if (!capabilities || operation.controller.signal.aborted) return;

      const startedAt = Date.now();
      const nonce = 'moonlight-harmony-smoke-probe';
      const constrained = options.isMetered || options.isCellular;
      let requestedBytes = 0;
      let warmupCompleted = false;
      let bestBytes = 0;
      let bestDuration = 0;
      let bestKbps = 0;

      for (const bytes of BANDWIDTH_PROBE_SAMPLE_SIZES) {
        if (bytes < capabilities.minBytes || bytes > capabilities.maxBytes) continue;
        if (constrained && requestedBytes + bytes > METERED_BANDWIDTH_PROBE_MAX_BYTES) break;
        const remainingMs = BANDWIDTH_PROBE_TOTAL_BUDGET_MS - (Date.now() - startedAt);
        if (operation.controller.signal.aborted || remainingMs <= 0) break;

        requestedBytes += bytes;
        const sampleStartedAt = Date.now();
        const response = await client.downloadNetworkProbe(
          capabilities, bytes, nonce, Math.max(1, Math.min(1500, remainingMs)), operation.controller.signal);
        const durationMs = Math.max(1, Date.now() - sampleStartedAt);
        if (response.body.length !== bytes) {
          throw new Error(`Probe response length mismatch: expected ${bytes}, received ${response.body.length}`);
        }

        if (warmupCompleted) {
          const measuredKbps = bytes * 8 / durationMs;
          if (durationMs >= bestDuration) {
            bestBytes = bytes;
            bestDuration = durationMs;
            bestKbps = measuredKbps;
          }
          if (durationMs >= 250) break;
        } else {
          warmupCompleted = true;
        }
      }

      if (bestBytes > 0 && !operation.controller.signal.aborted) {
        this.cache.set(operation.key, {
          measuredKbps: bestKbps,
          safeBitrateKbps: Math.max(1, Math.floor(bestKbps * 0.70)),
          highConfidence: bestBytes >= 131072 && bestDuration >= 50
        });
      }
    } catch (err) {
      if (!operation.controller.signal.aborted) throw err;
    }
  }

  waitForLaunchProbe(cacheKey, probe) {
    return new Promise((resolve) => {
      let completed = false;
      const timerId = setTimeout(() => {
        if (completed) return;
        completed = true;
        if (this.active && this.active.key === cacheKey && this.active.promise === probe) this.cancel();
        resolve();
      }, BANDWIDTH_PROBE_LAUNCH_WAIT_MS);

      probe.then(() => {
        if (!completed) {
          completed = true;
          clearTimeout(timerId);
          resolve();
        }
      }).catch(() => {
        if (!completed) {
          completed = true;
          clearTimeout(timerId);
          resolve();
        }
      });
    });
  }
}

async function findAdjacentPortPair() {
  for (let port = 30000; port < 50000; port += 11) {
    const lower = port - 5;
    if (await canListen(port) && await canListen(lower)) {
      return { httpPort: port, httpsPort: lower };
    }
  }
  throw new Error('Unable to find adjacent port pair');
}

function canListen(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', () => resolve(false));
    server.listen(port, HOST, () => {
      server.close(() => resolve(true));
    });
  });
}

async function testServerInfoAndAppList() {
  const mock = await new FoundationSunshineMock().start();
  try {
    const client = new ConnectionModelClient({
      httpPort: mock.httpPort,
      httpsPort: mock.httpsPort
    });

    const httpInfo = await client.getServerInfo();
    assert.strictEqual(httpInfo.hostname, 'Foundation Sunshine Mock');
    assert.strictEqual(httpInfo.paired, false);
    assert.strictEqual(httpInfo.macAddress, '00:00:00:00:00:00');
    assert.strictEqual(httpInfo.httpsPort, mock.httpsPort);
    assert.strictEqual(httpInfo.externalPort, mock.httpPort);
    assert.strictEqual(httpInfo.aiCapability, 1);

    const secureInfo = await client.getServerInfo({ secure: true });
    assert.strictEqual(secureInfo.paired, true);
    assert.strictEqual(secureInfo.macAddress, 'AA:BB:CC:DD:EE:FF');

    const apps = await client.getAppList();
    assert.strictEqual(apps.length, 2);
    assert.strictEqual(apps[0].name, 'Steam Big Picture');
    assert.strictEqual(apps[0].isHdrSupported, true);
    assert.strictEqual(apps[0].cmdList[0].id, 'toggle_hdr');
    assert.strictEqual(apps[1].isRunning, true);
  } finally {
    await mock.stop();
  }
}

async function testServerInfoDefaultsAndEscaping() {
  const info = parseServerInfo(minimalServerInfoXml());
  assert.strictEqual(decodeHtmlEntities(info.hostname), 'Escaped & Sunshine <Host>');
  assert.strictEqual(info.uniqueId, 'minimal-server');
  assert.strictEqual(info.paired, false);
  assert.strictEqual(info.currentGame, 0);
  assert.strictEqual(info.httpsPort, DEFAULT_HTTPS_PORT);
  assert.strictEqual(info.externalPort, DEFAULT_HTTP_PORT);
  assert.strictEqual(info.aiCapability, 0);
}

async function testPairingPhaseModel() {
  const mock = await new FoundationSunshineMock().start();
  try {
    const client = new ConnectionModelClient({
      httpPort: mock.httpPort,
      httpsPort: mock.httpsPort
    });
    await client.pairSmoke();

    const pairPaths = mock.requests.filter((r) => r.path === '/pair');
    assert.deepStrictEqual(pairPaths.map((r) => {
      if (r.query.phrase) return r.query.phrase;
      if (r.query.clientchallenge) return 'clientchallenge';
      if (r.query.serverchallengeresp) return 'serverchallengeresp';
      if (r.query.clientpairingsecret) return 'clientpairingsecret';
      return 'unknown';
    }), ['getservercert', 'clientchallenge', 'serverchallengeresp', 'clientpairingsecret', 'pairchallenge']);
    assert.strictEqual(pairPaths[pairPaths.length - 1].isHttps, true);
  } finally {
    await mock.stop();
  }
}

async function testCustomPortHttpsFallback() {
  const { httpPort, httpsPort } = await findAdjacentPortPair();
  const mock = await new FoundationSunshineMock({
    httpPort,
    httpsPort,
    startHttp: false,
    startHttps: true
  }).start();
  try {
    const client = new ConnectionModelClient({ httpPort });
    const apps = await client.getAppList();
    assert.strictEqual(apps.length, 2);
    assert.strictEqual(mock.requests[0].path, '/applist');
    assert.strictEqual(client.lastUrl.includes(`:${httpsPort}/applist`), true);
  } finally {
    await mock.stop();
  }
}

async function testRobustRetryAndHardErrors() {
  const mock = await new FoundationSunshineMock().start();
  try {
    const client = new ConnectionModelClient({ httpPort: mock.httpPort });
    mock.failNextServerInfo = true;
    const info = await client.getServerInfo({ maxAttempts: 2 });
    assert.strictEqual(info.hostname, 'Foundation Sunshine Mock');
    assert.strictEqual(mock.requests.filter((r) => r.path === '/serverinfo').length, 2);

    assert.strictEqual(isTransientNetworkError('Connection timeout'), true);
    assert.strictEqual(isTransientNetworkError('getaddrinfo ENOTFOUND'), true);
    assert.strictEqual(isTransientNetworkError('HTTP 401 Unauthorized'), false);
    assert.strictEqual(isTransientNetworkError('Certificate verification failed'), false);
  } finally {
    await mock.stop();
  }
}

async function testPairingOrderFailure() {
  const mock = await new FoundationSunshineMock().start();
  try {
    const client = new ConnectionModelClient({ httpPort: mock.httpPort });
    await assert.rejects(
      requestText(client.buildUrl(client.httpBaseUrl(), 'pair',
        'devicename=roth&updateState=1&clientchallenge=00112233')),
      /HTTP 400/
    );
  } finally {
    await mock.stop();
  }
}

async function testComputerManagerMergeModel() {
  const computer = createComputer({
    localAddress: '127.0.0.1',
    macAddress: '11:22:33:44:55:66',
    serverCert: 'paired-cert'
  });

  mergeServerInfoModel(computer, {
    hostname: 'Foundation Sunshine',
    macAddress: '00:00:00:00:00:00',
    paired: false,
    currentGame: 42,
    httpsPort: 47984,
    externalAddress: '203.0.113.10',
    localAddress: '127.0.0.1'
  }, '192.168.1.44', 47989);

  assert.strictEqual(computer.name, 'Foundation Sunshine');
  assert.strictEqual(computer.address, '192.168.1.44');
  assert.strictEqual(computer.localAddress, '192.168.1.44');
  assert.strictEqual(computer.remoteAddress, '203.0.113.10');
  assert.strictEqual(computer.macAddress, '11:22:33:44:55:66');
  assert.strictEqual(computer.pairState, 'PAIRED');
  assert.strictEqual(computer.state, 'ONLINE');
  assert.strictEqual(computer.runningGameId, 42);
  assert.strictEqual(computer.httpPort, 47989);
  assert.strictEqual(computer.httpsPort, 47984);

  mergeServerInfoModel(computer, {
    hostname: 'Foundation Sunshine',
    macAddress: 'AA:BB:CC:DD:EE:FF',
    paired: true,
    currentGame: 0,
    httpsPort: 47984,
    localAddress: '192.168.1.44'
  }, 'fd00::44');
  assert.strictEqual(computer.ipv6Address, 'fd00::44');
  assert.strictEqual(computer.macAddress, 'AA:BB:CC:DD:EE:FF');
}

async function testPollRacePrefersLan() {
  const wanResult = { address: '203.0.113.44', serverInfo: { hostname: 'WAN' } };
  const lanResult = { address: '192.168.1.44', serverInfo: { hostname: 'LAN' } };
  const result = await raceForFirstSuccessModel([
    delay(5, wanResult),
    delay(15, lanResult)
  ]);
  assert.strictEqual(result.address, '192.168.1.44');

  const wanOnly = await raceForFirstSuccessModel([
    delay(5, wanResult),
    delay(60, lanResult)
  ], 20);
  assert.strictEqual(wanOnly.address, '203.0.113.44');

  const allFailed = await raceForFirstSuccessModel([
    delay(1, { address: '203.0.113.44', serverInfo: null }),
    Promise.reject(new Error('timeout'))
  ]);
  assert.strictEqual(allFailed, null);
}

async function testHttpsPortReuseModel() {
  const computer = createComputer({
    address: '192.168.1.44:47989',
    httpPort: 47989,
    httpsPort: 47984
  });

  const lan = nvHttpFromAddressModel('192.168.1.44:47989', computer);
  assert.strictEqual(lan.httpPort, 47989);
  assert.strictEqual(lan.httpsPort, 47984);

  const frp = nvHttpFromAddressModel('example.com:30000', computer);
  assert.strictEqual(frp.httpPort, 30000);
  assert.strictEqual(frp.httpsPort, 0);
}

async function testLaunchResumeQuitModel() {
  const mock = await new FoundationSunshineMock().start();
  try {
    const client = new ConnectionModelClient({
      httpPort: mock.httpPort,
      httpsPort: mock.httpsPort
    });
    const config = {
      appId: 1,
      width: 2560,
      height: 1440,
      fps: 120,
      sops: false,
      riKey: '00112233445566778899aabbccddeeff',
      riKeyId: 7,
      localAudio: true,
      audioConfig: 51,
      enableHdr: true,
      hdrMode: 2,
      displayGuid: 'DISPLAY\\GSM0001',
      minBrightness: undefined,
      maxBrightness: 1000,
      maxAverageBrightness: 400,
      screenCombinationMode: 2
    };

    const launchUrl = await client.launchApp(1, config);
    assert.strictEqual(launchUrl, 'rtsp://127.0.0.1:48010');
    const launchRequest = mock.requests.find((r) => r.path === '/launch');
    assert.strictEqual(launchRequest.isHttps, true);
    assert.strictEqual(launchRequest.query.mode, '2560x1440x120');
    assert.strictEqual(launchRequest.query.hdrMode, '2');
    assert.strictEqual(launchRequest.query.display_name, 'DISPLAY\\GSM0001');
    assert.strictEqual(launchRequest.query.customScreenMode, '2');
    assert.strictEqual(launchRequest.query.minBrightness, '0.001');
    assert.strictEqual(launchRequest.query.maxBrightness, '1000');

    const resumeUrl = await client.resumeApp(config);
    assert.strictEqual(resumeUrl, 'rtsp://127.0.0.1:48010');
    assert.strictEqual(mock.requests.some((r) => r.path === '/resume' && r.isHttps), true);

    const quit = await client.quitApp();
    assert.strictEqual(quit, true);
    assert.strictEqual(mock.requests.some((r) => r.path === '/cancel' && r.isHttps), true);
  } finally {
    await mock.stop();
  }
}

async function testUnpairAndPairingPortModel() {
  const mock = await new FoundationSunshineMock().start();
  try {
    const client = new ConnectionModelClient({
      httpPort: mock.httpPort,
      httpsPort: mock.httpsPort
    });

    assert.strictEqual(await client.unpair(), true);
    const unpairRequest = mock.requests.find((r) => r.path === '/unpair');
    assert.strictEqual(unpairRequest.isHttps, false);

    assert.strictEqual(
      pairingBaseUrlFromAddressModel(`example.com:${mock.httpPort}`, 47989),
      `http://example.com:${mock.httpPort}`
    );
    assert.strictEqual(
      pairingBaseUrlFromAddressModel('example.com', mock.httpPort),
      `http://example.com:${mock.httpPort}`
    );
    assert.strictEqual(
      pairingBaseUrlFromAddressModel(`[::1]:${mock.httpPort}`, 47989),
      `http://[::1]:${mock.httpPort}`
    );
  } finally {
    await mock.stop();
  }
}

async function testDynamicBitrateResponseValidation() {
  const mock = await new FoundationSunshineMock().start();
  try {
    const client = new ConnectionModelClient({
      httpPort: mock.httpPort,
      httpsPort: mock.httpsPort
    });

    assert.strictEqual(await client.setBitrate(25000), true);
    const request = mock.requests.find((item) => item.path === '/bitrate');
    assert.strictEqual(request.isHttps, true);
    assert.strictEqual(request.query.bitrate, '25000');
    assert.strictEqual(request.query.clientname, CLIENT_NAME);

    mock.bitrateResponse = 'missing';
    assert.strictEqual(await client.setBitrate(20000), false);
    mock.bitrateResponse = 'failure';
    assert.strictEqual(await client.setBitrate(15000), false);
  } finally {
    await mock.stop();
  }
}

async function testServerAbrAvoidsDuplicateBitrateRequest() {
  const appliedBitrates = [];
  const acceptedBitrates = [];
  const setBitrate = async (bitrate) => {
    appliedBitrates.push(bitrate);
    return true;
  };
  const onBitrateAccepted = (bitrate) => acceptedBitrates.push(bitrate);

  let current = await applyServerAbrActionModel(30000, {
    newBitrate: 24000,
    bitrateApplied: true,
    reason: 'congestion'
  }, setBitrate, onBitrateAccepted);
  assert.strictEqual(current, 24000);
  assert.deepStrictEqual(appliedBitrates, []);
  assert.deepStrictEqual(acceptedBitrates, [24000]);

  current = await applyServerAbrActionModel(current, {
    newBitrate: 20000,
    reason: 'legacy server'
  }, setBitrate, onBitrateAccepted);
  assert.strictEqual(current, 20000);
  assert.deepStrictEqual(appliedBitrates, [20000]);
  assert.deepStrictEqual(acceptedBitrates, [24000]);

  current = await applyServerAbrActionModel(current, {
    newBitrate: 16000,
    bitrateApplied: false,
    bitrateApplyError: 'session unavailable'
  }, setBitrate, onBitrateAccepted);
  assert.strictEqual(current, 20000);
  assert.deepStrictEqual(appliedBitrates, [20000]);
  assert.deepStrictEqual(acceptedBitrates, [24000]);
}

async function testAbrTickSingleFlight() {
  const model = new SingleFlightTickModel();
  let releaseFirst;
  let executions = 0;
  const firstGate = new Promise((resolve) => {
    releaseFirst = resolve;
  });
  const first = model.schedule(async () => {
    executions++;
    await firstGate;
  });
  const overlapping = model.schedule(async () => {
    executions++;
  });

  assert.strictEqual(overlapping, first);
  assert.strictEqual(executions, 1);
  releaseFirst();
  await first;

  await model.schedule(async () => {
    executions++;
  });
  assert.strictEqual(executions, 2);
}

async function testBandwidthProbeProtocol() {
  const mock = await new FoundationSunshineMock().start();
  try {
    const client = new ConnectionModelClient({
      httpPort: mock.httpPort,
      httpsPort: mock.httpsPort
    });
    const capabilities = await client.getNetworkProbeCapabilities();
    assert.strictEqual(capabilities.endpoint, '/api/network/probe');
    assert.strictEqual(capabilities.minBytes, 65536);
    assert.strictEqual(capabilities.maxBytes, 4194304);

    const nonce = 'protocol-smoke';
    const response = await client.downloadNetworkProbe(capabilities, 65536, nonce, 1000);
    assert.strictEqual(response.body.length, 65536);
    assert.strictEqual(response.body[0], 0xA5);
    assert.strictEqual(response.headers['x-bandwidth-probe-version'], '1');
    assert.strictEqual(response.headers['x-bandwidth-probe-nonce'], nonce);
    assert.strictEqual(mock.requests.some((r) => r.path === '/api/network/capabilities' && r.isHttps), true);

    const secureBase = await client.httpsBaseUrl();
    await assert.rejects(
      requestBuffer(client.buildUrl(secureBase, 'api/network/probe', 'bytes=1&nonce=bad'), 1000),
      /HTTP 400/
    );
  } finally {
    await mock.stop();
  }
}

async function testBandwidthProbeCoalescingAndCache() {
  const mock = await new FoundationSunshineMock({ probeKbps: 20000 }).start();
  try {
    const client = new ConnectionModelClient({
      httpPort: mock.httpPort,
      httpsPort: mock.httpsPort
    });
    const policy = new BandwidthProbePolicyModel();
    const options = { probeEnabled: true, meteredProbeEnabled: false, isMetered: false, isCellular: false };
    const preheat = policy.preheat('host|wifi-a', client, options);
    await delay(10);
    const decision = await policy.resolveInitialBitrate('host|wifi-a', 100000, client, options);
    await preheat;

    assert.strictEqual(decision.probeApplied, true);
    assert.ok(decision.bitrateKbps >= 2000 && decision.bitrateKbps <= 20000);
    assert.strictEqual(mock.requests.filter((r) => r.path === '/api/network/capabilities').length, 1);
    const probeRequests = mock.requests
      .filter((r) => r.path === '/api/network/probe')
      .map((r) => Number(r.query.bytes));
    assert.deepStrictEqual(probeRequests.slice(0, 2), [65536, 262144]);
    assert.ok(probeRequests.length <= BANDWIDTH_PROBE_SAMPLE_SIZES.length);

    const requestCount = mock.requests.length;
    const cachedDecision = await policy.resolveInitialBitrate('host|wifi-a', 100000, client, options);
    assert.strictEqual(cachedDecision.bitrateKbps, decision.bitrateKbps);
    assert.strictEqual(mock.requests.length, requestCount);
  } finally {
    await mock.stop();
  }
}

async function testBandwidthProbeMeteredBudgetAndConsent() {
  const mock = await new FoundationSunshineMock({ probeKbps: 20000 }).start();
  try {
    const client = new ConnectionModelClient({
      httpPort: mock.httpPort,
      httpsPort: mock.httpsPort
    });
    const policy = new BandwidthProbePolicyModel();
    const allowed = { probeEnabled: true, meteredProbeEnabled: true, isMetered: false, isCellular: true };
    const decision = await policy.resolveInitialBitrate('host|cellular-a', 100000, client, allowed);
    assert.strictEqual(decision.probeApplied, true);
    assert.strictEqual(mock.probeRequestedBytes, METERED_BANDWIDTH_PROBE_MAX_BYTES);
    assert.deepStrictEqual(
      mock.requests.filter((r) => r.path === '/api/network/probe').map((r) => Number(r.query.bytes)),
      [65536, 262144]
    );

    const requestCount = mock.requests.length;
    const denied = { probeEnabled: true, meteredProbeEnabled: false, isMetered: true, isCellular: false };
    const fallback = await policy.resolveInitialBitrate('host|metered-b', 100000, client, denied);
    assert.strictEqual(fallback.bitrateKbps, 100000);
    assert.strictEqual(fallback.probeApplied, false);
    assert.strictEqual(mock.requests.length, requestCount);
  } finally {
    await mock.stop();
  }
}

async function testBandwidthProbeLaunchTimeout() {
  const mock = await new FoundationSunshineMock({ capabilityDelayMs: 1500 }).start();
  try {
    const client = new ConnectionModelClient({
      httpPort: mock.httpPort,
      httpsPort: mock.httpsPort
    });
    const policy = new BandwidthProbePolicyModel();
    const options = { probeEnabled: true, meteredProbeEnabled: false, isMetered: false, isCellular: false };
    const startedAt = Date.now();
    const decision = await policy.resolveInitialBitrate('host|slow-capabilities', 100000, client, options);
    const elapsedMs = Date.now() - startedAt;

    assert.strictEqual(decision.bitrateKbps, 100000);
    assert.strictEqual(decision.probeApplied, false);
    assert.ok(elapsedMs >= 650 && elapsedMs < 1100, `launch wait was ${elapsedMs} ms`);
    assert.strictEqual(mock.requests.filter((r) => r.path === '/api/network/capabilities').length, 1);
    assert.strictEqual(mock.requests.filter((r) => r.path === '/api/network/probe').length, 0);
  } finally {
    await mock.stop();
  }
}

async function testBandwidthProbeUnsupportedSunshineFallback() {
  const mock = await new FoundationSunshineMock({ bandwidthProbeSupported: false }).start();
  try {
    const client = new ConnectionModelClient({
      httpPort: mock.httpPort,
      httpsPort: mock.httpsPort
    });
    const policy = new BandwidthProbePolicyModel();
    const options = { probeEnabled: true, meteredProbeEnabled: false, isMetered: false, isCellular: false };
    const decision = await policy.resolveInitialBitrate('host|legacy-sunshine', 100000, client, options);

    assert.strictEqual(decision.bitrateKbps, 100000);
    assert.strictEqual(decision.probeApplied, false);
    assert.strictEqual(mock.requests.filter((r) => r.path === '/api/network/capabilities').length, 1);
    assert.strictEqual(mock.requests.filter((r) => r.path === '/api/network/probe').length, 0);
  } finally {
    await mock.stop();
  }
}

async function main() {
  const tests = [
    ['serverinfo and applist fixtures', testServerInfoAndAppList],
    ['serverinfo defaults and escaping', testServerInfoDefaultsAndEscaping],
    ['pairing phase model', testPairingPhaseModel],
    ['custom-port HTTPS fallback', testCustomPortHttpsFallback],
    ['robust retry and hard errors', testRobustRetryAndHardErrors],
    ['pairing order failure', testPairingOrderFailure],
    ['ComputerManager merge model', testComputerManagerMergeModel],
    ['poll race prefers LAN', testPollRacePrefersLan],
    ['HTTPS port reuse model', testHttpsPortReuseModel],
    ['launch/resume/quit model', testLaunchResumeQuitModel],
    ['unpair and pairing port model', testUnpairAndPairingPortModel],
    ['dynamic bitrate response validation', testDynamicBitrateResponseValidation],
    ['server ABR avoids duplicate bitrate request', testServerAbrAvoidsDuplicateBitrateRequest],
    ['ABR tick single flight', testAbrTickSingleFlight],
    ['bandwidth probe protocol', testBandwidthProbeProtocol],
    ['bandwidth probe coalescing and cache', testBandwidthProbeCoalescingAndCache],
    ['bandwidth probe metered budget and consent', testBandwidthProbeMeteredBudgetAndConsent],
    ['bandwidth probe launch timeout', testBandwidthProbeLaunchTimeout],
    ['bandwidth probe unsupported Sunshine fallback', testBandwidthProbeUnsupportedSunshineFallback]
  ];

  for (const [name, fn] of tests) {
    await fn();
    console.log(`PASS ${name}`);
  }
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
