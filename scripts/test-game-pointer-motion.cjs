// Requires a C++17 compiler: g++ on PATH, or CXX set to the compiler executable.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'moonlight-pointer-tests-'));
const tests = ['relative-mouse-motion', 'touchpad-acceleration'];
const executable = name => path.join(tempDir, name + (process.platform === 'win32' ? '.exe' : ''));

function run(command, args) {
  const result = spawnSync(command, args, { stdio: 'inherit', windowsHide: true });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} failed (${result.signal || result.status})`);
  }
}

try {
  for (const name of tests) {
    run(process.env.CXX || 'g++', [
      '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror',
      path.join(__dirname, `test-${name}.cpp`), '-o', executable(name)
    ]);
    run(executable(name), []);
  }
} finally {
  for (const name of tests) fs.rmSync(executable(name), { force: true });
  fs.rmdirSync(tempDir);
}
