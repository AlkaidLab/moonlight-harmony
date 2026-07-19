#!/usr/bin/env node
/*
 * Repository hygiene checks shared by local development and CI.
 */

const { execFileSync } = require('child_process');

function findIgnoredTrackedFiles() {
  return execFileSync('git', ['ls-files', '-ci', '--exclude-standard'], {
    encoding: 'utf8'
  }).trim();
}

try {
  const ignoredFiles = findIgnoredTrackedFiles();
  if (ignoredFiles) {
    console.error('Tracked files must not match .gitignore:');
    console.error(ignoredFiles);
    process.exit(1);
  }

  console.log('Repository hygiene checks passed.');
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`Repository hygiene checks failed: ${message}`);
  process.exit(1);
}
