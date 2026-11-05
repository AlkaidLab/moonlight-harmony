const assert = require('node:assert/strict');
const { test } = require('node:test');
const { loadArkTsModule } = require('./test-helpers/load-arkts.cjs');

const { RawMouseMotion } = loadArkTsModule('entry/src/main/ets/utils/RawMouseMotion.ets', {}, ['RawMouseMotion']);

test('API 24 and 26 produce the same hardware counts at each display scale', () => {
  for (const scale of [1, 1.25, 1.5, 2, 2.75, 3.5]) {
    for (const count of [-40, -7, -1, 0, 1, 7, 40]) {
      const old = new RawMouseMotion().consume(count / scale, -count / scale, 24, scale);
      const current = new RawMouseMotion().consume(count, -count, 26, scale);
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
  assert.equal(next.x, 0);
  assert.equal(next.y, -0);
});

test('nonfinite events cannot poison later mouse movement', () => {
  const motion = new RawMouseMotion();
  motion.consume(NaN, Infinity, 26, 1);
  const next = motion.consume(3, -3, 26, NaN);
  assert.equal(next.x, 3);
  assert.equal(next.y, -3);
});

function fixture(apiVersion = 26, capability = true) {
  const calls = [];
  const listeners = new Set();
  let state = 'foreground';
  let failEnter = -1;
  let failLeave = -1;
  let failureCode = 500;
  const { NetworkBoostService } = loadArkTsModule(
    'entry/src/main/ets/service/network/NetworkBoostService.ets', {
      deviceInfo: { sdkApiVersion: apiVersion },
      canIUse: () => capability,
      Logger: { info() {}, warn() {} },
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
        setSceneDesc: scene => calls.push({ scene: scene.sceneEvent }),
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
    enter: () => calls.filter(call => call.event === 0).map(call => call.fd),
    leave: () => calls.filter(call => call.event === 2).map(call => call.fd),
    state(next) { state = next; for (const listener of listeners) listener(next); },
    failEnter(fd, code = 500) { failEnter = fd; failureCode = code; },
    failLeave(fd) { failLeave = fd; }
  };
}

function flows(control = 30, video = 10, audio = 20) {
  return { control: { fd: control }, videoRtp: { fd: video }, audioRtp: { fd: audio } };
}

test('at most two flows, prioritizing control and video', () => {
  const f = fixture();
  f.service.registerStreamingFlows(flows());
  assert.deepEqual(f.enter(), [30, 10]);
  f.service.stop();
  assert.deepEqual(f.leave(), [30, 10]);
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

test('re-registration releases old descriptors before taking new slots', () => {
  const f = fixture();
  f.service.registerStreamingFlows(flows());
  f.calls.length = 0;
  f.service.registerStreamingFlows(flows(31, 11, 21));
  assert.deepEqual(f.calls.filter(call => call.fd !== undefined), [
    { fd: 30, event: 2 }, { fd: 10, event: 2 },
    { fd: 31, event: 0 }, { fd: 11, event: 0 }
  ]);
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

test('unsupported optional flow API keeps QoE reporting enabled', () => {
  const f = fixture();
  f.failEnter(30, 801);
  f.service.registerStreamingFlows(flows());
  assert.deepEqual(f.enter(), [30]);
  f.service.reportConnectionStatus(true);
  assert.equal(f.calls.at(-1).qoe.qoeType, 'highLatency');
  f.service.stop();
});

test('failed release is retried before any new flow is registered', () => {
  const f = fixture();
  f.service.registerStreamingFlows(flows());
  f.failLeave(30);
  f.service.registerStreamingFlows(flows(31, 11, 21));
  assert.deepEqual(f.enter(), [30, 10]);
  f.failLeave(-1);
  f.service.registerStreamingFlows(flows(31, 11, 21));
  assert.deepEqual(f.enter(), [30, 10, 31, 11]);
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
