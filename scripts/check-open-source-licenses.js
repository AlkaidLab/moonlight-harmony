#!/usr/bin/env node
/*
 * Validate the canonical open-source component manifest and its consumers.
 */

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const manifestRelativePath =
  'entry/src/main/resources/rawfile/open_source_libraries.json';
const manifestPath = path.join(root, manifestRelativePath);
const noticePath = path.join(root, 'OPEN_SOURCE_LICENSES.md');
const settingsPath = path.join(
  root, 'entry/src/main/ets/pages/SettingsPageV2.ets');

function fail(message) {
  console.error(`Open-source license check failed: ${message}`);
  process.exit(1);
}

let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
} catch (error) {
  fail(`cannot parse ${manifestRelativePath}: ${error.message}`);
}

if (manifest.schemaVersion !== 1 || !Array.isArray(manifest.libraries)) {
  fail('manifest must use schemaVersion 1 and contain a libraries array');
}

const names = new Set();
for (const [index, library] of manifest.libraries.entries()) {
  const requiredStrings = ['name', 'license', 'licenseType', 'desc', 'url'];
  for (const field of requiredStrings) {
    if (typeof library[field] !== 'string') {
      fail(`libraries[${index}].${field} must be a string`);
    }
  }
  if (typeof library.showInAbout !== 'boolean') {
    fail(`libraries[${index}].showInAbout must be a boolean`);
  }
  if (!library.name.trim() || names.has(library.name)) {
    fail(`library names must be non-empty and unique: ${library.name}`);
  }
  names.add(library.name);
}

const notice = fs.readFileSync(noticePath, 'utf8');
for (const library of manifest.libraries) {
  if (!notice.includes(library.name)) {
    fail(`OPEN_SOURCE_LICENSES.md does not mention ${library.name}`);
  }
}

const settings = fs.readFileSync(settingsPath, 'utf8');
if (!/getRawFileContentSync\(\s*['"]open_source_libraries\.json['"]\s*\)/
  .test(settings)) {
  fail('SettingsPageV2.ets must load the canonical manifest');
}
if (settings.includes("{ name: 'Moonlight', license:")) {
  fail('SettingsPageV2.ets must not keep a duplicate hard-coded library list');
}

console.log(
  `Open-source license checks passed (${manifest.libraries.length} entries).`);
