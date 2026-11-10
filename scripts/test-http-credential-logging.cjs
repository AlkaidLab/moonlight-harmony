const assert = require('node:assert/strict');
const { test } = require('node:test');
const { loadArkTsModule } = require('./test-helpers/load-arkts.cjs');

function fixture() {
  const logs = [];
  const requests = [];
  let failure = null;
  const logger = {};
  for (const level of ['debug', 'info', 'warn', 'error']) {
    logger[level] = (...args) => logs.push(args.map(String).join(' '));
  }
  const session = {
    async fetch(request) {
      requests.push(request.url);
      if (failure) throw new Error(`${failure}: ${request.url}`);
      return { statusCode: 200, body: new ArrayBuffer(1) };
    }
  };
  const { HttpClient } = loadArkTsModule('entry/src/main/ets/utils/HttpClient.ets', {
    Logger: logger,
    StringUtil: { arrayBufferToString: () => '<response/>' },
    RcpSessionPool: { keyFor: () => 'host', acquire: () => session, invalidate() {}, release() {} },
    rcp: { Request: class { constructor(url) { this.url = url; } } }
  }, ['HttpClient']);
  const { NvHttp } = loadArkTsModule('entry/src/main/ets/service/streaming/NvHttp.ets', {
    Logger: logger,
    HttpClient,
    StringUtil: { generateUUID: () => 'request-id' },
    XmlUtil: { getValue: (_xml, key) => key === 'sessionUrl0' ? 'rtspenc://host:48010' : '1' },
    DEFAULT_HTTP_PORT: 47989, DEFAULT_HTTPS_PORT: 47984,
    DEFAULT_HDR_MIN_BRIGHTNESS_NITS: 0, DEFAULT_HDR_MAX_BRIGHTNESS_NITS: 1000,
    DEFAULT_HDR_MAX_FULL_FRAME_BRIGHTNESS_NITS: 400
  }, ['NvHttp']);
  const client = Object.assign(Object.create(NvHttp.prototype), {
    uniqueId: 'client', clientName: 'client', certFilePath: 'cert', keyFilePath: 'key',
    getHttpsBaseUrl: async () => 'https://host:47984'
  });
  return { client, logs, requests, fail: message => { failure = message; } };
}

const secret = 'aabbccddeeff00112233445566778899';
const config = {
  appId: 1, width: 1920, height: 1080, fps: 60,
  riKey: secret, riKeyId: 123, audioConfig: '0'
};

test('launch and resume send the key without logging it', async () => {
  const f = fixture();
  assert.equal(await f.client.launchApp(1, config), 'rtspenc://host:48010');
  assert.equal(await f.client.resumeApp(config), 'rtspenc://host:48010');
  assert.equal(f.requests.length, 2);
  for (const request of f.requests) assert.ok(request.includes(`rikey=${secret}`));
  assert.ok(!f.logs.join('\n').includes(secret));
});

test('network errors preserve the failure reason without exposing the key', async () => {
  for (const reason of ['connection refused', 'timeout']) {
    const f = fixture();
    f.fail(reason);
    await assert.rejects(f.client.resumeApp(config), error => {
      assert.ok(error.message.includes(reason));
      assert.ok(!error.message.includes(secret));
      return true;
    });
    assert.ok(!f.logs.join('\n').includes(secret));
  }
});
