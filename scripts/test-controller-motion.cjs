// Adapter tests execute production ETS. Native queue/stop behavior is tested in common-c.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..');
const input = path.join(root, 'entry/src/main/ets/service/input');
const managerText = fs.readFileSync(path.join(input, 'GamepadManager.ets'), 'utf8');
const managerTree = ts.createSourceFile('GamepadManager.ts', managerText, ts.ScriptTarget.ES2020, true);
const managerClass = managerTree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'GamepadManager');
const names = ['setMotionSink', 'handleSetMotionEventState', 'reportControllerMotion',
  'reportControllerMotionFrame', 'stopAllSensors'];
const methods = names.map(name => {
  const method = managerClass.members.find(node => node.name && node.name.getText(managerTree) === name);
  assert.ok(method, `Missing production method: ${name}`);
  return method.getText(managerTree);
}).join('\n');
function compile(source) {
  return ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
  }}).outputText;
}
function fixture() {
  const listeners = new Map(), modules = {}, remote = [], local = [];
  const sensor = { SensorId: { GYROSCOPE: 1, ACCELEROMETER: 2 }, once() {},
    on(id, callback) { listeners.set(id, callback); }, off(id) { listeners.delete(id); } };
  const Logger = { info() {}, warn() {}, error() {} };
  function load(name) {
    if (modules[name]) return modules[name];
    const module = { exports: {} };
    vm.runInNewContext(compile(fs.readFileSync(path.join(input, `${name}.ets`), 'utf8')), {
      exports: module.exports, module, require(id) {
        if (id === '@kit.SensorServiceKit') return { sensor };
        if (id === '@kit.ArkUI') return { display: { getDefaultDisplaySync: () => ({ rotation: 0 }) } };
        if (id === '../../common/Logger') return { Logger };
        if (id === './DeviceSensorService') return load('DeviceSensorService');
        throw Error(`Unexpected dependency: ${id}`);
      }
    });
    return modules[name] = module.exports;
  }
  const device = load('DeviceSensorService').DeviceSensorService.getInstance();
  const GyroAssistService = load('GyroAssistService').GyroAssistService;
  const assist = GyroAssistService.getInstance();
  assist.setSendCallback((...args) => local.push(args));
  const context = { device, Logger, GyroAssistService,
    LI_MOTION_TYPE_ACCEL: 1, LI_MOTION_TYPE_GYRO: 2, ControllerCapabilities: { ACCEL: 16, GYRO: 32 } };
  vm.runInNewContext(compile(`class Manager {
    motionSink=null; deviceSensorService=device; usingDeviceSensorFallback=false;
    gamepadMotionSensorsEnabled=true; sensorFallbackEnabled=true; physicalCapabilities=0;
    requestedPhysicalMotion=new Set<string>(); usbControllerIdToSlot=new Map<number,number>([[7,0]]);
    getPhysicalSensorCapabilities(c:number):number{return this.physicalCapabilities;}
    ${methods}
  }; globalThis.manager=new Manager();`), context);
  let result = 0;
  const sink = {};
  for (const method of ['sendControllerMotionEvent', 'sendControllerMotionFrame',
    'stopControllerMotionEvent', 'resetControllerMotionEvents']) {
    sink[method] = (...args) => { remote.push([method, ...args]); return result; };
  }
  context.manager.setMotionSink(sink);
  return { device, assist, manager: context.manager, sink, remote, local, listeners,
    fail(value) { result = value; }, emit(x, y = 0, z = 0) { listeners.get(1)?.({ x, y, z }); } };
}
{
  const f = fixture();
  f.manager.handleSetMotionEventState(0, 2, 100);
  f.fail(-1); f.emit(.1); f.emit(0); f.fail(0); f.emit(0); f.emit(.1);
  assert.equal(f.remote.filter(row => row[0] === 'sendControllerMotionEvent').length, 4);
  const old = f.listeners.get(1);
  f.manager.handleSetMotionEventState(0, 2, 0);
  assert.equal(f.listeners.has(1), false);
  f.manager.handleSetMotionEventState(0, 2, 100);
  const before = f.remote.length;
  old({ x: 9, y: 0, z: 0 }); assert.equal(f.remote.length, before);
  f.emit(.1); assert.equal(f.remote.length, before + 1); // Same reading resumes without a stale cache.
}
for (const assistFirst of [false, true]) {
  const f = fixture();
  if (assistFirst) f.assist.setEnabled(true);
  f.manager.setMotionSink(f.sink); // Must not replace the local consumer.
  f.manager.handleSetMotionEventState(0, 2, 100);
  if (!assistFirst) f.assist.setEnabled(true);
  f.emit(.1); const localCount = f.local.length;
  assert.ok(localCount > 0 && f.local.at(-1)[5] !== 0);
  assert.equal(f.remote.filter(row => row[0] === 'sendControllerMotionEvent').length, 0);
  f.manager.handleSetMotionEventState(0, 2, 0);
  assert.equal(f.device.isGyroActive(), true);
  f.emit(.1); assert.equal(f.local.length, localCount + 1);
  f.manager.handleSetMotionEventState(0, 2, 100);
  f.assist.setEnabled(false);
  assert.equal(f.device.isGyroActive(), true); // Remote demand survives local disable.
  assert.equal(f.local.at(-1)[4], 0); assert.equal(f.local.at(-1)[5], 0);
  f.emit(.1);
  assert.equal(f.remote.at(-1)[0], 'sendControllerMotionEvent');
}
{
  const f = fixture(); f.manager.physicalCapabilities = 48;
  f.manager.handleSetMotionEventState(0, 2, 100);
  f.manager.handleSetMotionEventState(0, 1, 100);
  f.manager.reportControllerMotionFrame(7, 1, 2, 3, 4, 5, 6);
  assert.deepEqual(f.remote.at(-1), ['sendControllerMotionFrame', 0, 1, 2, 3, 4, 5, 6]);
  f.assist.setEnabled(true);
  f.manager.reportControllerMotionFrame(7, 1, 2, 3, 4, 5, 6);
  assert.deepEqual(f.remote.at(-1), ['sendControllerMotionEvent', 0, 1, 4, 5, 6]);
  const old = f.listeners.get(1);
  f.manager.stopAllSensors(); const before = f.remote.length, localBefore = f.local.length;
  old({ x: 9, y: 0, z: 0 });
  assert.equal(f.remote.length, before); assert.equal(f.local.length, localBefore);
  assert.equal(f.assist.enabled, false);
}
// Execute the real host request callback with a startup window, termination and stale generation.
{
  const text = fs.readFileSync(path.join(root, 'entry/src/main/ets/service/streaming/StreamingSession.ets'), 'utf8');
  const tree = ts.createSourceFile('StreamingSession.ts', text, ts.ScriptTarget.ES2020, true);
  const callbacks = {};
  function visit(node) {
    if (ts.isPropertyAssignment(node) && ['setMotionEventState', 'connectionStarted', 'connectionTerminated'].includes(node.name.getText(tree))) {
      callbacks[node.name.getText(tree)] = node.initializer.getText(tree);
    }
    ts.forEachChild(node, visit);
  }
  visit(tree); assert.ok(callbacks.setMotionEventState);
  const requests = [], session = { motionCallbacksActive: true, isRunning: false, isStartingConnection: true };
  const generation = { callbackGeneration: 1 };
  const context = { session, StreamingSession: generation, Logger: { info() {} },
    GamepadManager: { getInstance: () => ({ handleSetMotionEventState: (...args) => requests.push(args) }) } };
  vm.runInNewContext(compile(`function register(){ const generation=1; return ${callbacks.setMotionEventState}; }
    globalThis.callback=register.call(session);`), context);
  context.callback(0, 2, 100); assert.equal(requests.length, 1);
  session.motionCallbacksActive = false; context.callback(0, 2, 0); assert.equal(requests.length, 1);
  session.motionCallbacksActive = true; generation.callbackGeneration = 2;
  context.callback(0, 2, 0); assert.equal(requests.length, 1);
  for (const name of ['connectionStarted', 'connectionTerminated']) {
    vm.runInNewContext(compile(`function register(){ const generation=1; return ${callbacks[name]}; }
      globalThis.stale=register.call(session);`), context);
    assert.doesNotThrow(() => context.stale(0));
    assert.equal(session.motionCallbacksActive, true);
    assert.equal(session.isRunning, false);
  }
}
console.log('Motion adapters: repeated samples, resume, local/host demand, frames and stale callbacks passed.');
