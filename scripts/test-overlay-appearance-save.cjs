const test = require('node:test');
const assert = require('node:assert/strict');
const { loadArkTsModule } = require('./test-helpers/load-arkts.cjs');

const { AppearanceSettingsWriter, OVERLAY_PADDING_KEY } = loadArkTsModule(
  'entry/src/main/ets/service/OverlayAppearanceSettings.ets',
  { PreferencesUtil: {} }, ['AppearanceSettingsWriter', 'OVERLAY_PADDING_KEY']);
function name(key) { return key === OVERLAY_PADDING_KEY ? 'padding' : 'font'; }

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

function attach(writer, failures) {
  return writer.attach(value => failures.push(['padding', value]),
    value => failures.push(['font', value]), () => {});
}

test('rapid changes are serialized and obsolete queued slider values are skipped', async () => {
  const first = deferred();
  const calls = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    calls.push([name(key), value]);
    if (calls.length === 1) await first.promise;
  });
  const failures = [];
  attach(writer, failures);
  writer.savePadding(13);
  await Promise.resolve();
  writer.savePadding(14);
  writer.saveFontSize(20);
  writer.savePadding(15);
  first.resolve();
  await writer.queue;
  assert.deepEqual(calls, [['padding', 13], ['font', 20], ['padding', 15]]);
  assert.deepEqual(failures, []);
});

test('last failed write restores the last flushed value and reports it to the UI', async () => {
  const values = { padding: 12 };
  const calls = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    calls.push([name(key), value]);
    // Model a successful in-memory put followed by a failing flush.
    values[name(key)] = value;
    if (value === 20) throw new Error('flush failed');
  });
  const failures = [];
  attach(writer, failures);
  writer.savePadding(16);
  await writer.queue;
  writer.savePadding(20);
  await writer.queue;
  assert.deepEqual(calls, [['padding', 16], ['padding', 20], ['padding', 16]]);
  assert.equal(values.padding, 16);
  assert.deepEqual(failures, [['padding', 16]]);
});

test('an obsolete failed write does not roll back a newer user choice', async () => {
  const first = deferred();
  const values = {};
  const calls = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    calls.push([name(key), value]);
    if (value === 13) await first.promise;
    values[name(key)] = value;
  });
  const failures = [];
  attach(writer, failures);
  writer.saveFontSize(13);
  await Promise.resolve();
  writer.saveFontSize(20);
  first.reject(new Error('failed'));
  await writer.queue;
  assert.deepEqual(calls, [['font', 13], ['font', 20]]);
  assert.equal(values.font, 20);
  assert.deepEqual(failures, []);
});

test('failed compensation still reports failure and allows retry', async () => {
  const calls = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    calls.push(value);
    if (calls.length <= 2) throw new Error('storage unavailable');
  });
  const failures = [];
  attach(writer, failures);
  writer.saveFontSize(20);
  await writer.queue;
  writer.saveFontSize(22);
  await writer.queue;
  assert.deepEqual(calls, [20, 12, 22]);
  assert.deepEqual(failures, [['font', 12]]);
});

test('recreated component cannot have its choice overwritten by an older in-flight write', async () => {
  const first = deferred();
  const calls = [];
  const values = {};
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    calls.push([name(key), value]);
    if (value === 18) await first.promise;
    values[name(key)] = value;
  });
  const oldFailures = [];
  const newFailures = [];
  attach(writer, oldFailures);
  writer.saveFontSize(18);
  await Promise.resolve();
  // New component inherits the old component's current optimistic value.
  attach(writer, newFailures, 12, 18);
  writer.saveFontSize(24);
  first.reject(new Error('old write failed'));
  await writer.queue;
  assert.deepEqual(calls, [['font', 18], ['font', 24]]);
  assert.equal(values.font, 24);
  assert.deepEqual(oldFailures, []);
  assert.deepEqual(newFailures, []);
});

test('failure after recreation rolls back through the new component callback to the confirmed value', async () => {
  const first = deferred();
  const calls = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    calls.push([name(key), value]);
    if (value === 18) await first.promise;
  });
  const oldFailures = [];
  const newFailures = [];
  const oldOwner = attach(writer, oldFailures);
  writer.saveFontSize(18);
  await Promise.resolve();
  attach(writer, newFailures, 12, 18);
  writer.detach(oldOwner); // A late disappear must not detach the new owner.
  first.reject(new Error('failed'));
  await writer.queue;
  assert.deepEqual(calls, [['font', 18], ['font', 12]]);
  assert.deepEqual(oldFailures, []);
  assert.deepEqual(newFailures, [['font', 12]]);
});


test('detached owner receives a pending rollback and is released after it settles', async () => {
  const first = deferred();
  const failures = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    if (value === 18) await first.promise;
  });
  const owner = attach(writer, failures);
  const oldCallback = writer.fontFailure;
  writer.saveFontSize(18);
  await Promise.resolve();
  writer.detach(owner);
  first.reject(new Error('failed'));
  await writer.queue;
  assert.deepEqual(failures, [['font', 12]]);
  assert.notEqual(writer.fontFailure, oldCallback);
});


test('a completed write during a stale read remains authoritative for the next screen', async () => {
  const reading = deferred();
  const writer = new AppearanceSettingsWriter(12, 12, async () => {}, async (key, fallback) => {
    if (key === OVERLAY_PADDING_KEY) return reading.promise;
    return fallback;
  });
  const loading = writer.load();
  writer.saveFontSize(24);
  await writer.queue;
  reading.resolve(12);
  const result = await loading;
  assert.equal(result.fontSize, 24);
  assert.equal(writer.snapshot().fontSize, 24);
});

test('a write already pending at the start of a stale read remains authoritative after it completes', async () => {
  const reading = deferred();
  const writing = deferred();
  const writer = new AppearanceSettingsWriter(12, 12, async () => writing.promise,
    async (key, fallback) => key === OVERLAY_PADDING_KEY ? reading.promise : fallback);
  writer.savePadding(24);
  await Promise.resolve();
  const loading = writer.load();
  writing.resolve();
  await writer.queue;
  reading.resolve(12);
  assert.equal((await loading).padding, 24);
  assert.equal(writer.snapshot().padding, 24);
});

test('display settings use the latest appearance after other asynchronous settings load', async () => {
  const paused = deferred();
  const entered = deferred();
  const writer = new AppearanceSettingsWriter(12, 12, async () => {}, async (key, fallback) => fallback);
  const { SettingsService } = loadArkTsModule('entry/src/main/ets/service/SettingsService.ets', {
    PreferencesUtil: {},
    AppearanceSettingsWriter: { getInstance: () => writer },
    OVERLAY_PADDING_KEY, OVERLAY_FONT_SIZE_KEY: 'font'
  }, ['SettingsService']);
  const service = SettingsService.getInstance();
  service.getString = async (key, fallback) => fallback;
  service.getNumber = async (key, fallback) => fallback;
  service.getBoolean = async (key, fallback) => {
    entered.resolve();
    await paused.promise;
    return fallback;
  };
  const loading = service.getDisplaySettings();
  await entered.promise;
  writer.savePadding(22);
  writer.saveFontSize(20);
  await writer.queue;
  paused.resolve();
  const settings = await loading;
  assert.equal(settings.perfOverlayVerticalPadding, 22);
  assert.equal(settings.perfOverlayFontSize, 20);
});

test('pending overlay writes serialize with a later settings page choice', async () => {
  const first = deferred();
  const values = {};
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    if (value === 18) await first.promise;
    values[name(key)] = value;
  }, async (key, fallback) => fallback);
  const oldFailures = [];
  const pageFailures = [];
  const oldOwner = attach(writer, oldFailures);
  writer.saveFontSize(18);
  await Promise.resolve();
  writer.detach(oldOwner);
  attach(writer, pageFailures);
  writer.saveFontSize(24);
  first.resolve();
  await writer.queue;
  assert.equal(values.font, 24);
  assert.equal(writer.snapshot().fontSize, 24);
  assert.deepEqual(oldFailures, []);
  assert.deepEqual(pageFailures, []);
});

test('reset waits for earlier writes and preserves later user choices', async () => {
  const write = deferred();
  const clear = deferred();
  const calls = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    calls.push(['write', value]);
    if (value === 18) await write.promise;
  }, async (key, fallback) => fallback);
  writer.saveFontSize(18);
  await Promise.resolve();
  const reset = writer.replacePreferences(async () => {
    calls.push(['clear']);
    await clear.promise;
  });
  write.resolve();
  await Promise.resolve();
  writer.saveFontSize(24);
  clear.resolve();
  await reset;
  await writer.queue;
  assert.deepEqual(calls, [['write', 18], ['clear'], ['write', 24]]);
  assert.equal(writer.snapshot().fontSize, 24);
});

test('a stale read overlapping reset cannot undo default values', async () => {
  const reading = deferred();
  let replacing = false;
  const writer = new AppearanceSettingsWriter(20, 18, async () => {},
    async (key, fallback) => replacing ? fallback : key === OVERLAY_PADDING_KEY ? reading.promise : 18);
  const loading = writer.load();
  await writer.replacePreferences(async () => { replacing = true; });
  reading.resolve(20);
  const result = await loading;
  assert.equal(result.padding, 12);
  assert.equal(result.fontSize, 12);
});

test('saving retains the initiating screen backup callback after another screen attaches', async () => {
  const writing = deferred();
  let backups = 0;
  const writer = new AppearanceSettingsWriter(12, 12, async () => writing.promise);
  writer.attach(() => {}, () => {}, () => { backups++; });
  writer.savePadding(16);
  writer.attach(() => {}, () => {}, () => {});
  writing.resolve();
  await writer.queue;
  assert.equal(backups, 1);
});

test('failed reset propagates the error without blocking subsequent writes', async () => {
  const calls = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => calls.push(value));
  await assert.rejects(writer.replacePreferences(async () => { throw new Error('clear failed'); }));
  writer.savePadding(16);
  await writer.queue;
  assert.deepEqual(calls, [16]);
});

test('backup replacement loads imported values as rollback baseline', async () => {
  const values = { padding: 12, font: 12 };
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    if (value === 20) throw new Error('write failed');
    values[name(key)] = value;
  }, async key => values[name(key)]);
  await writer.replacePreferences(async () => { values.padding = 17; values.font = 19; });
  assert.equal(writer.snapshot().padding, 17);
  assert.equal(writer.snapshot().fontSize, 19);
  const failures = [];
  attach(writer, failures);
  writer.saveFontSize(20);
  await writer.queue;
  assert.equal(values.font, 19);
  assert.deepEqual(failures, [['font', 19]]);
});

test('a new screen waits for a pending backup replacement before loading appearance', async () => {
  const restoring = deferred();
  const values = { padding: 12, font: 12 };
  const writer = new AppearanceSettingsWriter(12, 12, async () => {}, async key => values[name(key)]);
  const replacement = writer.replacePreferences(async () => {
    await restoring.promise;
    values.padding = 17;
    values.font = 19;
  });
  let loaded = false;
  const loading = writer.load().then(result => { loaded = true; return result; });
  await Promise.resolve();
  assert.equal(loaded, false);
  restoring.resolve();
  await replacement;
  const result = await loading;
  assert.equal(result.padding, 17);
  assert.equal(result.fontSize, 19);
});

test('a replacement started during loading is awaited and read again', async () => {
  const staleRead = deferred();
  const restoring = deferred();
  const values = { padding: 12, font: 12 };
  let firstRead = true;
  const writer = new AppearanceSettingsWriter(12, 12, async () => {}, async key => {
    if (key === OVERLAY_PADDING_KEY && firstRead) {
      firstRead = false;
      return staleRead.promise;
    }
    return values[name(key)];
  });
  let loaded = false;
  const loading = writer.load().then(result => { loaded = true; return result; });
  const replacement = writer.replacePreferences(async () => {
    await restoring.promise;
    values.padding = 17;
    values.font = 19;
  });
  staleRead.resolve(12);
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(loaded, false);
  restoring.resolve();
  await replacement;
  const result = await loading;
  assert.equal(result.padding, 17);
  assert.equal(result.fontSize, 19);
});

test('preference read failure preserves the confirmed baseline for later save rollback', async () => {
  const values = { padding: 18, font: 20 };
  let failRead = false;
  const calls = [];
  const { AppearanceSettingsWriter: ProductionWriter } = loadArkTsModule(
    'entry/src/main/ets/service/OverlayAppearanceSettings.ets', {
      PreferencesUtil: {
        getPreferences: async () => ({ get: async key => {
          if (failRead) throw new Error('preferences read failed');
          return values[name(key)];
        } }),
        put: async (key, value) => {
          calls.push([name(key), value]);
          if (value === 22) throw new Error('write failed');
          values[name(key)] = value;
        }
      }
    }, ['AppearanceSettingsWriter']);
  const writer = ProductionWriter.getInstance();
  await writer.load();
  failRead = true;
  const result = await writer.load();
  assert.equal(result.padding, 18);
  assert.equal(result.fontSize, 20);
  const failures = [];
  attach(writer, failures);
  writer.saveFontSize(22);
  await writer.queue;
  assert.deepEqual(calls, [['font', 22], ['font', 20]]);
  assert.deepEqual(failures, [['font', 20]]);
});

test('initial preference read failure is surfaced when no confirmed baseline exists', async () => {
  const writer = new AppearanceSettingsWriter(12, 12, async () => {},
    async () => { throw new Error('preferences read failed'); });
  await assert.rejects(writer.load(), /preferences read failed/);
});

test('replacement reports a post-restore read failure even with a confirmed baseline', async () => {
  let failRead = false;
  const writer = new AppearanceSettingsWriter(12, 12, async () => {}, async (key, fallback) => {
    if (failRead) throw new Error('preferences read failed');
    return fallback;
  });
  await writer.load();
  await assert.rejects(writer.replacePreferences(async () => { failRead = true; }), /preferences read failed/);
});

test('invalid stored values retain confirmed finite values while numeric strings remain supported', async () => {
  const values = { padding: '18', font: '20' };
  const { AppearanceSettingsWriter: ProductionWriter } = loadArkTsModule(
    'entry/src/main/ets/service/OverlayAppearanceSettings.ets', {
      PreferencesUtil: { getPreferences: async () => ({ get: async key => values[name(key)] }) }
    }, ['AppearanceSettingsWriter']);
  const writer = ProductionWriter.getInstance();
  let result = await writer.load();
  assert.equal(result.padding, 18);
  assert.equal(result.fontSize, 20);
  values.padding = 'bad';
  values.font = 'Infinity';
  result = await writer.load();
  assert.equal(result.padding, 18);
  assert.equal(result.fontSize, 20);
});
