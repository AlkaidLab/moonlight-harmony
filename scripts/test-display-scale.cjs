#!/usr/bin/env node
/* Contract tests for the production NvHttp display-scale methods. */
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
  return Object.assign(Object.create(NvHttp.prototype), {
    address: 'sunshine.test', httpPort: 47989, httpsPort: 47984,
    uniqueId: 'paired-client', clientName: '测试客户端 + UI',
    certFilePath: '/paired/client_cert.pem', keyFilePath: '/paired/client_key.pem'
  });
}

function options(overrides = {}) {
  return {
    status_code: 200, status_message: 'OK', success: true, target: 'current',
    display_name: DISPLAY_NAME, device_id: DEVICE_ID,
    friendly_name: 'Streaming monitor', is_primary: false,
    current_scale_percent: 500, recommended_scale_percent: 175,
    supported_scale_percents: STEPS, scale_set_supported: true, ...overrides
  };
}

function result(overrides = {}) {
  return {
    status_code: 200, status_message: 'Display scale changed successfully',
    success: true, target: 'current', display_name: DISPLAY_NAME, device_id: DEVICE_ID,
    previous_scale_percent: 150, current_scale_percent: 500,
    supported_scale_percents: STEPS, effective_immediately: true,
    restart_required: false, ...overrides
  };
}

function reply(body, statusCode = 200) {
  requests.length = 0;
  certificatePresent = true;
  respond = () => ({ statusCode, body: JSON.stringify(body) });
}

function assertRequest(request, path, method) {
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
}

async function rejectsWith(call, statusCode, errorCode) {
  await assert.rejects(call, error => {
    assert.ok(error instanceof DisplayScaleError);
    assert.equal(error.statusCode, statusCode);
    assert.equal(error.errorCode, errorCode);
    return true;
  });
}

async function run() {
  reply(options());
  const supported = await client().getDisplayScaleOptions();
  assert.equal(supported.deviceId, DEVICE_ID);
  assert.equal(supported.currentScalePercent, 500);
  assert.deepEqual(Array.from(supported.supportedScalePercents), STEPS);
  assertRequest(requests[0], '/display-scale-options', 'GET');
  assert.equal(requests[0].body, undefined);
  assert.equal(requests[0].url.searchParams.get('target'), 'current');

  for (const invalid of [
    options({ target: undefined }), options({ target: 'primary' }), options({ device_id: ' ' })
  ]) {
    reply(invalid);
    await rejectsWith(() => client().getDisplayScaleOptions(), 200, 'invalid_response');
  }

  reply(options({ current_scale_percent: '500', supported_scale_percents: ['100', 150, 0, 125.5] }));
  const sanitized = await client().getDisplayScaleOptions();
  assert.equal(sanitized.currentScalePercent, null);
  assert.deepEqual(Array.from(sanitized.supportedScalePercents), [150]);

  reply(result());
  const changed = await client().setDisplayScale(500);
  assert.equal(changed.currentScalePercent, 500);
  assertRequest(requests[0], '/display-scale', 'POST');
  assert.deepEqual(JSON.parse(requests[0].body), { target: 'current', scale_percent: 500 });

  reply(result({ device_id: '{new-capture-device}', display_name: '\\\\.\\DISPLAY9' }));
  const changedTarget = await client().setDisplayScale(500);
  assert.equal(changedTarget.deviceId, '{new-capture-device}');
  assert.equal(changedTarget.displayName, '\\\\.\\DISPLAY9');
  reply(result({ device_id: '' }));
  await rejectsWith(() => client().setDisplayScale(500), 200, 'invalid_response');

  reply(result({ current_scale_percent: null, previous_scale_percent: null,
    effective_immediately: false, restart_required: true }));
  const pending = await client().setDisplayScale(200);
  assert.equal(pending.currentScalePercent, null);
  assert.equal(pending.previousScalePercent, null);
  assert.equal(pending.effectiveImmediately, false);

  for (const [statusCode, errorCode] of [
    [400, 'unsupported_scale'], [409, 'no_active_stream'], [501, 'unsupported_platform']
  ]) {
    reply({ status_code: statusCode, success: false, status_message: 'host error', error_code: errorCode }, statusCode);
    await rejectsWith(() => client().setDisplayScale(500), statusCode, errorCode);
    assert.equal(requests.length, 1);
  }

  respond = () => ({ statusCode: 200, body: '<html>invalid response</html>' });
  await rejectsWith(() => client().getDisplayScaleOptions(), 200, 'invalid_response');

  for (const value of [0, 125.5, '150']) {
    reply(result());
    await assert.rejects(() => client().setDisplayScale(value));
    assert.equal(requests.length, 0);
  }

  reply(options());
  certificatePresent = false;
  await rejectsWith(() => client().getDisplayScaleOptions(), 401, 'pairing_required');
  assert.equal(requests.length, 0);

  reply(result());
  const forwarded = client();
  forwarded.httpPort = 30000;
  respond = request => {
    if (request.url.port === '47984') throw new Error('connection timed out');
    return { statusCode: 200, body: JSON.stringify(result()) };
  };
  assert.equal((await forwarded.setDisplayScale(500)).currentScalePercent, 500);
  assert.deepEqual(requests.map(request => request.url.port), ['47984', '29995']);
  assert.equal(requests[0].body, requests[1].body);

  console.log('Production NvHttp display-scale contract tests passed.');
}

run().catch(error => { console.error(error); process.exitCode = 1; });
