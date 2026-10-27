const assert = require('node:assert/strict');
const test = require('node:test');
const { loadArkTsModule } = require('./test-helpers/load-arkts.cjs');

// Run the production class without constructing device services or starting a stream.
const { StreamingSession } = loadArkTsModule(
  'entry/src/main/ets/service/streaming/StreamingSession.ets',
  { nativeLib: {}, MoonlightButton: {} },
  ['StreamingSession']
);

function makeSession(nvHttp, displayGuid = '', useVdd = false) {
  const session = Object.create(StreamingSession.prototype);
  session.nvHttp = nvHttp;
  session.displayGuid = displayGuid;
  session.useVdd = useVdd;
  return session;
}

function options(deviceId = '{current-capture-device}') {
  return {
    displayName: '\\\\.\\DISPLAY7',
    deviceId,
    currentScalePercent: null,
    supportedScalePercents: [100, 125, 150]
  };
}

test('a disconnected session does not send either current-display DPI request', async () => {
  const session = makeSession(null);
  assert.equal(await session.getDisplayScaleOptions(), null);
  assert.equal(await session.setDisplayScale(150, options()), null);
});

for (const scenario of [
  { title: 'default/resumed stream', displayGuid: '', useVdd: false },
  { title: 'VDD stream', displayGuid: '', useVdd: true },
  { title: 'stream launched on a different display', displayGuid: '{old-launch-device}', useVdd: false }
]) {
  test('the ' + scenario.title + ' queries the active capture instead of enumerating or guessing a screen', async () => {
    const calls = [];
    const active = options();
    const session = makeSession({
      getDisplays: async () => { throw new Error('DPI must not enumerate displays'); },
      getDisplayScaleOptions: async (...args) => {
        calls.push(args);
        return active;
      }
    }, scenario.displayGuid, scenario.useVdd);
    assert.strictEqual(await session.getDisplayScaleOptions(), active);
    assert.deepEqual(calls, [[]], 'Only the paired host can identify the actual current capture screen.');
  });
}

test('query and apply preserve the canonical target returned for the current session', async () => {
  const calls = [];
  const active = options();
  const result = { success: true, currentScalePercent: null, effectiveImmediately: false };
  const session = makeSession({
    getDisplays: async () => { throw new Error('DPI must not enumerate displays'); },
    getDisplayScaleOptions: async (...args) => {
      calls.push(['query', ...args]);
      return active;
    },
    setDisplayScale: async (...args) => {
      calls.push(['apply', ...args]);
      return result;
    }
  }, '{obsolete-launch-device}');
  const queried = await session.getDisplayScaleOptions();
  assert.strictEqual(queried, active);
  assert.strictEqual(await session.setDisplayScale(150, queried), result);
  assert.deepEqual(calls, [['query'], ['apply', 150, active]]);
  assert.strictEqual(calls[1][2], active, 'Do not replace the queried capture identity with the launch identity.');
  assert.equal(queried.currentScalePercent, null);
});

test('a new query follows capture changes instead of caching the initial target', async () => {
  const first = options('{capture-before-switch}');
  const second = options('{capture-after-switch}');
  const replies = [first, second];
  const session = makeSession({
    getDisplayScaleOptions: async (...args) => {
      assert.deepEqual(args, []);
      return replies.shift();
    }
  }, '{initial-launch-screen}');
  assert.strictEqual(await session.getDisplayScaleOptions(), first);
  assert.strictEqual(await session.getDisplayScaleOptions(), second);
  assert.equal(replies.length, 0);
});

test('no-active-stream and display-change conflicts propagate without an unscoped retry', async () => {
  for (const errorCode of ['no_active_stream', 'display_target_changed']) {
    const failure = Object.assign(new Error(errorCode), { statusCode: 409, errorCode });
    let requests = 0;
    const session = makeSession({
      getDisplayScaleOptions: async () => { requests++; throw failure; },
      setDisplayScale: async () => { requests++; throw failure; },
      getDisplays: async () => { throw new Error('No fallback screen enumeration'); }
    });
    await assert.rejects(session.getDisplayScaleOptions(), error => error === failure);
    await assert.rejects(session.setDisplayScale(150, options()), error => error === failure);
    assert.equal(requests, 2);
  }
});

test('an unavailable target never falls back to a host primary display', async () => {
  const failure = Object.assign(new Error('Display not found'), { statusCode: 404, errorCode: 'display_not_found' });
  const session = makeSession({
    getDisplayScaleOptions: async () => { throw failure; },
    getDisplays: async () => { throw new Error('DPI must not enumerate displays'); }
  }, '{old-launch-device}');
  await assert.rejects(session.getDisplayScaleOptions(), error => error === failure);
});
