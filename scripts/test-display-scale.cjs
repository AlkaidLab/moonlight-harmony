#!/usr/bin/env node
/*
 * Exercise the production NvHttp methods with the HarmonyOS transport mocked.
 * Existing response fields / step fixtures: AlkaidLab/foundation-sunshine @
 * b052a5fc88fe90bd9b849c45b3fda2024e0676a5:
 * - src/nvhttp/display_scale.cpp (routes, nullable values and error bodies)
 * - src/platform/windows/display_device/windows_utils.cpp (pending success)
 * - src/platform/windows/display_device/display_scale_steps.h (#1182's 12 steps)
 * https://github.com/AlkaidLab/foundation-sunshine/tree/b052a5fc88fe90bd9b849c45b3fda2024e0676a5
 *
 * Current-session target and optimistic device identity checks exercise the
 * paired Sunshine / HarmonyOS contract added by this change.
 *
 * No client-side parser or request builder is mirrored here: the loader runs
 * NvHttp.ets itself. Only platform/network dependencies are replaced.
 */
const assert = require('node:assert/strict');
const { loadArkTsModule } = require('./test-helpers/load-arkts.cjs');

const STEPS = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500];
const DISPLAY_NAME = '\\\\.\\DISPLAY 2 & 工作台?#';
const DEVICE_ID = '{display-guid + percent%/显示器}';
const requests = [];
let certificatePresent = true;
let respond;

const { NvHttp, DisplayScaleError } = loadArkTsModule(
  'entry/src/main/ets/service/streaming/NvHttp.ets', {
    DEFAULT_HTTP_PORT: 47989,
    DEFAULT_HTTPS_PORT: 47984,
    Logger: { debug() {}, info() {}, warn() {}, error() {} },
    StringUtil: { generateUUID: () => 'request-uuid' },
    fileIo: { accessSync: () => certificatePresent },
    formatAddressForUrl: address => address,
    parseAddressAndPort: address => {
      const parsed = new URL('http://' + address);
      return { host: parsed.hostname, port: Number(parsed.port) };
    },
    HttpClient: {
      async requestRaw(url, method, body, config) {
        const request = { url: new URL(url), method, body, config };
        requests.push(request);
        return respond(request);
      }
    }
  }, ['NvHttp', 'DisplayScaleError']);

function client() {
  // Avoid initializing device identity/files; retain every production method.
  return Object.assign(Object.create(NvHttp.prototype), {
    address: 'sunshine.test',
    httpPort: 47989,
    httpsPort: 47984,
    uniqueId: 'paired-client',
    clientName: '测试客户端 + UI',
    certFilePath: '/paired/client_cert.pem',
    keyFilePath: '/paired/client_key.pem'
  });
}

function options(overrides = {}) {
  return {
    status_code: 200, status_message: 'OK', success: true, target: 'current',
    display_name: DISPLAY_NAME, device_id: DEVICE_ID,
    friendly_name: 'Streaming monitor', is_primary: false,
    current_scale_percent: 500, recommended_scale_percent: 175,
    supported_scale_percents: STEPS, scale_set_supported: true,
    ...overrides
  };
}

function result(overrides = {}) {
  return {
    status_code: 200, status_message: 'Display scale changed successfully',
    success: true, target: 'current', display_name: DISPLAY_NAME, device_id: DEVICE_ID,
    previous_scale_percent: 150, current_scale_percent: 500,
    supported_scale_percents: STEPS,
    effective_immediately: true, restart_required: false,
    ...overrides
  };
}

function reply(body, statusCode = 200) {
  requests.length = 0;
  certificatePresent = true;
  respond = () => ({ statusCode, body: JSON.stringify(body) });
}

function assertPairedRequest(request, path, method) {
  assert.equal(request.url.origin, 'https://sunshine.test:47984');
  assert.equal(request.url.pathname, path);
  assert.equal(request.method, method);
  assert.equal(request.url.searchParams.get('uniqueid'), 'paired-client');
  assert.equal(request.url.searchParams.get('clientname'), '测试客户端 + UI');
  assert.equal(request.url.searchParams.get('uuid'), 'request-uuid');
  assert.equal(request.config.clientCertPath, '/paired/client_cert.pem');
  assert.equal(request.config.clientKeyPath, '/paired/client_key.pem');
  assert.equal(request.config.headers.Accept, 'application/json');
  assert.equal(request.config.headers['Content-Type'], 'application/json');
  assert.equal(request.config.connectTimeout, NvHttp.CONNECTION_TIMEOUT);
  assert.equal(request.config.transferTimeout, NvHttp.LONG_CONNECTION_TIMEOUT);
}

async function run() {
  reply(options());
  const supported = await client().getDisplayScaleOptions();
  assert.equal(supported.currentScalePercent, 500);
  assert.equal(supported.recommendedScalePercent, 175);
  assert.deepEqual(Array.from(supported.supportedScalePercents), STEPS);
  assert.equal(supported.scaleSetSupported, true);
  assert.equal(supported.deviceId, DEVICE_ID);
  assert.equal(requests.length, 1);
  assertPairedRequest(requests[0], '/display-scale-options', 'GET');
  assert.equal(requests[0].body, undefined);
  assert.equal(requests[0].url.searchParams.get('target'), 'current');
  assert.equal(requests[0].url.searchParams.has('display_name'), false);
  assert.equal(requests[0].url.searchParams.has('device_id'), false);
  assert.equal(requests[0].url.searchParams.getAll('target').length, 1);

  // A host which ignores target=current must never make a primary-display
  // response look like the active session target.
  for (const overrides of [
    { target: undefined },
    { target: 'primary' },
    { device_id: '' },
    { device_id: '   ' }
  ]) {
    reply(options(overrides));
    await assert.rejects(() => client().getDisplayScaleOptions(), error => {
      assert.ok(error instanceof DisplayScaleError);
      assert.equal(error.errorCode, 'invalid_response');
      return true;
    });
    assert.equal(requests.length, 1);
  }

  for (const current of [null, undefined]) {
    reply(options({ current_scale_percent: current, recommended_scale_percent: current }));
    const nullable = await client().getDisplayScaleOptions();
    assert.equal(nullable.currentScalePercent, null, 'Unknown current DPI must not become 100%.');
    assert.equal(nullable.recommendedScalePercent, null, 'Unknown recommendation must stay unknown.');
  }

  // Runtime JSON may contain values that satisfy the compile-time interface
  // only on paper. Invalid scale fields must be discarded before reaching UI.
  reply(options({ current_scale_percent: '500', recommended_scale_percent: '175',
    supported_scale_percents: ['100', 150, null] }));
  const malformedOptions = await client().getDisplayScaleOptions();
  assert.equal(malformedOptions.currentScalePercent, null);
  assert.equal(malformedOptions.recommendedScalePercent, null);
  assert.deepEqual(Array.from(malformedOptions.supportedScalePercents), [150]);

  reply(options({ supported_scale_percents: '500' }));
  const nonArrayOptions = await client().getDisplayScaleOptions();
  assert.deepEqual(Array.from(nonArrayOptions.supportedScalePercents), []);

  reply(result());
  const changed = await client().setDisplayScale(500, supported);
  assert.equal(changed.currentScalePercent, 500);
  assert.equal(changed.previousScalePercent, 150);
  assert.equal(changed.effectiveImmediately, true);
  assert.equal(changed.restartRequired, false);
  assert.deepEqual(Array.from(changed.supportedScalePercents), STEPS);
  assert.equal(requests.length, 1);
  assertPairedRequest(requests[0], '/display-scale', 'POST');
  assert.deepEqual(JSON.parse(requests[0].body), {
    target: 'current', scale_percent: 500, display_name: DISPLAY_NAME, device_id: DEVICE_ID
  });
  assert.equal(Number.isInteger(JSON.parse(requests[0].body).scale_percent), true);

  for (const overrides of [
    { target: undefined },
    { target: 'primary' },
    { device_id: '' },
    { device_id: '{unrelated-primary-device}' }
  ]) {
    reply(result(overrides));
    await assert.rejects(() => client().setDisplayScale(500, supported), error => {
      assert.ok(error instanceof DisplayScaleError);
      assert.equal(error.errorCode, 'invalid_response');
      return true;
    });
  }

  reply(result({
    current_scale_percent: 150, effective_immediately: false, restart_required: true,
    status_message: 'Display scale was accepted but has not taken effect yet'
  }));
  const pending = await client().setDisplayScale(200, supported);
  assert.equal(pending.success, true);
  assert.equal(pending.currentScalePercent, 150, 'Pending requests must retain the actual current DPI.');
  assert.equal(pending.effectiveImmediately, false);
  assert.equal(pending.restartRequired, true);

  for (const current of [null, undefined]) {
    reply(result({ previous_scale_percent: current, current_scale_percent: current,
      effective_immediately: false, restart_required: true }));
    const nullable = await client().setDisplayScale(500, supported);
    assert.equal(nullable.previousScalePercent, null, 'Unknown previous DPI must not become zero.');
    assert.equal(nullable.currentScalePercent, null, 'Unknown applied DPI must not become the requested value.');
    assert.equal(nullable.effectiveImmediately, false);
  }

  reply(result({ previous_scale_percent: '150', current_scale_percent: '500',
    supported_scale_percents: ['100', 200, null] }));
  const malformedResult = await client().setDisplayScale(500, supported);
  assert.equal(malformedResult.previousScalePercent, null);
  assert.equal(malformedResult.currentScalePercent, null);
  assert.deepEqual(Array.from(malformedResult.supportedScalePercents), [200]);

  reply(result({ supported_scale_percents: '500' }));
  const nonArrayResult = await client().setDisplayScale(500, supported);
  assert.deepEqual(Array.from(nonArrayResult.supportedScalePercents), []);

  const errors = [
    [400, 'unsupported_scale', 'Unsupported display scale', '不支持此 DPI'],
    [400, 'invalid_request', 'Missing or invalid scale_percent', '请求无效'],
    [403, 'permission_denied', 'Display scale is not available for this display', '权限'],
    [404, 'display_not_found', 'Display not found', '找不到'],
    [409, 'no_active_stream', 'No active stream for this client', '串流'],
    [409, 'display_target_changed', 'The current stream display changed', '显示器'],
    [409, 'display_target_unavailable', 'Current capture display is not available', '暂不可用'],
    [409, 'ambiguous_stream', 'Multiple active streams for this client', '多个串流会话'],
    [501, 'unsupported_platform', 'Display scale is not supported on this platform', '不支持调整 DPI']
  ];
  for (const method of ['GET', 'POST']) {
    for (const [statusCode, errorCode, statusMessage, localized] of errors) {
      reply({ status_code: statusCode, success: false,
        status_message: statusMessage, error_code: errorCode }, statusCode);
      await assert.rejects(
        () => method === 'GET'
          ? client().getDisplayScaleOptions()
          : client().setDisplayScale(500, supported), error => {
          assert.ok(error instanceof DisplayScaleError);
          assert.equal(error.statusCode, statusCode);
          assert.equal(error.errorCode, errorCode);
          assert.equal(error.statusMessage, statusMessage);
          assert.ok(error.message.includes(localized), error.message);
          return true;
        });
      assert.equal(requests.length, 1, 'Structured host errors must not be retried.');
    }
  }

  for (const method of ['GET', 'POST']) {
    for (const statusCode of [200, 404]) {
      reply(null, statusCode);
      respond = () => ({ statusCode, body: '<html>Endpoint not found</html>' });
      await assert.rejects(
        () => method === 'GET'
          ? client().getDisplayScaleOptions()
          : client().setDisplayScale(500, supported), error => {
          assert.ok(error instanceof DisplayScaleError);
          assert.equal(error.statusCode, statusCode);
          assert.equal(error.errorCode, statusCode === 200 ? 'invalid_response' : '');
          if (statusCode === 404) assert.ok(error.message.includes('更新 Sunshine'));
          return true;
        });
    }
  }

  for (const value of [125.5, NaN, Infinity, 0, -1, 1001, '150']) {
    reply(result());
    await assert.rejects(() => client().setDisplayScale(value, supported));
    assert.equal(requests.length, 0, 'Invalid DPI values must be rejected before any request.');
  }

  for (const deviceId of ['', '   ']) {
    reply(result());
    await assert.rejects(() => client().setDisplayScale(150, { ...supported, deviceId }));
    assert.equal(requests.length, 0, 'Apply must carry the queried current device identity.');
  }

  // Switching capture displays between opening the picker and applying must
  // reject that stale request. Only a fresh query can authorize the new target.
  reply(options());
  const switching = client();
  const beforeSwitch = await switching.getDisplayScaleOptions();
  const nextDevice = '{new-capture-device}';
  const nextDisplayName = '\\\\.\\DISPLAY9';
  let postCount = 0;
  respond = request => {
    if (request.method === 'GET') {
      return { statusCode: 200, body: JSON.stringify(options({
        device_id: nextDevice, display_name: nextDisplayName
      })) };
    }
    postCount++;
    const body = JSON.parse(request.body);
    if (body.device_id !== nextDevice) {
      return { statusCode: 409, body: JSON.stringify({
        status_code: 409, success: false, error_code: 'display_target_changed',
        status_message: 'The current stream display changed'
      }) };
    }
    return { statusCode: 200, body: JSON.stringify(result({
      device_id: nextDevice, display_name: nextDisplayName
    })) };
  };
  await assert.rejects(() => switching.setDisplayScale(500, beforeSwitch),
    error => error instanceof DisplayScaleError && error.errorCode === 'display_target_changed');
  assert.equal(postCount, 1, 'A target conflict must not silently replay against another display.');
  const afterSwitch = await switching.getDisplayScaleOptions();
  assert.equal(afterSwitch.deviceId, nextDevice);
  assert.equal((await switching.setDisplayScale(500, afterSwitch)).deviceId, nextDevice);
  assert.equal(postCount, 2);

  reply(options());
  certificatePresent = false;
  await assert.rejects(() => client().getDisplayScaleOptions(), error => {
    assert.ok(error instanceof DisplayScaleError);
    assert.equal(error.statusCode, 401);
    assert.equal(error.errorCode, 'pairing_required');
    return true;
  });
  assert.equal(requests.length, 0, 'DPI control must require pairing credentials.');

  // The existing FRP retry must retain the current-session target and expected device.
  reply(result());
  const forwarded = client();
  forwarded.httpPort = 30000;
  forwarded.httpsPort = 47984;
  respond = request => {
    if (request.url.port === '47984') throw new Error('connection timed out');
    return { statusCode: 200, body: JSON.stringify(result()) };
  };
  assert.equal((await forwarded.setDisplayScale(500, supported)).currentScalePercent, 500);
  assert.deepEqual(requests.map(request => request.url.port), ['47984', '29995']);
  assert.equal(requests[0].body, requests[1].body);
  assert.equal(forwarded.httpsPort, 29995);

  console.log('Production NvHttp current-session DPI contract tests passed.');
}

run().catch(error => { console.error(error); process.exitCode = 1; });
