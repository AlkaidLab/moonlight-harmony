const assert = require('node:assert/strict');
const test = require('node:test');
const { loadArkTsModule } = require('./test-helpers/load-arkts.cjs');

const { StreamingSession } = loadArkTsModule(
  'entry/src/main/ets/service/streaming/StreamingSession.ets',
  { nativeLib: {}, MoonlightButton: {} }, ['StreamingSession']);

function makeSession(nvHttp) {
  const session = Object.create(StreamingSession.prototype);
  session.nvHttp = nvHttp;
  return session;
}

function options(deviceId = '{capture-device}') {
  return { displayName: '\\\\.\\DISPLAY7', deviceId,
    currentScalePercent: 150, supportedScalePercents: [100, 125, 150] };
}

test('disconnected sessions return null without issuing DPI requests', async () => {
  const session = makeSession(null);
  assert.equal(await session.getDisplayScaleOptions(), null);
  assert.equal(await session.setDisplayScale(150), null);
});

test('DPI queries use Sunshine current capture for every session mode', async () => {
  for (const mode of ['default', 'vdd', 'different-launch-display']) {
    const active = options('{capture-' + mode + '}');
    let enumerated = false;
    const session = makeSession({
      getDisplays: async () => { enumerated = true; return []; },
      getDisplayScaleOptions: async () => active
    });
    assert.strictEqual(await session.getDisplayScaleOptions(), active);
    assert.equal(enumerated, false);
  }
});

test('DPI apply forwards only the requested scale', async () => {
  const calls = [];
  const result = { success: true, currentScalePercent: 150 };
  const session = makeSession({
    setDisplayScale: async (...args) => { calls.push(args); return result; },
    getDisplays: async () => { throw new Error('must not enumerate displays'); }
  });
  assert.strictEqual(await session.setDisplayScale(150), result);
  assert.deepEqual(calls, [[150]]);
});

test('current-display errors propagate without fallback or retry', async () => {
  const failure = Object.assign(new Error('no active stream'), {
    statusCode: 409, errorCode: 'no_active_stream'
  });
  const session = makeSession({
    getDisplayScaleOptions: async () => { throw failure; },
    setDisplayScale: async () => { throw failure; },
    getDisplays: async () => { throw new Error('must not enumerate displays'); }
  });
  await assert.rejects(session.getDisplayScaleOptions(), error => error === failure);
  await assert.rejects(session.setDisplayScale(150), error => error === failure);
});
