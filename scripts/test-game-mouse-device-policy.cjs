// Run with Node.js 22.13+; the pure policy needs no HarmonyOS SDK or mocks.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { stripTypeScriptTypes } = require('node:module');
const source = fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/service/input/GameMouseDevicePolicy.ets'), 'utf8');
const code = stripTypeScriptTypes(source);

async function main() {
  const policy = await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
  const classify = policy.classifyGameMouseDevice;
  const device = (id, sources, bus, vendor, product, phys) => ({ id, sources, bus, vendor, product, phys });
  const devices = [
    // Matebook's two collections share one physical I2C touchpad.
    device(14, ['mouse'], 24, 13045, 2691, '6-005d'),
    device(15, ['touchpad'], 24, 13045, 2691, '6-005d'),
    device(16, [], 24, 13045, 2691, '6-005d'), // A stylus sibling is not a mouse.
    // Observed external HUAWEI Mouse CD20R-57.
    device(20, ['mouse'], 5, 4817, 4319, ''),
    device(21, ['keyboard', 'touchpad', 'mouse'], 3, 123, 456, 'usb1'),
    device(22, ['mouse'], 3, 123, 456, 'usb2'),
    device(23, ['keyboard'], 3, 321, 654, 'usb3'),
    device(24, ['touchpad'], 5, 4817, 4319, ''),
  ];
  assert.equal(classify(devices, 14), 'touchpad');
  assert.equal(classify(devices, 15), 'touchpad');
  assert.equal(classify(devices, 16), 'unknown');
  assert.equal(classify(devices, 20), 'mouse'); // Empty phys must not match another device.
  assert.equal(classify(devices, 21), 'touchpad'); // Touchpad capability takes precedence.
  assert.equal(classify(devices, 22), 'mouse'); // Identical model, different physical path.
  assert.equal(classify(devices, 23), 'unknown');
  assert.equal(classify(devices, -1), 'unknown');
  assert.equal(classify([], 20), 'unknown'); // No inventory must not imply mouse.
  assert.equal(classify(devices.filter(d => d.id !== 20), 20), 'unknown'); // Unplugged.
  const gain = policy.gameMouseGain;
  assert.equal(gain('mouse', 5, false, 2), 5);
  assert.equal(gain('mouse', 5, true, 2), 5);
  assert.equal(gain('touchpad', 5, false, 2), 1);
  assert.equal(gain('touchpad', 5, true, 2), 2);
  assert.equal(gain('touchpad', 5, true, 0.5), 0.5);
  assert.equal(gain('unknown', 5, true, 2), 1);
  const accelerated = policy.gameTouchpadUsesAcceleration;
  assert.equal(accelerated('touchpad', 'accelerated'), true);
  assert.equal(accelerated('touchpad', 'linear'), false);
  assert.equal(accelerated('mouse', 'accelerated'), false);
  assert.equal(accelerated('unknown', 'accelerated'), false);
  assert.equal(accelerated('touchpad', 'invalid'), false);
  console.log('Game mouse device policy tests passed');
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
