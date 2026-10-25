// Behavioral tests against the ArkTS sources, using the DevEco SDK compiler.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ts = require('./load-sdk-typescript.cjs')();
const modules = {};
const timers = new Map();
let nextTimer = 0;
let now = 0;
const prefs = new Map();
const input = [];
const modifierInput = [];
const session = {
  sendKeyboardInput(vk, flags, modifiers = 0) { input.push(['key', vk, flags]); modifierInput.push([vk, flags, modifiers]); },
  sendVirtualControllerInput(...args) { input.push(['controller', ...args]); }
};
const TouchType = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
const bridge = {
  sendMouseButton(...args) { input.push(['button', ...args]); },
  sendMouseHighResScroll(...args) { input.push(['scroll', ...args]); },
  sendMouseMove(...args) { input.push(['move', ...args]); }
};
function load(relative, extra = '', transform = source => source) {
  const source = transform(fs.readFileSync(path.join(__dirname, '../entry/src/main/ets', relative), 'utf8') + extra);
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, {
    exports, TouchType, RenderingContextSettings: class {}, CanvasRenderingContext2D: class {},
    setTimeout(fn, delay) { const id = ++nextTimer; timers.set(id, { fn, at: now + delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    require(name) {
      if (name.endsWith('MoonBridge')) return {
        MoonBridge: bridge, BUTTON_ACTION_PRESS: 7, BUTTON_ACTION_RELEASE: 8, TOUCHPAD_FLAG: 0x100000
      };
      for (const [suffix, value] of Object.entries(modules)) if (name.endsWith(suffix)) return value;
      if (name === '@kit.ArkUI') return { display: { getDefaultDisplaySync: () => ({ width: 1000, height: 600 }) } };
      if (name.endsWith('/UI')) return { UI: { get: () => ({ px2vp: n => n }) } };
      if (name.endsWith('PreferencesUtil')) return { PreferencesUtil: {
        getPreferences: async () => ({ get: async (k, fallback) => prefs.get(k) ?? fallback }),
        put: async (k, value) => prefs.set(k, value)
      } };
      if (name.endsWith('SettingsBackupService')) return { SettingsBackupService: { scheduleAutoSave() {} } };
      if (name.endsWith('Logger')) return { Logger: { info() {}, warn() {}, error() {} } };
      return {};
    }
  }, { filename: relative });
  return exports;
}
function loadTouchComponent(relative) {
  // Execute the component's real event/lifecycle methods outside ArkUI. Only
  // declarative rendering and reactive decorators are removed; watchers are
  // invoked explicitly in these input-only tests. Native hit-testing needs a device.
  return load(relative, '', source => {
    source = source.replace(/@Component\s*/, '').replace('export struct ', 'export class ')
      .replace(/@(Prop|State)\b/g, '').replace(/@Watch\('[^']+'\)/g, '');
    const start = source.indexOf('  build() {');
    assert.ok(start >= 0, 'Component must have a build method');
    const scanner = ts.createScanner(ts.ScriptTarget.ES2020, true);
    scanner.setText(source); scanner.setTextPos(source.indexOf('{', start));
    let depth = 0, end;
    for (let token = scanner.scan(); token !== ts.SyntaxKind.EndOfFileToken; token = scanner.scan()) {
      if (token === ts.SyntaxKind.OpenBraceToken) depth++;
      if (token === ts.SyntaxKind.CloseBraceToken && --depth === 0) { end = scanner.getTextPos(); break; }
    }
    assert.ok(end, 'Component build block must balance');
    return source.slice(0, start) + source.slice(end);
  });
}
function flushTimers() {
  while (timers.size) advanceTimers(Math.min(...[...timers.values()].map(timer => timer.at)) - now);
}
function advanceTimers(duration) {
  const target = now + duration;
  while (timers.size) {
    const next = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
    if (next[1].at > target) break;
    now = next[1].at; timers.delete(next[0]); next[1].fn();
  }
  now = target;
}
const plain = value => JSON.parse(JSON.stringify(value));
const types = modules.CustomKeyTypes = load('service/customkey/CustomKeyTypes.ets');
const menu = modules.KeyMenuController = load('service/customkey/KeyMenuController.ets');
const qr = load('service/network/QrShareService.ets', '\nexport { encodeAction, decodeAction };');
const { CustomKeyManager } = load('service/customkey/CustomKeyManager.ets');
const manager = new CustomKeyManager({ getSession: () => session });
const controller = new menu.KeyMenuController();
const opened = [];
controller.onOpenChanged = id => opened.push(id);
controller.onAction = (action, isDown) => manager.handleAction(action, isDown);

// Opening/closing/switching menus never emits host input.
controller.toggle('inventory'); controller.toggle('social'); controller.toggle('social');
assert.deepEqual(opened, ['inventory', 'social', '']);
assert.deepEqual(input, []);
assert.equal(controller.execute({ type: 'keyboard', vk: 66 }, true), false);

// Auto-close removes only the panel: its pending key must still be released.
controller.toggle('inventory');
manager.handleAction({ type: 'keyboard', vk: 87 }, true); // another finger keeps walking
assert.equal(controller.execute({ type: 'keyboard', vk: 66 }, true), true);
assert.equal(opened.at(-1), '');
assert.deepEqual(input, [['key', 87, 3], ['key', 66, 3]]);
flushTimers();
assert.deepEqual(input.at(-1), ['key', 66, 4]);
manager.handleAction({ type: 'keyboard', vk: 87 }, false);
assert.deepEqual(input.at(-1), ['key', 87, 4]);

// Pinned menus stay open. Two command fingers keep independent full pulses;
// the second click cannot truncate the first before the host observes it.
input.length = 0;
controller.toggle('inventory');
controller.execute({ type: 'keyboard', vk: 66 }, false);
controller.execute({ type: 'keyboard', vk: 77 }, false);
assert.equal(opened.at(-1), 'inventory');
assert.deepEqual(input, [['key', 66, 3], ['key', 77, 3]]);
flushTimers();
assert.deepEqual(input, [['key', 66, 3], ['key', 77, 3], ['key', 66, 4], ['key', 77, 4]]);

// Manual close, focus loss, editing, profile replacement and unmount all use
// the same reset path. It must release once and leave no delayed input.
input.length = 0;
controller.execute({ type: 'keyboard', vk: 74 }, false);
controller.close();
controller.reset(); controller.reset(); flushTimers();
assert.deepEqual(input, [['key', 74, 3], ['key', 74, 4]]);
assert.equal(timers.size, 0);

// Menu shortcuts own their sequence timers, including after auto-close. Focus
// loss must cancel steps which have not fired, and release held modifiers.
input.length = 0;
controller.toggle('sequence');
controller.execute({ type: 'shortcut', keys: [], keySequence: [[17, 66], [77], [74]] }, true);
assert.equal(opened.at(-1), '');
assert.deepEqual(input, [['key', 17, 3], ['key', 66, 3]]);
advanceTimers(50); controller.reset(); flushTimers();
assert.deepEqual(input, [['key', 17, 3], ['key', 66, 3], ['key', 66, 4], ['key', 17, 4]]);
input.length = 0;
controller.toggle('sequence');
controller.execute({ type: 'shortcut', keys: [], keySequence: [[66], [77], [74]] }, false);
advanceTimers(199);
assert.deepEqual(input, [['key', 66, 3], ['key', 66, 4]]);
advanceTimers(1);
assert.deepEqual(input.at(-1), ['key', 77, 3]);
flushTimers();
assert.deepEqual(input.slice(-2), [['key', 74, 3], ['key', 74, 4]]);
controller.reset();

// Overlapping logical inputs are shared holds, including menu pulses, normal
// buttons and shortcut modifiers. A release cannot steal another finger's key.
manager.reset(); input.length = 0;
const keyboardB = { type: 'keyboard', vk: 66 };
manager.handleAction(keyboardB, true);
controller.toggle('shared'); controller.execute(keyboardB, true); flushTimers();
assert.deepEqual(input, [['key', 66, 3]]);
manager.handleAction(keyboardB, false);
assert.deepEqual(input, [['key', 66, 3], ['key', 66, 4]]);
input.length = 0;
controller.toggle('shared'); controller.execute(keyboardB, true);
manager.handleAction(keyboardB, true);
advanceTimers(100);
assert.deepEqual(input, [['key', 66, 3]]);
manager.handleAction(keyboardB, false);
assert.deepEqual(input.at(-1), ['key', 66, 4]);
input.length = 0;
manager.handleAction({ type: 'keyboard', vk: 17 }, true);
controller.toggle('modifiers');
controller.execute({ type: 'shortcut', keys: [17, 66] }, true);
manager.handleAction({ type: 'shortcut', keys: [17, 67] }, true);
flushTimers();
assert.deepEqual(input, [['key', 17, 3], ['key', 66, 3], ['key', 67, 3], ['key', 67, 4], ['key', 66, 4]]);
manager.handleAction({ type: 'keyboard', vk: 17 }, false);
assert.deepEqual(input.at(-1), ['key', 17, 4]);
modifierInput.length = 0;
controller.toggle('modifier-flags');
controller.execute({ type: 'shortcut', keys: [17, 18, 66] }, true); flushTimers();
assert.deepEqual(modifierInput, [
  [17, 3, 0], [18, 3, 2], [66, 3, 6], [66, 4, 6], [18, 4, 2], [17, 4, 0]
]);

// Mouse holds, overlapping gamepad bits, LT/RT and D-pad ownership combine
// without clearing the resident control on the menu's timed release.
input.length = 0;
const mouse = { type: 'mouse', button: 1 };
manager.handleAction(mouse, true);
controller.toggle('mouse'); controller.execute(mouse, true); flushTimers();
assert.deepEqual(input, [['button', 7, 1]]);
manager.handleAction(mouse, false);
assert.deepEqual(input.at(-1), ['button', 8, 1]);
input.length = 0;
manager.handleAction({ type: 'gamepadButton', mask: 0x3000 }, true);
controller.toggle('AB'); controller.execute({ type: 'gamepadButton', mask: 0x1000 }, true); flushTimers();
assert.equal(input.at(-1)[1], 0x3000);
manager.handleAction({ type: 'gamepadButton', mask: 0x3000 }, false);
assert.equal(input.at(-1)[1], 0);
manager.handleDPadDirectionChange(1);
controller.toggle('dpad'); controller.execute({ type: 'gamepadButton', mask: 1 }, true); flushTimers();
assert.equal(input.at(-1)[1], 1);
manager.handleAction({ type: 'gamepadButton', mask: 1 }, true);
manager.handleDPadDirectionChange(0);
assert.equal(input.at(-1)[1], 1);
manager.handleAction({ type: 'gamepadButton', mask: 1 }, false);
assert.equal(input.at(-1)[1], 0);
for (const trigger of ['left', 'right']) {
  const action = { type: 'gamepadTrigger', trigger };
  const index = trigger === 'left' ? 2 : 3;
  manager.handleAction(action, true);
  controller.toggle('trigger'); controller.execute(action, true); flushTimers();
  assert.equal(input.at(-1)[index], 255);
  manager.handleAction(action, false);
  assert.equal(input.at(-1)[index], 0);
}

// A menu direction temporarily overrides one axis. Releasing it restores the
// most recent analog position, even if the joystick moved during the pulse.
manager.handleAnalogStickMovement('left', 0.4, -0.2);
controller.toggle('stick');
controller.execute({ type: 'gamepadStick', stick: 'left', direction: 'right' }, true);
assert.equal(input.at(-1)[4], 32767);
assert.equal(input.at(-1)[5], Math.round(0.2 * 0x7FFE));
manager.handleAnalogStickMovement('left', 0.6, 0.3);
assert.equal(input.at(-1)[4], 32767);
flushTimers();
assert.equal(input.at(-1)[4], Math.round(0.6 * 0x7FFE));
assert.equal(input.at(-1)[5], Math.round(-0.3 * 0x7FFE));
manager.handleAction({ type: 'gamepadButton', mask: 0x40 }, true);
manager.handleAnalogStickClick('left'); flushTimers();
assert.equal(input.at(-1)[1], 0x40);
manager.handleAction({ type: 'gamepadButton', mask: 0x40 }, false);
assert.equal(input.at(-1)[1], 0);

// Reset also owns normal shortcut/click timers. A stale release cannot cancel
// the same key newly pressed after a profile/focus reset.
manager.handleAction({ type: 'shortcut', keys: [], keySequence: [[66], [77]] }, true);
manager.handleAnalogStickClick('left');
manager.reset(); input.length = 0;
manager.handleAction(keyboardB, true); flushTimers();
assert.deepEqual(input, [['key', 66, 3]]);
manager.handleAction(keyboardB, false);

// Exercise the actual session routing as well as the merge helper: menu
// snapshots must preserve the stock on-screen controller and physical slot 0.
modules.ControllerInputMerge = load('service/input/ControllerInputMerge.ets');
modules.GamepadTypes = load('service/input/GamepadTypes.ets');
modules.InputEvent = load('model/InputEvent.ets');
const { StreamingSession } = load('service/streaming/StreamingSession.ets');
const emptyController = () => ({ buttonFlags: 0, leftTrigger: 0, rightTrigger: 0,
  leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0 });
const packets = [];
// Keep media and network services out of this input-only session fixture.
const stream = Object.assign(Object.create(StreamingSession.prototype), {
  isRunning: true, controllerState: emptyController(), customControllerState: emptyController(),
  controllerStates: new Map(), physicalControllerArrived: new Set(), physicalControllerTypes: new Map(),
  activeGamepadMask: 0, virtualControllerArrived: false, ds5TouchpadEnabled: false,
  ds5TouchpadButtonPressed: false,
  nativeModule: { sendControllerArrivalEvent: () => 0, sendMultiControllerInput: (...args) => packets.push(args) }
});
const axisType = modules.InputEvent.InputType.CONTROLLER_AXIS;
const buttonType = modules.InputEvent.InputType.CONTROLLER_BUTTON;
stream.sendInput({ type: axisType, axis: 0, value: 14000, controllerIndex: 0 });
stream.sendInput({ type: axisType, axis: 1, value: 8000, controllerIndex: 0 });
stream.sendInput({ type: buttonType, button: 0x1000, isPressed: true, controllerIndex: 0 });
stream.sendVirtualControllerInput(0x2000, 0, 0, 0, 0, 0, 0);
assert.deepEqual(packets.at(-1).slice(2), [0x3000, 0, 0, 14000, 8000, 0, 0]);
stream.sendInput({ type: axisType, axis: 0, value: 17000, controllerIndex: 0 });
assert.equal(packets.at(-1)[2], 0x3000);
assert.equal(stream.controllerStates.get(0).buttonFlags, 0x1000);
stream.sendVirtualControllerInput(0, 0, 0, 0, 0, 0, 0);
assert.deepEqual(packets.at(-1).slice(2), [0x1000, 0, 0, 17000, 8000, 0, 0]);
stream.physicalControllerArrived.add(0);
stream.sendGamepadState(0, 0x0100, 12000, -6000, 22000, 0, 180, 0);
stream.sendVirtualControllerInput(0x2000, 0, 200, 0, 0, 0, 0);
assert.deepEqual(packets.at(-1).slice(2), [0x2100, 180, 200, 12000, -6000, 22000, 0]);
stream.sendGamepadState(0, 0x0200, 9000, -3000, 21000, 0, 160, 0);
assert.deepEqual(packets.at(-1).slice(2), [0x2200, 160, 200, 9000, -3000, 21000, 0]);
stream.sendVirtualControllerInput(0, 0, 0, 0, 0, 0, 0);
assert.deepEqual(packets.at(-1).slice(2), [0x0200, 160, 0, 9000, -3000, 21000, 0]);
stream.ds5TouchpadEnabled = true; stream.ds5TouchpadButtonPressed = true;
stream.sendVirtualControllerInput(0x2000, 0, 0, 0, 0, 0, 0);
assert.equal(packets.at(-1)[2], 0x102200);
stream.physicalControllerArrived.add(1);
stream.sendGamepadState(1, 0x4000, 0, 0, 0, 0, 0, 0);
assert.equal(packets.at(-1)[2], 0x4000, 'Custom inputs and clickpad stay on slot 0');
stream.resetControllerState();
assert.deepEqual(plain(stream.customControllerState), emptyController());

// Replay actual multitouch packets against the same handler as CustomKeyBtn:
// both ArkUI Up conventions, a second finger on the same key, targeted/global
// cancellation, motion outside a hexagon, toggles and the menu's tap gesture.
const { CustomKeyTouchHandler } = load('service/input/CustomKeyTouchHandler.ets');
const finger = (id, x = 20, y = 20) => ({ id, x, y, windowX: x, windowY: y });
const contains = (x, y) => x >= 0 && x <= 60 && y >= 0 && y <= 60;
const keyTouch = new CustomKeyTouchHandler();
const touchEvents = [];
let menuTaps = 0;
function touchEvent(type, touches, changedTouches = touches, mode = 'momentary') {
  return keyTouch.handleEvent({ type, touches, changedTouches }, mode, contains,
    down => touchEvents.push(down), () => menuTaps++);
}
touchEvent(TouchType.Down, [finger(1)]);
touchEvent(TouchType.Down, [finger(1), finger(2)], [finger(2)]);
touchEvent(TouchType.Up, [finger(1)], [finger(2)]);
assert.deepEqual(touchEvents, [true]);
touchEvent(TouchType.Up, [], [finger(1, 100)]);
assert.deepEqual(touchEvents, [true, false]);
touchEvent(TouchType.Down, [finger(3)]);
touchEvent(TouchType.Up, [finger(3), finger(4)], [finger(3)]);
touchEvent(TouchType.Move, [finger(4)]);
touchEvent(TouchType.Up, [], [finger(4)]);
assert.deepEqual(touchEvents, [true, false, true, false]);
touchEvent(TouchType.Down, [finger(5)]);
touchEvent(TouchType.Cancel, [finger(5)], [finger(6)]);
assert.equal(keyTouch.pressed, true);
touchEvent(TouchType.Cancel, [finger(5)], []);
assert.equal(keyTouch.pressed, false);
const balanced = touchEvents.length;
keyTouch.reset(); touchEvent(TouchType.Up, [], [finger(5)]);
assert.equal(touchEvents.length, balanced);
touchEvent(TouchType.Down, [finger(7)], undefined, 'toggle');
touchEvent(TouchType.Down, [finger(7), finger(8)], [finger(8)], 'toggle');
assert.equal(keyTouch.toggled, true);
touchEvent(TouchType.Up, [], [finger(7)], 'toggle');
assert.equal(keyTouch.toggled, true);
keyTouch.reset();
assert.equal(keyTouch.toggled, false);
assert.equal(touchEvents.at(-1), false);
for (const cancelled of ['move-out', 'cancel', 'reset']) {
  touchEvent(TouchType.Down, [finger(9)], undefined, 'tap');
  if (cancelled === 'move-out') touchEvent(TouchType.Move, [finger(9, 100)], undefined, 'tap');
  if (cancelled === 'cancel') touchEvent(TouchType.Cancel, [], [finger(9)], 'tap');
  if (cancelled === 'reset') keyTouch.reset();
  touchEvent(TouchType.Up, [], [finger(9)], 'tap');
}
assert.equal(menuTaps, 0);
touchEvent(TouchType.Down, [finger(10), finger(11)], [finger(11)], 'tap');
touchEvent(TouchType.Up, [finger(11)], [finger(10)], 'tap');
assert.equal(menuTaps, 0);
touchEvent(TouchType.Up, [], [finger(11)], 'tap');
assert.equal(menuTaps, 1);

// Existing joysticks, D-pad and wheel keep their own finger when a menu finger
// is added/removed. Global cancellation, focus loss and unmount release state.
const { VirtualJoystick } = loadTouchComponent('components/virtual/VirtualJoystick.ets');
const joystick = new VirtualJoystick();
const moves = [], joystickDoubleClicks = [];
joystick.onMovement = (x, y) => moves.push([x, y]); joystick.aboutToAppear();
joystick.onDoubleClick = () => joystickDoubleClicks.push(true);
joystick.handleTouch({ type: TouchType.Down, touches: [finger(1, 60, 0)], changedTouches: [finger(1, 60, 0)] });
const firstMove = moves.length;
joystick.handleTouch({ type: TouchType.Up, touches: [finger(1, 60, 0)], changedTouches: [finger(2)] });
assert.equal(moves.length, firstMove);
joystick.aboutToDisappear();
assert.deepEqual(moves.at(-1), [0, 0]);
joystick.handleTouch({ type: TouchType.Move, touches: [finger(1, 60, 0)], changedTouches: [finger(1, 60, 0)] });
assert.deepEqual(moves.at(-1), [0, 0]);
joystick.aboutToAppear();
for (const id of [8, 9]) {
  joystick.handleTouch({ type: TouchType.Down, touches: [finger(id, 60, 0)], changedTouches: [finger(id, 60, 0)] });
  joystick.handleTouch({ type: TouchType.Up, touches: [], changedTouches: [finger(id, 60, 0)] });
}
assert.equal(joystickDoubleClicks.length, 1);
joystick.handleTouch({ type: TouchType.Down, touches: [finger(3, 60, 0)], changedTouches: [finger(3, 60, 0)] });
joystick.handleTouch({ type: TouchType.Cancel, touches: [finger(3, 60, 0)], changedTouches: [] });
assert.deepEqual(moves.at(-1), [0, 0]);
const { VirtualDPad } = loadTouchComponent('components/virtual/VirtualDPad.ets');
const dpad = new VirtualDPad(), directions = [];
dpad.onDirectionChange = value => directions.push(value); dpad.aboutToAppear();
dpad.handleTouch({ type: TouchType.Down, touches: [finger(4, 60, 0)], changedTouches: [finger(4, 60, 0)] });
dpad.handleTouch({ type: TouchType.Cancel, touches: [finger(4, 60, 0)], changedTouches: [finger(5)] });
assert.deepEqual(directions, [1]);
dpad.inputEnabled = false; dpad.resetInput();
assert.deepEqual(directions, [1, 0]);
dpad.aboutToDisappear();
assert.deepEqual(directions, [1, 0]);
const { VirtualWheelPad } = loadTouchComponent('components/virtual/VirtualWheelPad.ets');
const wheel = new VirtualWheelPad(), segments = [];
wheel.segments = [{ label: 'B', action: keyboardB }, { label: 'M', action: { type: 'keyboard', vk: 77 } }];
wheel.onSegmentAction = (action, down) => segments.push([action.vk, down]); wheel.aboutToAppear();
wheel.handleTouch({ type: TouchType.Down, touches: [finger(6, 75, 0)], changedTouches: [finger(6, 75, 0)] });
wheel.handleTouch({ type: TouchType.Up, touches: [finger(6, 75, 0)], changedTouches: [finger(7)] });
assert.deepEqual(segments, [[66, true]]);
wheel.handleTouch({ type: TouchType.Cancel, touches: [finger(6, 75, 0)], changedTouches: [] });
assert.deepEqual(segments, [[66, true], [66, false]]);
wheel.aboutToDisappear();
assert.equal(segments.length, 2);

// Containers and continuous controls are never interpreted as menu commands.
for (const action of [null, { type: 'keyMenu', items: [] }, { type: 'wheelPad', segments: [] },
  { type: 'mouseLook' }, { type: 'analogStick' }, { type: 'dpad' }, { type: 'special', id: 'hideCustomKeys' },
  { type: 'keyboard', vk: NaN }, { type: 'keyboard', vk: 'B' },
  { type: 'combo', actions: [{ type: 'mouseLook' }] }]) {
  assert.equal(menu.isKeyMenuItemAction(action), false);
}
const sideAnchor = types.createDefaultKeyDef();
const sideways = menu.resolveKeyMenuLayout(sideAnchor, 1000, 200, 30);
assert.ok(sideways.x > 500 + sideAnchor.width / 2, 'Prefer a side when vertical placement would cover the launcher');
assert.equal(menu.isKeyMenuItemAction({ type: 'combo', actions: [{ type: 'keyboard', vk: 17 }, { type: 'keyboard', vk: 66 }] }), true);
assert.equal(menu.isKeyMenuItemAction({ type: 'shortcut', keys: [], keySequence: [[91, 88], [85], [83]] }), true);

// Presets, duplicates and undo snapshots own their mutable descendants.
const preset = types.KEY_PRESET_CATEGORIES.find(c => c.name === '快捷菜单').presets[0];
const first = types.createDefaultKeyDef({ label: '背包|菜单', action: preset.action });
const second = types.cloneKeyDef(first);
second.action.items[0].label = 'Changed';
second.action.items[0].action.vk = 65;
second.action.items.push({ label: 'New', action: { type: 'keyboard', vk: 78 } });
assert.equal(first.action.items[0].label, '背包');
assert.equal(first.action.items[0].action.vk, 66);
assert.equal(preset.action.items.length, 5);

// Anchored panels stay inside actual window bounds at every edge and rotation;
// large menus scroll internally rather than extending beyond the display.
for (const [width, height] of [[320, 600], [600, 320], [1000, 600], [600, 1000]]) {
  for (const xPercent of [0, 0.5, 1]) for (const yPercent of [0, 0.5, 1]) {
    for (const count of [0, 1, 5, 60]) {
      const key = { ...first, xPercent, yPercent };
      const rect = menu.resolveKeyMenuLayout(key, width, height, count);
      assert.ok(rect.x >= 8 && rect.y >= 8);
      assert.ok(rect.x + rect.width <= width - 8);
      assert.ok(rect.y + rect.height <= height - 8);
    }
  }
}

// All current sharing paths preserve names, arbitrary delimiters, multi-step
// shortcuts with empty keys, combos and the pinned setting.
const shared = types.createDefaultKeyDef({ label: '菜单|:\n', action: {
  type: 'keyMenu', autoClose: false, items: [
    { label: '背包|仓库:\n', action: { type: 'keyboard', vk: 66 } },
    { label: '组合', action: { type: 'combo', actions: [{ type: 'keyboard', vk: 17 }, { type: 'mouse', button: 1 }] } },
    { label: '休眠', action: { type: 'shortcut', keys: [], keySequence: [[91, 88], [85], [83]] } }
  ]
} });
assert.deepEqual(plain(qr.decodeAction(qr.encodeAction(shared.action))), plain(shared.action));
for (const payload of [qr.QrShareService.serialize('Mixed', [shared, first]), qr.QrShareService.serializeJson('Mixed', [shared, first])]) {
  const result = qr.QrShareService.parseData(payload);
  assert.equal(result[0], 'Mixed');
  assert.equal(result[1].length, 2);
  assert.equal(result[1][0].label, shared.label);
  assert.deepEqual(plain(result[1][0].action), plain(shared.action));
}
assert.deepEqual(plain(qr.decodeAction('Q,%broken')), { type: 'special', id: 'none' });
assert.equal(qr.QrShareService.parseData('3\nBroken\n%|K66|0.5|0.5|60|60|le=1'), null);
assert.deepEqual(plain(qr.decodeAction('K87')), { type: 'keyboard', vk: 87 });
assert.equal(qr.QrShareService.parseData('3\nLegacy\nJump|K32|0.5|0.8|60|60')[1][0].action.vk, 32);
const defaultMenu = menu.normalizeKeyMenuAction({ type: 'keyMenu', items: [
  { label: 'Map', action: { type: 'keyboard', vk: 77 } },
  { label: 'Nested', action: { type: 'keyMenu', items: [] } }, null
] });
assert.equal(defaultMenu.autoClose, true);
assert.equal(defaultMenu.items.length, 1);

async function testStorage() {
  const { CustomKeyStore: store } = load('service/customkey/CustomKeyStore.ets');
  await store.init();
  await store.saveKeys([shared]);
  const json = await store.exportProfile();
  await store.duplicateProfile('Copy');
  const copy = await store.getKeys();
  copy[0].action.items[0].label = 'Only copy';
  await store.switchProfile('默认');
  assert.equal((await store.getKeys())[0].action.items[0].label, shared.action.items[0].label);
  await store.init(); // reload from actual persisted JSON, not the in-memory copy
  assert.deepEqual(plain((await store.getKeys())[0].action), plain(shared.action));
  assert.equal(await store.importProfile(json), true);
  assert.deepEqual(plain((await store.getKeys())[0].action), plain(shared.action));
  assert.equal(await store.mergeImportKeys(json), 1);
  assert.equal((await store.getKeys()).length, 2);
  console.log('Key-menu lifecycle, coexistence, layout, cloning, sharing and storage tests passed.');
}
testStorage().catch(error => { console.error(error); process.exitCode = 1; });
