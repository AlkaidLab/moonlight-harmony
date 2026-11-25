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

function displayService(writer, logger = {}) {
  const { SettingsService } = loadArkTsModule('entry/src/main/ets/service/SettingsService.ets', {
    PreferencesUtil: {}, AppearanceSettingsWriter: { getInstance: () => writer }, Logger: logger,
    OVERLAY_PADDING_KEY, OVERLAY_FONT_SIZE_KEY: 'font'
  }, ['SettingsService']);
  const service = SettingsService.getInstance();
  service.getString = service.getNumber = service.getBoolean = async (key, fallback) => fallback;
  return service;
}

test('rapid changes are serialized and obsolete queued slider values are skipped', async () => {
  const first = deferred();
  const calls = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    calls.push([name(key), value]);
    if (calls.length === 1) await first.promise;
  }, async (key, fallback) => fallback);
  await writer.load();
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
  }, async (key, fallback) => fallback);
  await writer.load();
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
  }, async (key, fallback) => fallback);
  await writer.load();
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

test('failure after recreation rolls back through the new component callback to the confirmed value', async () => {
  const first = deferred();
  const calls = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    calls.push([name(key), value]);
    if (value === 18) await first.promise;
  }, async (key, fallback) => fallback);
  await writer.load();
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


test('a write already pending at the start of a stale read remains authoritative after it completes', async () => {
  const reading = deferred();
  const writing = deferred();
  let blockRead = false;
  const writer = new AppearanceSettingsWriter(12, 12, async () => writing.promise,
    async (key, fallback) => blockRead && key === OVERLAY_PADDING_KEY ? reading.promise : fallback);
  await writer.load();
  blockRead = true;
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
  const service = displayService(writer);
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

test('display settings fall back on an initial appearance read failure and retry later', async () => {
  let failRead = true;
  const writer = new AppearanceSettingsWriter(12, 12, async () => {}, async key => {
    if (failRead) throw new Error('preferences read failed');
    return key === OVERLAY_PADDING_KEY ? 18 : 20;
  });
  const warnings = [];
  const service = displayService(writer, { warn: (...args) => warnings.push(args) });

  const fallback = await service.getDisplaySettings();
  assert.equal(fallback.perfOverlayVerticalPadding, 12);
  assert.equal(fallback.perfOverlayFontSize, 12);
  assert.equal(fallback.enablePerfOverlay, false);
  assert.equal(warnings.length, 1);
  failRead = false;
  const loaded = await service.getDisplaySettings();
  assert.equal(loaded.perfOverlayVerticalPadding, 18);
  assert.equal(loaded.perfOverlayFontSize, 20);
});

test('reset waits for earlier writes and preserves later user choices', async () => {
  const write = deferred();
  const clear = deferred();
  const calls = [];
  let cleared = false;
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    calls.push(['write', value]);
    if (value === 18) await write.promise;
  }, async (key, fallback) => {
    if (cleared) throw new Error('read unavailable after clear');
    return fallback;
  });
  await writer.load();
  writer.saveFontSize(18);
  await Promise.resolve();
  const reset = writer.replacePreferences(async () => {
    calls.push(['clear']);
    await clear.promise;
    cleared = true;
  }, { padding: 12, fontSize: 12 });
  write.resolve();
  await Promise.resolve();
  writer.saveFontSize(24);
  clear.resolve();
  await reset;
  await writer.queue;
  assert.deepEqual(calls, [['write', 18], ['clear'], ['write', 24]]);
  assert.equal(writer.snapshot().fontSize, 24);
});

test('failed reset propagates the error without blocking subsequent writes', async () => {
  const calls = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => calls.push(value),
    async (key, fallback) => fallback);
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

test('backup import restores files and shortcuts when appearance reads fail after flush', async () => {
  const values = { [OVERLAY_PADDING_KEY]: 18, settings_perf_overlay_font_size: 20 };
  const files = [];
  const shortcuts = {};
  let flushed = false;
  let shortcutFlushed = false;
  const prefs = {
    async get(key, fallback) {
      if (flushed) throw new Error('read unavailable after flush');
      return Object.hasOwn(values, key) ? values[key] : fallback;
    },
    async clear() { for (const key of Object.keys(values)) delete values[key]; },
    async put(key, value) { values[key] = value; },
    async flush() { flushed = true; }
  };
  const prefsUtil = {
    getPreferences: async () => prefs,
    getFilesDir: () => '/files',
    getContext: () => ({})
  };
  const { AppearanceSettingsWriter: ProductionWriter, OVERLAY_FONT_SIZE_KEY } = loadArkTsModule(
    'entry/src/main/ets/service/OverlayAppearanceSettings.ets',
    { PreferencesUtil: prefsUtil }, ['AppearanceSettingsWriter', 'OVERLAY_FONT_SIZE_KEY']);
  const writer = ProductionWriter.getInstance();
  await writer.load();
  const shortcutPrefs = {
    async clear() {},
    async put(key, value) { shortcuts[key] = value; },
    async flush() { shortcutFlushed = true; }
  };
  const { SettingsBackupService } = loadArkTsModule('entry/src/main/ets/service/SettingsBackupService.ets', {
    PreferencesUtil: prefsUtil,
    AppearanceSettingsWriter: ProductionWriter,
    OVERLAY_PADDING_KEY, OVERLAY_FONT_SIZE_KEY,
    preferences: { getPreferences: async () => shortcutPrefs },
    Logger: { info() {}, warn() {}, error() {} }
  }, ['SettingsBackupService']);
  SettingsBackupService.writeFileText = (path, content) => files.push([path, content]);
  const backup = { version: 2, settings: { flag: true }, clientCert: 'cert', clientKey: 'key',
    uniqueId: 'id', shortcutConfig: { shortcut: 'Ctrl+A' } };
  assert.equal(await SettingsBackupService.importAll(JSON.stringify(backup)), 1);
  assert.deepEqual(files, [['/files/client_cert.pem', 'cert'], ['/files/client_key.pem', 'key'],
    ['/files/unique_id.txt', 'id']]);
  assert.deepEqual(shortcuts, { shortcut: 'Ctrl+A' });
  assert.equal(shortcutFlushed, true);
  assert.equal(writer.snapshot().padding, 12);
  assert.equal(writer.snapshot().fontSize, 12);
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

test('saving with an unknown baseline never writes an unconfirmed default', async () => {
  let failRead = true;
  const writes = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    writes.push(value);
    if (value === 20) throw new Error('flush failed');
  }, async () => {
    if (failRead) throw new Error('read failed');
    return 18;
  });
  const failures = [];
  attach(writer, failures);
  await assert.rejects(writer.load(), /read failed/);
  writer.savePadding(20);
  await writer.queue;
  assert.deepEqual(writes, []);
  assert.deepEqual(failures, [['padding', 12]]);
  failRead = false;
  writer.savePadding(20);
  await writer.queue;
  assert.deepEqual(writes, [20, 18]);
  assert.deepEqual(failures, [['padding', 12], ['padding', 18]]);
});

test('failed replacement rechecks missing keys against defaults before rollback', async () => {
  let stored = 17;
  const writes = [];
  const writer = new AppearanceSettingsWriter(12, 12, async (key, value) => {
    writes.push(value);
    if (value === 28) throw new Error('flush failed');
    stored = value;
  }, async (key, fallback) => stored ?? fallback);
  await writer.load();
  await assert.rejects(writer.replacePreferences(async () => {
    stored = undefined; // clear succeeded before replacement failed
    throw new Error('replacement failed');
  }));
  writer.savePadding(28);
  await writer.queue;
  assert.deepEqual(writes, [28, 12]);
  assert.equal(stored, 12);
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
