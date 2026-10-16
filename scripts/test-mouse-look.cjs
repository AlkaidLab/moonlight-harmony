// Run with Node and, optionally, the SDK's typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
let ts;
if (process.argv[2]) {
  ts = require(path.resolve(process.argv[2]));
} else {
  try {
    ts = require('typescript');
  } catch {
    const roots = [];
    if (process.env.DEVECO_SDK_HOME) roots.push(process.env.DEVECO_SDK_HOME);
    if (process.env.DEVECO_HOME) {
      roots.push(path.join(process.env.DEVECO_HOME, 'Contents', 'sdk'));
      roots.push(path.join(process.env.DEVECO_HOME, 'sdk'));
    }
    if (process.platform === 'win32') {
      roots.push('C:/Program Files/Huawei/DevEco Studio/sdk');
    } else if (process.platform === 'darwin') {
      roots.push('/Applications/DevEco-Studio.app/Contents/sdk');
    } else {
      roots.push('/opt/DevEco-Studio/sdk');
    }

    const candidates = [];
    for (const root of roots) {
      candidates.push(path.join(root, 'default', 'openharmony', 'ets', 'build-tools', 'ets-loader', 'node_modules', 'typescript', 'lib', 'typescript.js'));
      candidates.push(path.join(root, 'ets', 'build-tools', 'ets-loader', 'node_modules', 'typescript', 'lib', 'typescript.js'));
      candidates.push(path.join(root, 'openharmony', 'ets', 'build-tools', 'ets-loader', 'node_modules', 'typescript', 'lib', 'typescript.js'));
    }
    const tsPath = candidates.find((candidate) => fs.existsSync(candidate));
    if (!tsPath) {
      throw new Error('Cannot find TypeScript in the DevEco SDK; pass the SDK TypeScript path as the first argument');
    }
    ts = require(tsPath);
  }
}
const TouchType = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
const input = [];
const session = {
  sendKeyboardInput(vk, flags) { input.push(['key', vk, flags]); },
  sendVirtualControllerInput(...args) { input.push(['controller', ...args]); }
};
const bridge = {
  sendMouseMove(dx, dy) { input.push(['move', dx, dy]); },
  sendMouseButton(...args) { input.push(['button', ...args]); },
  sendMouseHighResScroll(...args) { input.push(['scroll', ...args]); }
};
function load(relative, extra = '') {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets', relative), 'utf8') + extra;
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, {
    exports, TouchType,
    setTimeout() { throw new Error('Pure mouse look must not schedule clicks or drags'); },
    require(name) {
      if (name.endsWith('MoonBridge')) return { MoonBridge: bridge, BUTTON_ACTION_PRESS: 7, BUTTON_ACTION_RELEASE: 8 };
      if (name.endsWith('CustomKeyTypes')) return types;
      if (name.endsWith('KeyMenuController')) return keyMenu;
      return {};
    }
  }, { filename: relative });
  return exports;
}
const types = load('service/customkey/CustomKeyTypes.ets');
const { MouseLookGestureHandler } = load('service/input/MouseLookGestureHandler.ets');
const keyMenu = load('service/customkey/KeyMenuController.ets');
const { CustomKeyManager } = load('service/customkey/CustomKeyManager.ets');
let connected = true;
const manager = new CustomKeyManager({ getSession: () => connected ? session : null });
const handler = new MouseLookGestureHandler();
const touch = (id, x, y = 0) => ({ id, windowX: x, windowY: y, x, y });
const emit = (type, touches, changedTouches = touches, sensitivity = 1, invertY = false) =>
  handler.handleEvent({ type, touches, changedTouches }, sensitivity, invertY, (dx, dy) => manager.handleMouseLookMovement(dx, dy));

// Tap, repeated taps, stationary hold and cancellation must never click or move.
for (let i = 0; i < 3; i++) {
  emit(TouchType.Down, [touch(1, 10)]);
  for (let j = 0; j < 50; j++) emit(TouchType.Move, [touch(1, 10)]);
  emit(TouchType.Up, [], [touch(1, 10)]);
}
manager.handleAction({ type: 'mouseLook' }, true);
manager.handleAction({ type: 'mouseLook' }, false);
assert.deepEqual(input, []);

// Other fingers can press keys while the tracked finger looks around.
emit(TouchType.Down, [touch(7, 100, 50)]);
manager.handleAction({ type: 'keyboard', vk: 0x57 }, true);
emit(TouchType.Down, [touch(7, 100, 50), touch(9, 900)], [touch(9, 900)]);
emit(TouchType.Move, [touch(9, 1500), touch(7, 104, 52)], [touch(9, 1500)], 2);
emit(TouchType.Up, [touch(7, 104, 52)], [touch(9, 1500)]);
emit(TouchType.Move, [touch(7, 106, 53)], undefined, 2);
manager.handleAction({ type: 'keyboard', vk: 0x57 }, false);
assert.deepEqual(input, [['key', 0x57, 3], ['move', 8, 4], ['move', 4, 2], ['key', 0x57, 4]]);
assert.equal(input.some(event => event[0] === 'button' || event[0] === 'scroll'), false);

// An intentional attack button is independent: view gestures add no button events.
input.length = 0;
manager.handleAction({ type: 'mouse', button: 1 }, true);
emit(TouchType.Move, [touch(7, 107, 53)]);
manager.handleAction({ type: 'mouse', button: 1 }, false);
assert.deepEqual(input, [['button', 7, 1], ['move', 1, 0], ['button', 8, 1]]);

// Both ArkUI Up conventions, second-finger retention, and fresh-down rebasing.
input.length = 0;
emit(TouchType.Up, [touch(7, 106, 53), touch(9, 2000)], [touch(7, 106, 53)]);
emit(TouchType.Move, [touch(9, 3000)]);
assert.deepEqual(input, []);
emit(TouchType.Down, [touch(10, 500)]);
emit(TouchType.Move, [touch(10, 501, 1)], undefined, 1, true);
assert.deepEqual(input, [['move', 1, -1]]);

// Tiny movements accumulate symmetrically instead of disappearing at each sample.
handler.reset(); input.length = 0;
emit(TouchType.Down, [touch(1, 0)]);
for (let x = 0.2; x <= 1.21; x += 0.2) emit(TouchType.Move, [touch(1, x)]);
assert.equal(input.reduce((sum, event) => sum + event[1], 0), 1);
handler.reset(); input.length = 0;
emit(TouchType.Down, [touch(1, 0)]);
for (let x = -0.2; x >= -1.21; x -= 0.2) emit(TouchType.Move, [touch(1, x)]);
assert.equal(input.reduce((sum, event) => sum + event[1], 0), -1);

// Cancel, lost pointer, and lifecycle reset require a new Down; no jumps on resume.
emit(TouchType.Cancel, [], [touch(1, -1.2)]); input.length = 0;
emit(TouchType.Move, [touch(1, 1000)]);
emit(TouchType.Down, [touch(2, 0)]);
emit(TouchType.Move, []);
emit(TouchType.Move, [touch(2, 1000)]);
emit(TouchType.Down, [touch(3, 0)]);
handler.reset();
emit(TouchType.Move, [touch(3, 1000)]);
assert.deepEqual(input, []);

// Global Cancel may retain touches without changedTouches. An unrelated finger's
// targeted Cancel must, however, leave the view finger active.
emit(TouchType.Down, [touch(5, 0)]);
emit(TouchType.Cancel, [touch(5, 0)], [touch(6, 1000)]);
emit(TouchType.Move, [touch(5, 1)]);
assert.deepEqual(input, [['move', 1, 0]]);
emit(TouchType.Cancel, [touch(5, 1)], []);
input.length = 0;
emit(TouchType.Move, [touch(5, 1000)]);
assert.deepEqual(input, []);

// Window coordinates keep movement continuous outside the original area.
emit(TouchType.Down, [touch(4, 0)]);
emit(TouchType.Move, [{ ...touch(4, 3), x: -9999 }], undefined, NaN);
assert.deepEqual(input, [['move', 4, 0]]);
connected = false;
emit(TouchType.Move, [touch(4, 20)]);
assert.equal(input.length, 1);
connected = true;

// Half-screen layout follows window/rotation dimensions without changing saved keys.
const original = types.createDefaultKeyDef({
  action: { type: 'mouseLook', region: 'rightHalf', sensitivity: 2.3, invertY: true },
  width: 60, height: 60, groupId: 'game-controls'
});
const right = types.resolveMouseLookLayout(original, 1000, 600);
assert.deepEqual([right.xPercent, right.yPercent, right.width, right.height], [0.75, 0.5, 500, 600]);
const rotated = types.resolveMouseLookLayout(original, 600, 1000);
assert.deepEqual([rotated.width, rotated.height], [300, 1000]);
assert.equal(original.width, 60);
const left = types.resolveMouseLookLayout({ ...original, action: { type: 'mouseLook', region: 'leftHalf' } }, 1000, 600);
assert.equal(left.xPercent, 0.25);
const free = types.resolveMouseLookLayout({ ...original, action: { ...original.action, region: 'custom' } }, 1000, 600);
assert.deepEqual([free.width, free.height], [60, 60]);
assert.deepEqual(JSON.parse(JSON.stringify(types.cloneKeyDef(original))).action, original.action);

// Exercise actual QR formats; the action must not degrade into a D-pad or click.
const qr = load('service/network/QrShareService.ets', '\nexport { encodeAction, decodeAction, toCompact, fromCompactV1, fromCompactV2, serializeV3, deserializeV3, QrShareService };');
const plain = value => JSON.parse(JSON.stringify(value));
assert.deepEqual(plain(qr.decodeAction(qr.encodeAction(original.action))), original.action);
for (const region of ['leftHalf', 'rightHalf', 'custom']) {
  for (const sensitivity of [0.1, 1.5, 5]) {
    const action = { type: 'mouseLook', region, sensitivity, invertY: false };
    assert.deepEqual(plain(qr.decodeAction(qr.encodeAction(action))), action);
  }
}
assert.deepEqual(plain(qr.fromCompactV2(qr.toCompact(original))).action, original.action);
const decodedV3 = qr.deserializeV3(qr.serializeV3('Look', [original]));
assert.equal(decodedV3[0], 'Look');
assert.deepEqual(plain(decodedV3[1][0]).action, original.action);
assert.equal(decodedV3[1][0].groupId, original.groupId);
assert.deepEqual(plain(qr.decodeAction('K87')), { type: 'keyboard', vk: 87 });

// Historical share payloads must remain importable after adding mouse-look.
// These fixtures represent the three formats emitted before this feature.
const oldV1 = JSON.stringify({
  v: 1,
  n: 'Legacy v1',
  k: [{ l: 'Jump', a: { type: 'keyboard', vk: 32 }, s: 'r', b: 'm', x: 0.25, y: 0.75, w: 48, h: 48 }]
});
const oldV2 = JSON.stringify({
  v: 2,
  n: 'Legacy v2',
  k: [{ l: 'Fire', a: 'M1', s: 'c', b: 't', x: 0.75, y: 0.5, w: 56, h: 56, o: 65, gid: 'legacy-controls' }]
});
const oldV3 = '3\nLegacy v3\nMenu|P,openGameMenu|0.5|0.1|64|64|s=h|o=70';
const parsedV1 = qr.QrShareService.parseData(oldV1);
const parsedV2 = qr.QrShareService.parseData(oldV2);
const parsedV3 = qr.QrShareService.parseData(oldV3);
assert.equal(parsedV1[0], 'Legacy v1');
assert.deepEqual(plain(parsedV1[1][0].action), { type: 'keyboard', vk: 32 });
assert.equal(parsedV2[0], 'Legacy v2');
assert.deepEqual(plain(parsedV2[1][0].action), { type: 'mouse', button: 1 });
assert.equal(parsedV2[1][0].groupId, 'legacy-controls');
assert.equal(parsedV3[0], 'Legacy v3');
assert.deepEqual(plain(parsedV3[1][0].action), { type: 'special', id: 'openGameMenu' });
assert.equal(parsedV3[1][0].shape, 'hexagon');
console.log('Mouse-look gesture, multitouch, pure movement, layout and sharing tests passed.');
