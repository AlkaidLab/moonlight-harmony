#!/usr/bin/env node
/**
 * Moonlight 开发者模式激活码生成器
 *
 * 用法: node scripts/devkey-gen.js <deviceId>
 *
 * deviceId 为设备显示的 8 位 ID（或完整 16 位 uniqueId）
 * 算法: SHA-256(salt + fullDeviceId) 取前 8 位 hex 大写
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// 从 DevKeySecret.ets 读取盐值（与 App 保持一致）
const secretFile = path.join(__dirname, '../entry/src/main/ets/config/DevKeySecret.ets');
const secretContent = fs.readFileSync(secretFile, 'utf8');
const match = secretContent.match(/DEV_KEY_SALT\s*=\s*'([^']+)'/);
if (!match) {
  console.error('错误: 无法从 DevKeySecret.ets 读取盐值');
  process.exit(1);
}
const SALT = match[1];

function computeKey(deviceId) {
  const payload = SALT + deviceId;
  const hash = crypto.createHash('sha256').update(payload, 'utf8').digest('hex');
  return hash.substring(0, 8).toUpperCase();
}

const args = process.argv.slice(2);
if (args.length === 0) {
  console.log('用法: node devkey-gen.js <deviceId>');
  console.log('  deviceId: 设备完整 16 位 uniqueId');
  console.log('');
  console.log('示例: node devkey-gen.js a1b2c3d4e5f67890');
  process.exit(1);
}

const deviceId = args[0].toLowerCase();
const key = computeKey(deviceId);

console.log(`设备 ID:  ${deviceId}`);
console.log(`显示 ID:  ${deviceId.substring(0, 8).toUpperCase()}`);
console.log(`激活码:   ${key}`);
