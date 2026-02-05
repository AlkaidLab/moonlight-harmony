#!/usr/bin/env node

/**
 * Hvigor wrapper script (JavaScript version)
 * For HarmonyOS project CI/CD compatibility
 */

const { spawn, execSync } = require('child_process');
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
    const hvigorPath = execSync('which hvigor', { encoding: 'utf8' }).trim();
    if (hvigorPath) {
      const child = spawn(hvigorPath, args, { stdio: 'inherit' });
      child.on('exit', (code) => process.exit(code || 0));
      return;
    }
  } catch (e) {
    // Global hvigor not found
  }
  
  // 5. Try npx
  console.log('Trying npx @ohos/hvigor...');
  const child = spawn('npx', ['@ohos/hvigor', ...args], { stdio: 'inherit', shell: true });
  child.on('exit', (code) => process.exit(code || 0));
  child.on('error', () => {
    console.error('Error: Cannot find hvigor. Please install it via:');
    console.error('  cd hvigor && npm install');
    console.error('  or: ohpm install');
    process.exit(1);
  });
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
