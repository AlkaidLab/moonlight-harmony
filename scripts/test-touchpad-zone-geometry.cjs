const test = require('node:test');
const assert = require('node:assert/strict');
const { loadArkTsModule } = require('./test-helpers/load-arkts.cjs');
const { TouchpadZoneGeometry: geometry } = loadArkTsModule(
  'entry/src/main/ets/service/input/TouchpadZoneGeometry.ets', {}, ['TouchpadZoneGeometry']);

test('minimum touchpad zone dimensions survive serialization', () => {
  const zone = { left: 0.18, top: 0.88, right: 0.30, bottom: 0.94 };
  const parsed = geometry.parseZoneRect(geometry.formatZoneRect(zone));
  assert.equal(geometry.formatZoneRect(parsed), geometry.formatZoneRect(zone));
});

test('undersized stored zones fall back to the default', () => {
  for (const raw of ['0.18,0.8801,0.82,0.9400', '0.18,0.74,0.2999,0.94']) {
    assert.equal(geometry.formatZoneRect(geometry.parseZoneRect(raw)), geometry.DEFAULT_ZONE_RECT
      .split(',').map(Number).map(value => value.toFixed(4)).join(','));
  }
});

test('surface coordinates undo layout, drawing offsets, scale and translation', () => {
  const p = geometry.toSurfacePoint(840, 760, 100, 200, 50, -20, 1.2, 60, -140);
  assert.ok(Math.abs(p.x - 500) < 1e-9);
  assert.ok(Math.abs(p.y - 570) < 1e-9);
  const q = geometry.toSurfacePoint(300, 400, 0, 0, 0, 0, 1, 0, 0);
  assert.equal(q.x, 300);
  assert.equal(q.y, 400);
});
