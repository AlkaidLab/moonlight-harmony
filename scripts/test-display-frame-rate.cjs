// Run with Node, optionally passing the SDK's typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
let info = { refreshRate: 90, supportedRefreshRates: [60, 90, 120] };
let fail = false;
const moduleStub = { exports: {} };
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/utils/DisplayFrameRate.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
vm.runInNewContext(compiled, {
  exports: moduleStub.exports,
  require(name) {
    assert.equal(name, '@kit.ArkUI');
    return { display: { getDefaultDisplaySync() {
      if (fail) throw new Error('Display unavailable');
      return info;
    } } };
  }
});
const { getDisplayRequestHz: request, getSupportedDisplayRates: supported } = moduleStub.exports;
assert.deepEqual(Array.from(supported()), [60, 90, 120]);
assert.equal(request(120), 120); // Current 90 Hz must not hide the 120 Hz capability.
assert.equal(request(119.88), 120);
assert.equal(request(144), 120); // Stream FPS can exceed physical display capability.
info = { refreshRate: 60, supportedRefreshRates: [60, 90] };
assert.equal(request(120), 90); // A 90 Hz-only device must not receive a 120 Hz target.
assert.equal(request(90), 90);
info = { refreshRate: 60, supportedRefreshRates: [144, 60, 120] };
assert.equal(request(144), 144);
assert.equal(request(90), 120);
info = { refreshRate: 60 };
assert.equal(supported().length, 0);
assert.equal(request(144), 144); // Unknown capability is not a 60 Hz cap.
info = { refreshRate: 60, supportedRefreshRates: [NaN, 0, -1, Infinity] };
assert.equal(supported().length, 0);
assert.equal(request(120), 120);
fail = true;
assert.equal(request(120), 120);
assert.equal(request(NaN), 60);
assert.equal(request(-1), 60);
console.log('Display frame-rate capability tests passed.');
