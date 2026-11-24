const assert = require('node:assert/strict');
const { test } = require('node:test');
const { loadArkTsModule } = require('./test-helpers/load-arkts.cjs');

function deferred() {
  let resolve;
  const promise = new Promise(r => { resolve = r; });
  return { promise, resolve };
}

function fixture(options = {}) {
  const sessions = [];
  const pending = deferred();
  class FakeSession {
    constructor() { this.stops = 0; this.quits = 0; sessions.push(this); }
    setDs5TouchpadEnabled() {}
    setHdrStateCallback() {}
    setCodecStateCallback() {}
    setConnectionTerminatedCallback() {}
    setResolutionChangedCallback() {}
    setConnectionStatusCallback() {}
    setStageProgressCallback() {}
    setDecoderStartedCallback() {}
    getEffectiveConfig() { return null; }
    getActiveUpscaleMode() { return 0; }
    async start() {
      if (options.failFirstStart && sessions[0] === this) throw new Error('connection failed');
      await pending.promise;
    }
    async stop() { this.stops++; await pending.promise; }
    async quitApp() { this.quits++; await pending.promise; return true; }
  }
  const { StreamViewModel } = loadArkTsModule('entry/src/main/ets/viewmodel/StreamViewModel.ets', {
    Observed: value => value,
    getDefaultOverlayConfig: () => ({}),
    SettingsService: { getInstance: () => ({}) },
    StreamingSession: FakeSession,
    AppStorage: { setOrCreate() {} },
    Logger: { info() {}, warn() {}, error() {} },
    PreferencesUtil: { get: async () => false },
    SettingsKeys: {},
    GamepadManager: { getInstance: () => ({ setGameVibration(...args) { options.vibrations?.push(args); } }) }
  }, ['StreamViewModel']);
  const vm = new StreamViewModel();
  vm.streamConfig = { width: 1920, height: 1080, fps: 60 };
  return { vm, sessions, pending };
}

test('dispose while loading settings prevents session creation', async () => {
  const { vm, sessions } = fixture();
  const settings = deferred();
  vm.loadSettings = () => settings.promise;
  const start = vm.startStreaming('host', 1, 'surface', {});
  vm.dispose();
  settings.resolve();
  await start;
  assert.equal(sessions.length, 0);
});

test('the view model waits for session shutdown while startup is in flight', async () => {
  const { vm, sessions, pending } = fixture();
  vm.loadSettings = async () => true;
  const start = vm.startStreaming('host', 1, 'surface', {});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(sessions.length, 1);
  let stopped = false;
  const stop = vm.stopStreaming().then(() => { stopped = true; });
  await Promise.resolve();
  assert.equal(stopped, false);
  assert.equal(sessions[0].stops, 1);
  pending.resolve();
  await Promise.all([start, stop]);
  assert.equal(sessions[0].stops, 1);
  assert.equal(vm.getSession(), null);
  assert.equal(vm.connectionState, 'disconnected');
});

function settingsForTest(vm, firstConfig) {
  let calls = 0;
  vm.parseOverlayPosition = () => 'top-left';
  vm.settingsService = {
    getStreamConfig: async () => {
      if (calls++ === 0) return await firstConfig.promise;
      return { width: 2560, height: 1440, fps: 60, enableVibration: true };
    },
    getInputSettings: async () => ({ touchscreenTrackpad: true, enableOnscreenControls: false }),
    getDisplaySettings: async () => ({ perfOverlayPosition: '左上' })
  };
}

test('outdated settings load cannot overwrite a newer snapshot or vibration settings', async () => {
  const vibrations = [];
  const { vm } = fixture({ vibrations });
  const old = deferred();
  settingsForTest(vm, old);
  const first = vm.loadSettings();
  assert.equal(await vm.loadSettings(), true);
  old.resolve({ width: 1280, height: 720, fps: 30, enableVibration: false });
  assert.equal(await first, false);
  assert.equal(vm.streamConfig.width, 2560);
  assert.equal(vm.displayInfo.streamWidth, 2560);
  assert.equal(vibrations.length, 1);
  assert.equal(vibrations[0][0], true);
});

test('disposing during settings load prevents committing state or vibration', async () => {
  const vibrations = [];
  const { vm } = fixture({ vibrations });
  const old = deferred();
  settingsForTest(vm, old);
  const load = vm.loadSettings();
  vm.dispose();
  old.resolve({ width: 1280, height: 720, fps: 30, enableVibration: true });
  assert.equal(await load, false);
  assert.equal(vm.streamConfig.width, 1920);
  assert.equal(vibrations.length, 0);
});

test('startup stops when another settings load supersedes it', async () => {
  const { vm, sessions } = fixture();
  const old = deferred();
  settingsForTest(vm, old);
  const start = vm.startStreaming('host', 1, 'surface', {});
  assert.equal(await vm.loadSettings(), true);
  old.resolve({ width: 1280, height: 720, fps: 30 });
  await start;
  assert.equal(sessions.length, 0);
  assert.equal(vm.streamConfig.width, 2560);
  assert.equal(vm.connectionState, 'disconnected');
});

test('the same view model can start a fresh session after stopping', async () => {
  const { vm, sessions, pending } = fixture();
  vm.loadSettings = async () => true;
  pending.resolve();
  await vm.startStreaming('host', 1, 'surface', {});
  await vm.stopStreaming();
  await vm.startStreaming('host', 1, 'surface', {});
  assert.equal(sessions.length, 2);
  assert.equal(sessions[0].stops, 1);
  assert.equal(vm.getSession(), sessions[1]);
  assert.equal(vm.connectionState, 'connecting');
  await vm.stopStreaming();
});

test('late stop completion does not overwrite a newer connection state', async () => {
  const { vm, sessions, pending } = fixture();
  vm.loadSettings = async () => true;
  const firstStart = vm.startStreaming('host', 1, 'surface', {});
  await new Promise(resolve => setImmediate(resolve));
  const stop = vm.stopStreaming();
  const nextStart = vm.startStreaming('host', 1, 'surface', {});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(sessions.length, 2);
  pending.resolve();
  await Promise.all([firstStart, stop, nextStart]);
  assert.equal(vm.getSession(), sessions[1]);
  assert.equal(vm.connectionState, 'connecting');
  await vm.stopStreaming();
});

test('late quit completion does not overwrite a newer connection state', async () => {
  const { vm, sessions, pending } = fixture();
  vm.loadSettings = async () => true;
  const firstStart = vm.startStreaming('host', 1, 'surface', {});
  await new Promise(resolve => setImmediate(resolve));
  const quit = vm.quitGame();
  const nextStart = vm.startStreaming('host', 1, 'surface', {});
  await new Promise(resolve => setImmediate(resolve));
  pending.resolve();
  await Promise.all([firstStart, quit, nextStart]);
  assert.equal(vm.getSession(), sessions[1]);
  assert.equal(vm.connectionState, 'connecting');
  await vm.stopStreaming();
});

test('disposing during a pending quit does not replace it with stop', async () => {
  const { vm, sessions, pending } = fixture();
  vm.loadSettings = async () => true;
  const start = vm.startStreaming('host', 1, 'surface', {});
  await new Promise(resolve => setImmediate(resolve));
  const quit = vm.quitGame();
  vm.dispose();
  assert.equal(sessions[0].quits, 1);
  assert.equal(sessions[0].stops, 0);
  pending.resolve();
  await Promise.all([start, quit]);
  assert.equal(vm.getSession(), null);
});

test('the same view model can retry after startup fails', async () => {
  const { vm, sessions, pending } = fixture({ failFirstStart: true });
  vm.loadSettings = async () => true;
  await assert.rejects(vm.startStreaming('host', 1, 'surface', {}), /connection failed/);
  assert.equal(vm.connectionState, 'error');
  pending.resolve();
  await vm.startStreaming('host', 1, 'surface', {});
  assert.equal(sessions.length, 2);
  assert.equal(vm.getSession(), sessions[1]);
  assert.equal(vm.connectionState, 'connecting');
  await vm.stopStreaming();
});

function sessionFixture() {
  const calls = [];
  const noop = () => {};
  const { StreamingSession } = loadArkTsModule('entry/src/main/ets/service/streaming/StreamingSession.ets', {
    nativeLib: {},
    MoonlightButton: {},
    AudioVibrationService: class { stop() {} },
    GamepadManager: { getInstance: () => ({ setControllerTouchCallback: noop, stopAllSensors: noop }) },
    Logger: { info: noop, warn: noop, error: noop },
    sampleDisplayBrightness: async () => null,
    ComputerManager: { getInstance: () => ({ invalidateServerInfoCache: () => calls.push('invalidate') }) },
    ConnectionPathService: { inspect: async () => ({ path: 'LAN' }) },
    SettingsService: { getInstance: () => ({ applyRemoteStreamSettings: async () => false }) }
  }, ['StreamingSession']);
  function makeSession() {
    const session = new StreamingSession();
    session.registerBrightnessProbe = noop;
    session.resetControllerState = noop;
    session.stopNetworkBoost = noop;
    session.cleanup = async () => { calls.push('cleanup'); };
    session.resolveComputer = async () => { calls.push('resolve'); };
    session.applyInitialBitratePolicy = async () => {};
    session.generateInputKey = noop;
    session.fetchServerInfo = async () => {};
    session.initializeNative = async () => {};
    session.applyPreConnectionSettings = noop;
    session.setupVideoSurface = async () => {};
    session.getCachedCurrentGame = () => 0;
    session.launchApp = async () => {};
    session.connectToServer = async () => {};
    return session;
  }
  return { makeSession, calls, StreamingSession };
}

test('new session waits for canceled old startup and cleanup', async () => {
  const { makeSession, calls } = sessionFixture();
  const old = makeSession();
  const next = makeSession();
  const gate = deferred();
  const entered = deferred();
  old.resolveComputer = async () => { calls.push('old-resolve'); entered.resolve(); await gate.promise; };
  const nextGate = deferred();
  const nextEntered = deferred();
  next.resolveComputer = async () => { calls.push('next-resolve'); nextEntered.resolve(); await nextGate.promise; };
  const config = { width: 1920, height: 1080, fps: 60, bitrate: 20000, codec: 'HEVC' };
  const oldStart = old.start('old', 1, config, 'surface');
  await entered.promise;
  const stop = old.stop();
  const nextStart = next.start('next', 1, config, 'surface');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls.includes('next-resolve'), false);
  gate.resolve();
  await Promise.all([oldStart, stop]);
  await nextEntered.promise;
  assert.equal(calls.filter(call => call === 'cleanup').length, 2);
  assert.equal(calls.includes('next-resolve'), true);
  await old.stop();
  assert.equal(await old.quitApp(), false);
  assert.equal(calls.filter(call => call === 'cleanup').length, 2);
  const nextStop = next.stop();
  nextGate.resolve();
  await Promise.all([nextStop, nextStart]);
});

test('new page retires the old session even before the old page stops', async () => {
  const { makeSession, calls, StreamingSession } = sessionFixture();
  const old = makeSession();
  const next = makeSession();
  const oldGate = deferred();
  const oldEntered = deferred();
  const nextGate = deferred();
  const nextEntered = deferred();
  old.resolveComputer = async () => { calls.push('old-resolve'); oldEntered.resolve(); await oldGate.promise; };
  next.resolveComputer = async () => { calls.push('next-resolve'); nextEntered.resolve(); await nextGate.promise; };
  const config = { width: 1920, height: 1080, fps: 60, bitrate: 20000, codec: 'HEVC' };
  const oldStart = old.start('old', 1, config, 'surface');
  await oldEntered.promise;
  const nextStart = next.start('next', 1, config, 'surface');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls.includes('next-resolve'), false);
  oldGate.resolve();
  await oldStart;
  await nextEntered.promise;
  const cleanups = calls.filter(call => call === 'cleanup').length;
  assert.equal(cleanups, 2);
  await old.stop();
  assert.equal(calls.filter(call => call === 'cleanup').length, cleanups);
  assert.equal(StreamingSession.resourceOwner, next);
  const nextStop = next.stop();
  nextGate.resolve();
  await Promise.all([nextStart, nextStop]);
  assert.equal(StreamingSession.resourceOwner, null);
});

test('quitting during host launch waits for launch to finish before sending quit', async () => {
  const { makeSession, calls } = sessionFixture();
  const session = makeSession();
  const gate = deferred();
  const entered = deferred();
  session.resolveComputer = async () => {
    session.nvHttp = { quitApp: async () => { calls.push('quit'); return true; } };
  };
  session.launchApp = async () => { calls.push('launch'); entered.resolve(); await gate.promise; calls.push('launch-finished'); };
  session.connectToServer = async () => { calls.push('connect'); };
  const config = { width: 1920, height: 1080, fps: 60, bitrate: 20000, codec: 'HEVC' };
  const start = session.start('host', 1, config, 'surface');
  await entered.promise;
  const quit = session.quitApp();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls.includes('quit'), false);
  gate.resolve();
  assert.equal(await quit, true);
  await start;
  assert.ok(calls.indexOf('launch-finished') < calls.indexOf('quit'));
  assert.ok(calls.indexOf('invalidate') > calls.indexOf('launch-finished'));
  assert.ok(calls.lastIndexOf('invalidate') > calls.indexOf('quit'));
  assert.equal(calls.includes('connect'), false);
});

test('failed remote launch invalidates cached host state before retry', async () => {
  const { makeSession, calls } = sessionFixture();
  const session = makeSession();
  session.launchApp = async () => { throw new Error('launch failed'); };
  const config = { width: 1920, height: 1080, fps: 60, bitrate: 20000, codec: 'HEVC' };
  await assert.rejects(session.start('host', 1, config, 'surface'), /launch failed/);
  assert.ok(calls.indexOf('invalidate') >= 0);
  assert.ok(calls.indexOf('invalidate') < calls.indexOf('cleanup'));
});

test('late stop from an old page cannot stop the new page background service', async () => {
  const calls = [];
  const noop = () => {};
  const service = {
    async start(context) { calls.push('start-' + context.name); },
    async stop() { calls.push('stop'); }
  };
  const { StreamLifecycleManager } = loadArkTsModule(
    'entry/src/main/ets/service/streaming/StreamLifecycleManager.ets', {
      AppStateService: { getInstance: () => ({}) },
      BackgroundStreamService: { getInstance: () => service },
      Logger: { info: noop, warn: noop, error: noop }
    }, ['StreamLifecycleManager']);
  const old = new StreamLifecycleManager();
  const next = new StreamLifecycleManager();
  await old.startBackgroundTask({ name: 'old' });
  await next.startBackgroundTask({ name: 'new' });
  await old.stopBackgroundTask();
  assert.deepEqual(calls, ['start-old', 'stop', 'start-new']);
  await next.stopBackgroundTask();
  assert.deepEqual(calls, ['start-old', 'stop', 'start-new', 'stop']);
});

test('canceled in-flight background start finishes cleanup before next page starts', async () => {
  const calls = [];
  const gate = deferred();
  const entered = deferred();
  const noop = () => {};
  const service = {
    async start(context) {
      calls.push('start-' + context.name);
      if (context.name === 'old') { entered.resolve(); await gate.promise; }
    },
    async stop() { calls.push('stop'); }
  };
  const { StreamLifecycleManager } = loadArkTsModule(
    'entry/src/main/ets/service/streaming/StreamLifecycleManager.ets', {
      AppStateService: { getInstance: () => ({}) },
      BackgroundStreamService: { getInstance: () => service },
      Logger: { info: noop, warn: noop, error: noop }
    }, ['StreamLifecycleManager']);
  const old = new StreamLifecycleManager();
  const next = new StreamLifecycleManager();
  const start = old.startBackgroundTask({ name: 'old' });
  await entered.promise;
  const stop = old.stopBackgroundTask();
  const nextStart = next.startBackgroundTask({ name: 'new' });
  gate.resolve();
  await Promise.all([start, stop, nextStart]);
  assert.deepEqual(calls, ['start-old', 'stop', 'start-new']);
  await next.stopBackgroundTask();
});

test('failed server lookup waits for parallel native initialization before cleanup', async () => {
  const { makeSession, calls } = sessionFixture();
  const session = makeSession();
  const gate = deferred();
  const entered = deferred();
  session.fetchServerInfo = async () => { throw new Error('server unavailable'); };
  session.initializeNative = async () => { entered.resolve(); await gate.promise; calls.push('native-ready'); };
  const config = { width: 1920, height: 1080, fps: 60, bitrate: 20000, codec: 'HEVC' };
  const start = session.start('host', 1, config, 'surface');
  const checked = assert.rejects(start, /server unavailable/);
  await entered.promise;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls.includes('cleanup'), false);
  gate.resolve();
  await checked;
  assert.ok(calls.indexOf('native-ready') < calls.indexOf('cleanup'));
});
