#!/usr/bin/env node

/**
 * Hvigor wrapper script (JavaScript version)
 * For HarmonyOS project CI/CD compatibility
 */

const { spawn, execFileSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const PROJECT_DIR = __dirname;
process.chdir(PROJECT_DIR);

// Set environment variables
process.env.NODE_OPTIONS = process.env.NODE_OPTIONS || '--max_old_space_size=4096';

const args = process.argv.slice(2);

/**
 * Find and execute hvigor
 */
function findAndRunHvigor() {
  // 0. Windows + DevEco Studio: delegate to its bundled hvigor wrapper.
  //    Runs in a separate process so the IDE's hvigor/plugin pair stays a
  //    single consistent instance (project-local copies would split it).
  if (process.platform === 'win32') {
    const devecoHvigorw = 'C:\\Program Files\\Huawei\\DevEco Studio\\tools\\hvigor\\bin\\hvigorw.js';
    const devecoNode = 'C:\\Program Files\\Huawei\\DevEco Studio\\tools\\node\\node.exe';
    if (fs.existsSync(devecoHvigorw) && fs.existsSync(devecoNode)) {
      const child = spawn(devecoNode, [devecoHvigorw, ...args], { stdio: 'inherit', windowsHide: true });
      child.on('exit', (code) => process.exit(code ?? 1));
      child.on('error', (error) => {
        console.error(`Error: Failed to start DevEco hvigor: ${error.message}`);
        process.exit(1);
      });
      return;
    }
  }

  // 1. Check hvigor/node_modules
  const hvigorNodeModules = path.join(PROJECT_DIR, 'hvigor', 'node_modules', '@ohos', 'hvigor', 'bin', 'hvigor.js');
  if (fs.existsSync(hvigorNodeModules)) {
    require(hvigorNodeModules);
    return;
  }
  
  // 2. Check root node_modules
  const rootNodeModules = path.join(PROJECT_DIR, 'node_modules', '@ohos', 'hvigor', 'bin', 'hvigor.js');
  if (fs.existsSync(rootNodeModules)) {
    require(rootNodeModules);
    return;
  }
  
  // 3. Check .hvigor cache
  const hvigorCache = path.join(PROJECT_DIR, '.hvigor');
  if (fs.existsSync(hvigorCache)) {
    const files = findFilesRecursive(hvigorCache, 'hvigor.js');
    if (files.length > 0) {
      require(files[0]);
      return;
    }
  }
  
  // 4. Try global hvigor
  try {
    const locator = process.platform === 'win32' ? 'where.exe' : 'which';
    const hvigorPaths = execFileSync(locator, ['hvigor'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      windowsHide: true
    }).split(/\r?\n/).map((candidate) => candidate.trim()).filter(Boolean);

    if (process.platform === 'win32') {
      for (const commandPath of hvigorPaths) {
        for (const prefix of [path.dirname(commandPath), path.resolve(path.dirname(commandPath), '..')]) {
          const globalEntry = path.join(prefix, 'node_modules', '@ohos', 'hvigor', 'bin', 'hvigor.js');
          if (fs.existsSync(globalEntry)) {
            require(globalEntry);
            return;
          }
        }
      }
    }

    const hvigorPath = hvigorPaths.find((candidate) =>
      process.platform !== 'win32' || /\.(?:com|exe)$/i.test(candidate));
    if (hvigorPath) {
      const child = spawn(hvigorPath, args, { stdio: 'inherit', windowsHide: true });
      child.on('exit', (code) => process.exit(code ?? 1));
      child.on('error', (error) => {
        console.error(`Error: Failed to start hvigor: ${error.message}`);
        process.exit(1);
      });
      return;
    }
  } catch (e) {
    // Global hvigor not found
  }

  console.error('Error: Cannot find hvigor. Run "ohpm install --all" or open the project in DevEco Studio.');
  process.exit(1);
}

function findFilesRecursive(dir, filename) {
  const results = [];
  try {
    const items = fs.readdirSync(dir, { withFileTypes: true });
    for (const item of items) {
      const fullPath = path.join(dir, item.name);
      if (item.isDirectory()) {
        results.push(...findFilesRecursive(fullPath, filename));
      } else if (item.name === filename) {
        results.push(fullPath);
      }
    }
  } catch (e) {
    // Ignore errors
  }
  return results;
}

findAndRunHvigor();
