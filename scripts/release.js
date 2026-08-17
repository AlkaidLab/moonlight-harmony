#!/usr/bin/env node
/**
 * 版本升级脚本（一键完成版本号 + CHANGELOG + Git commit）
 *
 * 用法:
 *   node scripts/release.js              # 自动递增 build number (732 → 733)
 *   node scripts/release.js 1.0.0.800    # 指定版本号
 *   node scripts/release.js --dry-run    # 预览，不修改文件
 *
 * 流程:
 *   1. 读取当前版本号（AppScope/app.json5）
 *   2. 递增 build number 或使用指定版本
 *   3. 更新 app.json5 中的 versionCode 和 versionName
 *   4. 从上一版本 commit 生成 CHANGELOG 条目
 *   5. 输出 git commit 命令（需手动确认执行）
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const APP_JSON5 = path.join(ROOT, 'AppScope', 'app.json5');

// --- 读取 & 解析 app.json5 ---
function readAppJson5() {
  const content = fs.readFileSync(APP_JSON5, 'utf-8');
  const versionCodeMatch = content.match(/"versionCode":\s*(\d+)/);
  const versionNameMatch = content.match(/"versionName":\s*"([^"]+)"/);
  return {
    content,
    versionCode: versionCodeMatch ? parseInt(versionCodeMatch[1]) : 0,
    versionName: versionNameMatch ? versionNameMatch[1] : '',
  };
}

function writeAppJson5(content, newCode, newName) {
  let updated = content.replace(
    /"versionCode":\s*\d+/,
    `"versionCode": ${newCode}`
  );
  updated = updated.replace(
    /"versionName":\s*"[^"]+"/,
    `"versionName": "${newName}"`
  );
  fs.writeFileSync(APP_JSON5, updated, 'utf-8');
}

// --- 版本号计算 ---
function bumpVersion(currentName) {
  const parts = currentName.split('.');
  const buildNum = parseInt(parts[parts.length - 1]) || 0;
  parts[parts.length - 1] = String(buildNum + 1);
  return parts.join('.');
}

function versionToCode(versionName) {
  const parts = versionName.split('.');
  const buildNum = parseInt(parts[parts.length - 1]) || 0;
  return 1000000 + buildNum;
}

// --- 查找上一版本的 commit ---
function findPreviousVersionCommit() {
  try {
    // Locate the commit that added the current version heading. This works
    // with all historical release commit formats and does not depend on the
    // commit message wording.
    const changelog = fs.readFileSync(
      path.join(ROOT, 'entry/src/main/resources/rawfile/CHANGELOG.md'), 'utf-8');
    const latestVersion = changelog.match(/^## \[([^\]]+)\]/m)?.[1];
    if (!latestVersion) return null;

    const heading = `## [${latestVersion}]`;
    return execSync(
      `git log --format=%H -S${JSON.stringify(heading)} -- entry/src/main/resources/rawfile/CHANGELOG.md -1`,
      { encoding: 'utf-8', cwd: ROOT }
    ).trim() || null;
  } catch {
    return null;
  }
}

// --- Main ---
const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const filteredArgs = args.filter(a => a !== '--dry-run');

const { content, versionCode, versionName } = readAppJson5();
console.log(`当前版本: ${versionName} (code: ${versionCode})\n`);

const newVersion = filteredArgs[0] || bumpVersion(versionName);
const newCode = versionToCode(newVersion);

console.log(`新版本:   ${newVersion} (code: ${newCode})\n`);

// Step 1: 更新 app.json5
if (!dryRun) {
  writeAppJson5(content, newCode, newVersion);
  console.log(`✅ 已更新 AppScope/app.json5`);
} else {
  console.log(`[dry-run] 将更新 AppScope/app.json5`);
}

// Step 2: 生成 CHANGELOG
const prevCommit = findPreviousVersionCommit();
const changelogArgs = [newVersion];
if (prevCommit) changelogArgs.push(prevCommit);

const genScript = path.join(__dirname, 'gen-changelog.js');

if (dryRun) {
  console.log(`\n[dry-run] 将运行: node gen-changelog.js --dry-run ${changelogArgs.join(' ')}\n`);
  try {
    execSync(`node "${genScript}" --dry-run ${changelogArgs.join(' ')}`, {
      cwd: ROOT,
      stdio: 'inherit'
    });
  } catch { /* ignore */ }
} else {
  console.log(`\n📝 生成 CHANGELOG...\n`);
  try {
    execSync(`node "${genScript}" ${changelogArgs.join(' ')}`, {
      cwd: ROOT,
      stdio: 'inherit'
    });
  } catch { /* ignore */ }
}

// Step 3: 提示 git commit
console.log('\n' + '='.repeat(50));
if (dryRun) {
  console.log('(dry-run 模式，未修改任何文件)\n');
} else {
  console.log('✅ 版本升级完成！\n');
  console.log('请检查变更后执行:');
  console.log(`  git add -A`);
  console.log(`  git commit -m "chore: 版本升级至 ${newVersion}"`);
  console.log('');
}
