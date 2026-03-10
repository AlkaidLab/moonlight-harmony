#!/usr/bin/env node
/**
 * Changelog 自动生成脚本
 *
 * 从 Git 提交记录生成 CHANGELOG.md 条目，遵循项目现有格式。
 *
 * 用法:
 *   node scripts/gen-changelog.js [版本号] [起始ref]
 *
 * 示例:
 *   node scripts/gen-changelog.js 1.0.0.733              # 从上一个版本 tag 开始
 *   node scripts/gen-changelog.js 1.0.0.733 HEAD~20      # 从 HEAD~20 开始
 *   node scripts/gen-changelog.js 1.0.0.733 v1.0.0.725   # 从指定 tag 开始
 *   node scripts/gen-changelog.js --dry-run               # 预览，不写入文件
 *
 * Commit 前缀映射:
 *   feat     → 新增
 *   fix      → 修复
 *   perf     → 优化
 *   refactor → 优化
 *   remove   → 移除
 *   ci/chore/docs/style/test → 跳过（不计入用户可见变更）
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// Conventional commit prefix → 中文分类
const CATEGORY_MAP = {
  feat: '新增',
  fix: '修复',
  perf: '优化',
  refactor: '优化',
  remove: '移除',
};

// 各分类的 emoji 前缀池（随机选取，增添趣味）
const CATEGORY_EMOJI = {
  '新增': ['✨', '🎉', '🆕', '⚡', '🚀'],
  '修复': ['🐛', '🔧', '🩹', '🛡️', '🔨'],
  '优化': ['🎯', '💡', '🏎️', '♻️', '📈'],
  '移除': ['🗑️', '🧹', '👋'],
};

// 跳过的前缀（CI / 文档等不面向用户的改动）
const SKIP_PREFIXES = ['ci', 'chore', 'docs', 'style', 'test', 'build'];

// 分类输出顺序
const CATEGORY_ORDER = ['新增', '优化', '修复', '移除'];

const CHANGELOG_PATH = path.resolve(__dirname,
  '../entry/src/main/resources/rawfile/CHANGELOG.md');

function getGitLog(since) {
  const range = since ? `${since}..HEAD` : '';
  const cmd = `git log ${range} --pretty=format:"%s" --no-merges`;
  try {
    return execSync(cmd, { encoding: 'utf-8', cwd: path.resolve(__dirname, '..') })
      .split('\n')
      .filter(Boolean);
  } catch {
    return [];
  }
}

function parseCommit(message) {
  // 匹配: type(scope): description 或 type: description
  const match = message.match(/^(\w+)(?:\([^)]*\))?:\s*(.+)$/);
  if (!match) return null;

  const prefix = match[1].toLowerCase();
  const description = match[2].trim();

  if (SKIP_PREFIXES.includes(prefix)) return null;

  const category = CATEGORY_MAP[prefix];
  if (!category) return null;

  return { category, description };
}

function generateEntry(version, commits) {
  const grouped = {};
  for (const msg of commits) {
    const parsed = parseCommit(msg);
    if (!parsed) continue;
    if (!grouped[parsed.category]) grouped[parsed.category] = [];
    // 去重
    if (!grouped[parsed.category].includes(parsed.description)) {
      grouped[parsed.category].push(parsed.description);
    }
  }

  if (Object.keys(grouped).length === 0) {
    console.log('没有符合条件的变更记录。');
    return null;
  }

  const now = new Date();
  const date = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  const lines = [`## [${version}] - ${date}`];

  for (const cat of CATEGORY_ORDER) {
    if (!grouped[cat] || grouped[cat].length === 0) continue;
    lines.push('');
    lines.push(`### ${cat}`);
    const emojis = CATEGORY_EMOJI[cat] || [''];
    for (let i = 0; i < grouped[cat].length; i++) {
      const emoji = emojis[i % emojis.length];
      lines.push(`- ${emoji} ${grouped[cat][i]}`);
    }
  }

  return lines.join('\n');
}

function insertIntoChangelog(entry) {
  if (!fs.existsSync(CHANGELOG_PATH)) {
    console.error(`CHANGELOG 文件不存在: ${CHANGELOG_PATH}`);
    return false;
  }

  const content = fs.readFileSync(CHANGELOG_PATH, 'utf-8');
  // 在第一个 ## 之前插入新条目
  const firstVersionIndex = content.indexOf('\n## [');
  if (firstVersionIndex === -1) {
    console.error('无法定位 CHANGELOG 中的版本标记');
    return false;
  }

  const newContent = content.slice(0, firstVersionIndex) +
    '\n' + entry + '\n' +
    content.slice(firstVersionIndex);

  fs.writeFileSync(CHANGELOG_PATH, newContent, 'utf-8');
  return true;
}

// --- Main ---
const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const filteredArgs = args.filter(a => a !== '--dry-run');

const version = filteredArgs[0];
const since = filteredArgs[1] || null;

if (!version && !dryRun) {
  // 预览模式：显示可用的 commit
  console.log('用法: node scripts/gen-changelog.js [--dry-run] <版本号> [起始ref]\n');
  console.log('最近 20 条 commit:\n');
  const commits = getGitLog(since);
  const preview = commits.slice(0, 20);
  for (const msg of preview) {
    const parsed = parseCommit(msg);
    const tag = parsed ? `[${parsed.category}]` : '[跳过]';
    console.log(`  ${tag.padEnd(6)} ${msg}`);
  }
  console.log(`\n共 ${commits.length} 条 commit，其中 ${commits.filter(m => parseCommit(m)).length} 条将被收录`);
  process.exit(0);
}

const commits = getGitLog(since);
console.log(`扫描到 ${commits.length} 条 commit`);

const versionForEntry = version || 'UNRELEASED';
const entry = generateEntry(versionForEntry, commits);

if (!entry) {
  process.exit(0);
}

console.log('\n--- 生成的 CHANGELOG 条目 ---\n');
console.log(entry);
console.log('\n----------------------------\n');

if (dryRun) {
  console.log('(dry-run 模式，未写入文件)');
} else {
  if (insertIntoChangelog(entry)) {
    console.log(`✅ 已写入 ${CHANGELOG_PATH}`);
  } else {
    console.log('❌ 写入失败');
    process.exit(1);
  }
}
