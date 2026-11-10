const assert = require('node:assert/strict');
const { test } = require('node:test');
const { loadArkTsModule } = require('./test-helpers/load-arkts.cjs');

const { RawMouseMotion } = loadArkTsModule('entry/src/main/ets/utils/RawMouseMotion.ets', {}, ['RawMouseMotion']);

test('API 24 and 26 produce the same hardware counts at each display scale', () => {
  for (const scale of [1, 1.25, 1.5, 2, 2.75, 3.5]) {
    for (const count of [-40, -7, -1, 0, 1, 7, 40]) {
      const old = new RawMouseMotion().consume(count / scale, -count / scale, 24, scale);
      const current = new RawMouseMotion().consume(count, -count, 26, scale);
      assert.equal(current.x, count);
      assert.equal(current.y, -count || 0);
      assert.ok(Math.abs(old.x - current.x) <= 1);
      assert.ok(Math.abs(old.y - current.y) <= 1);
    }
  }
});

test('fractional movement accumulates symmetrically, and resets between sessions', () => {
  const motion = new RawMouseMotion();
  let x = 0;
  let y = 0;
  for (let i = 0; i < 100; i++) {
    const step = motion.consume(0.25, -0.25, 26, 3);
    x += step.x;
    y += step.y;
  }
  assert.equal(x, 25);
  assert.equal(y, -25);
  motion.consume(0.75, -0.75, 26, 1);
  motion.reset();
  const next = motion.consume(0.25, -0.25, 26, 1);
  assert.ok(next.x === 0 && next.y === 0);
});

test('nonfinite events cannot poison later mouse movement', () => {
  const motion = new RawMouseMotion();
  motion.consume(NaN, Infinity, 26, 1);
  const next = motion.consume(3, -3, 26, NaN);
  assert.equal(next.x, 3);
  assert.equal(next.y, -3);
});

/** Load the production service with controllable platform failures and a deterministic timer queue. */
function fixture(apiVersion = 26, capability = true, duplicateDescriptors = false) {
  const calls = [];
  const listeners = new Set();
  let state = 'foreground';
  let failEnter = -1;
  let failLeave = -1;
  let failureCode = 500;
  let failSceneEvent = -1;
  let sceneFailureCode = 500;
  let currentFlows = null;
  let failedRetain = -1;
  const retained = [];
  const released = [];
  const timers = new Map();
  let nextTimer = 0;
  const { NetworkBoostService } = loadArkTsModule(
    'entry/src/main/ets/service/network/NetworkBoostService.ets', {
      deviceInfo: { sdkApiVersion: apiVersion },
      canIUse: () => capability,
      Logger: { info() {}, warn() {} },
      MoonBridge: {
        getStreamSocketFds: () => currentFlows,
        retainStreamSocket: fd => {
          retained.push(fd);
          return fd === failedRetain ? -1 : duplicateDescriptors ? fd + 1000 : fd;
        },
        releaseStreamSocket: fd => released.push(fd)
      },
      setTimeout: callback => { const id = ++nextTimer; timers.set(id, callback); return id; },
      clearTimeout: id => timers.delete(id),
      AppState: { FOREGROUND: 'foreground' },
      AppStateService: { getInstance: () => ({
        getCurrentState: () => state,
        addListener: listener => listeners.add(listener),
        removeListener: listener => listeners.delete(listener)
      }) },
      netQuality: {
        on() {}, off() {}, reportQoe: qoe => calls.push({ qoe })
      },
      netBoost: {
        SceneEvent: { SCENE_EVENT_ENTER: 0, SCENE_EVENT_LEAVE: 2 },
        PriorityLevel: { PRIO_HIGH: 1 },
        setSceneDesc: scene => {
          calls.push({ scene: scene.sceneEvent });
          if (scene.sceneEvent === failSceneEvent) {
            throw Object.assign(new Error('scene failed'), { code: sceneFailureCode });
          }
        },
        setDataFlowDesc: desc => {
          calls.push({ fd: desc.dataFlowInfo, event: desc.sceneEvent });
          if ((desc.sceneEvent === 0 && desc.dataFlowInfo === failEnter) ||
              (desc.sceneEvent === 2 && desc.dataFlowInfo === failLeave)) {
            throw Object.assign(new Error('unsupported or failed'), { code: failureCode });
          }
        }
      }
    }, ['NetworkBoostService']);
  const service = NetworkBoostService.getInstance();
  service.start();
  return {
    service, calls, listeners,
    retained, released,
    snapshot(value) { currentFlows = value; },
    failRetain(fd) { failedRetain = fd; },
    enter: () => calls.filter(call => call.event === 0).map(call => call.fd),
    leave: () => calls.filter(call => call.event === 2).map(call => call.fd),
    scenes: () => calls.filter(call => call.scene !== undefined).map(call => call.scene),
    tick() {
      const pending = [...timers.values()];
      timers.clear();
      for (const callback of pending) callback();
    },
    state(next) { state = next; for (const listener of listeners) listener(next); },
    failEnter(fd, code = 500) { failEnter = fd; failureCode = code; },
    failLeave(fd) { failLeave = fd; },
    failScene(event, code = 500) { failSceneEvent = event; sceneFailureCode = code; }
  };
}

/** Create socket metadata with overridable descriptors for reconnect and fallback scenarios. */
function flows(control = 30, video = 10, audio = 20) {
  return { control: { fd: control, localPort: 5000 + control },
    videoRtp: { fd: video, localPort: 5000 + video },
    audioRtp: { fd: audio, localPort: 5000 + audio } };
}

test('socket replacement releases retained flows before registering the new snapshot', () => {
  const f = fixture(26, true, true);
  f.service.registerStreamingFlows(flows());
  f.snapshot(flows(30, 11, 20));
  f.tick();
  assert.deepEqual(f.leave(), [1030, 1010]);
  assert.deepEqual(f.enter(), [1030, 1010, 1030, 1011]);
  assert.deepEqual(f.released, [1030, 1010]);
  f.service.stop();
  assert.deepEqual(f.released, [1030, 1010, 1030, 1011]);
});

test('unchanged sockets do not re-register and a foreground return reads the latest snapshot', () => {
  const f = fixture();
  f.service.registerStreamingFlows(flows());
  f.snapshot(flows());
  f.tick();
  assert.deepEqual(f.enter(), [30, 10]);
  assert.deepEqual(f.leave(), []);
  f.state('background');
  f.snapshot(flows(30, 11, 20));
  f.tick();
  assert.deepEqual(f.enter(), [30, 10]);
  f.state('foreground');
  assert.deepEqual(f.enter(), [30, 10, 30, 11]);
  f.service.stop();
});

test('audio replacement refreshes only when audio occupies a flow slot', () => {
  const activeVideo = fixture();
  activeVideo.service.registerStreamingFlows(flows());
  activeVideo.snapshot(flows(30, 10, 21));
  activeVideo.tick();
  assert.deepEqual(activeVideo.leave(), []);
  assert.deepEqual(activeVideo.enter(), [30, 10]);
  activeVideo.service.stop();

  const audioFallback = fixture();
  audioFallback.service.registerStreamingFlows(flows(30, -1, 20));
  audioFallback.snapshot(flows(30, -1, 21));
  audioFallback.tick();
  assert.deepEqual(audioFallback.leave(), [30, 20]);
  assert.deepEqual(audioFallback.enter(), [30, 20, 30, 21]);
  audioFallback.service.stop();
});

test('a reused descriptor with a new local port triggers a refresh', () => {
  const f = fixture();
  f.service.registerStreamingFlows(flows());
  const replacement = flows();
  replacement.videoRtp.localPort++;
  f.snapshot(replacement);
  f.tick();
  assert.deepEqual(f.leave(), [30, 10]);
  assert.deepEqual(f.enter(), [30, 10, 30, 10]);
  f.service.stop();
});

test('failed socket retention is retried within a fixed budget and does not outlive the session', () => {
  const f = fixture();
  f.failRetain(10);
  f.service.registerStreamingFlows(flows());
  f.snapshot(flows());
  for (let i = 0; i < 8; i++) f.tick();
  assert.equal(f.retained.filter(fd => fd === 10).length, 4);
  f.service.stop();
  const attempts = f.retained.length;
  f.tick();
  assert.equal(f.retained.length, attempts);
});

test('failed flow cleanup retains the old duplicate until it can be unregistered', () => {
  const f = fixture(26, true, true);
  f.service.registerStreamingFlows(flows());
  f.failLeave(1010);
  f.snapshot(flows(30, 11, 20));
  f.tick();
  assert.deepEqual(f.enter(), [1030, 1010]);
  assert.deepEqual(f.released, [1030]);
  f.failLeave(-1);
  f.tick();
  assert.deepEqual(f.enter(), [1030, 1010, 1030, 1011]);
  assert.deepEqual(f.released, [1030, 1010]);
  f.service.stop();
});

test('at most two flows, prioritizing control and video', () => {
  const f = fixture();
  f.service.registerStreamingFlows(flows());
  assert.deepEqual(new Set(f.enter()), new Set([30, 10]));
  f.service.stop();
  assert.deepEqual(new Set(f.leave()), new Set([30, 10]));
  assert.equal(f.listeners.size, 0);
});

test('background releases descriptors; foreground restores only the current connection', () => {
  const f = fixture();
  f.service.registerStreamingFlows(flows());
  f.state('background');
  assert.deepEqual(f.leave(), [30, 10]);
  f.service.registerStreamingFlows(flows(31, 11, 21));
  assert.deepEqual(f.enter(), [30, 10]);
  f.state('foreground');
  assert.deepEqual(f.enter(), [30, 10, 31, 11]);
  f.service.stop();
  f.state('foreground');
  assert.deepEqual(f.enter(), [30, 10, 31, 11]);
});

test('stop retries failed flow or scene cleanup and stops after success', () => {
  for (const [fail, target] of [['failLeave', 30], ['failScene', 2]]) {
    const f = fixture();
    f.service.registerStreamingFlows(flows());
    f[fail](target);
    f.service.stop();
    assert.equal(f.listeners.size, 0);
    const attempts = f.calls.length;
    f[fail](-1);
    f.tick();
    assert.ok(f.calls.length > attempts, fail + ' must be retried');
    assert.equal(f.scenes().at(-1), 2);
    const finished = f.calls.length;
    f.tick();
    assert.equal(f.calls.length, finished, 'successful cleanup must stop retrying');
  }
});

test('permanent cleanup failure releases retained sockets after bounded retries', () => {
  const f = fixture(26, true, true);
  f.service.registerStreamingFlows(flows());
  f.failLeave(1030);
  f.service.stop();
  for (let i = 0; i < 10; i++) f.tick();
  const attempts = f.leave().filter(fd => fd === 1030).length;
  assert.ok(attempts > 1 && attempts <= 4, 'cleanup must retry within its budget');
  f.tick();
  assert.equal(f.leave().filter(fd => fd === 1030).length, attempts);
  assert.deepEqual(new Set(f.released), new Set([1030, 1010]));
  f.service.start();
  f.failLeave(-1);
  f.service.registerStreamingFlows(flows(31, 11, 21));
  assert.deepEqual(f.enter(), [1030, 1010, 1031, 1011]);
  f.service.stop();
});

test('starting a new session cancels old cleanup timers before registering new flows', () => {
  const f = fixture();
  f.service.registerStreamingFlows(flows());
  f.failLeave(30);
  f.service.stop();
  f.failLeave(-1);
  f.service.start();
  f.service.registerStreamingFlows(flows(31, 11, 21));
  const released = f.leave().length;
  f.tick();
  assert.equal(f.leave().length, released, 'old cleanup must not release new session flows');
  assert.deepEqual(f.enter(), [30, 10, 31, 11]);
  f.service.stop();
});

test('failed flow or scene cleanup blocks replacement until it succeeds', () => {
  for (const [fail, target] of [['failLeave', 30], ['failScene', 2]]) {
    const f = fixture();
    f.service.registerStreamingFlows(flows());
    f[fail](target);
    f.service.registerStreamingFlows(flows(31, 11, 21));
    assert.deepEqual(f.enter(), [30, 10], 'failed cleanup must block replacement');
    if (fail === 'failLeave') assert.ok(!f.scenes().includes(2));
    f[fail](-1);
    f.service.registerStreamingFlows(flows(31, 11, 21));
    assert.deepEqual(f.enter(), [30, 10, 31, 11]);
    f.service.stop();
  }
});

test('re-registration releases old descriptors before taking new slots', () => {
  const f = fixture();
  f.service.registerStreamingFlows(flows());
  f.calls.length = 0;
  f.service.registerStreamingFlows(flows(31, 11, 21));
  assert.deepEqual(new Set(f.leave()), new Set([30, 10]));
  assert.deepEqual(new Set(f.enter()), new Set([31, 11]));
  assert.ok(f.calls.findLastIndex(call => call.event === 2) <
    f.calls.findIndex(call => call.event === 0), 'release old flows before registering replacements');
});

test('invalid or duplicate descriptors leave room for audio fallback', () => {
  for (const [control, video, expected] of [[-1, 10, [10, 20]], [10, 10, [10, 20]], [NaN, 10, [10, 20]]]) {
    const f = fixture();
    f.service.registerStreamingFlows(flows(control, video));
    assert.deepEqual(f.enter(), expected);
  }
});

test('one registration failure can use audio fallback without exceeding the quota', () => {
  const f = fixture();
  f.failEnter(30);
  f.service.registerStreamingFlows(flows());
  assert.deepEqual(f.enter(), [30, 10, 20]);
  f.service.stop();
  assert.deepEqual(f.leave(), [10, 20]);
});

test('unsupported optional flow or scene API keeps QoE reporting enabled', () => {
  for (const [fail, target] of [['failEnter', 30], ['failScene', 0]]) {
    const f = fixture();
    f[fail](target, 801);
    f.service.registerStreamingFlows(flows());
    f.service.reportConnectionStatus(true);
    assert.equal(f.calls.at(-1).qoe?.qoeType, 'highLatency');
    const attempts = f.enter().length + f.scenes().filter(event => event === 0).length;
    f.service.registerStreamingFlows(flows());
    assert.equal(f.enter().length + f.scenes().filter(event => event === 0).length, attempts,
      'unsupported setup must not be retried');
    f.service.stop();
  }
});

test('API 12/24 and unsupported devices never invoke API 26 flow descriptions', () => {
  for (const [version, capability] of [[12, true], [24, true], [26, false]]) {
    const f = fixture(version, capability);
    f.service.registerStreamingFlows(flows());
    f.state('background');
    f.state('foreground');
    f.service.stop();
    assert.deepEqual(f.enter(), []);
    assert.deepEqual(f.leave(), []);
    assert.equal(f.listeners.size, 0);
  }
});
