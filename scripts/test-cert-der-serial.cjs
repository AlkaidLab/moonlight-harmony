const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { test } = require('node:test');
const { loadArkTsModule } = require('./test-helpers/load-arkts.cjs');

const CRYPTO_UTIL = 'entry/src/main/ets/utils/CryptoUtil.ets';
const PAIRING_MANAGER = 'entry/src/main/ets/service/network/PairingManager.ets';

const quietLogger = { info() {}, warn() {}, error() {} };

// 固定的 RSA-2048 SubjectPublicKeyInfo，仅用于拼装证书结构
const RSA_SPKI = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 })
  .publicKey.export({ type: 'spki', format: 'der' });

/** 与 CryptoUtil 使用的 cryptoFramework API 对齐的最小替身 */
function createBindings(serialBytes) {
  const util = {
    Base64Helper: class {
      encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
      decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); }
    },
    TextEncoder: class {
      encodeInto(text) { return new Uint8Array(Buffer.from(text, 'utf8')); }
    }
  };

  const keyPair = {
    pubKey: { getEncoded: () => ({ data: new Uint8Array(RSA_SPKI) }) },
    priKey: { getEncodedPem: () => '-----BEGIN PRIVATE KEY-----\nTEST KEY\n-----END PRIVATE KEY-----\n' }
  };

  let signCalls = 0;
  const cryptoFramework = {
    createRandom: () => ({
      generateRandomSync: length => ({ data: new Uint8Array(serialBytes.slice(0, length)) })
    }),
    createAsyKeyGenerator: () => ({
      generateKeyPair: async () => keyPair,
      convertPemKey: async () => keyPair
    }),
    createSign: () => {
      signCalls++;
      return {
        init: async () => {},
        update: async () => {},
        sign: async () => ({ data: new Uint8Array(256).fill(0x5a) })
      };
    }
  };

  return { util, cryptoFramework, signCalls: () => signCalls };
}

function loadCryptoUtil(serialBytes) {
  const bindings = createBindings(serialBytes);
  const { CryptoUtil } = loadArkTsModule(CRYPTO_UTIL, {
    util: bindings.util,
    cryptoFramework: bindings.cryptoFramework,
    canIUse: () => true,
    Logger: quietLogger
  }, ['CryptoUtil']);
  return { CryptoUtil, bindings };
}

/** 用生产代码生成自签名证书 */
async function generateCert(serialBytes) {
  const { CryptoUtil } = loadCryptoUtil(serialBytes);
  const certDer = await CryptoUtil.generateSelfSignedCert({
    pubKey: { getEncoded: () => ({ data: new Uint8Array(RSA_SPKI) }) },
    priKey: { getEncodedPem: () => '' }
  });
  assert.ok(certDer && certDer.length > 0, '证书生成不应失败');
  return { CryptoUtil, certDer };
}

function derLength(length) {
  if (length < 0x80) return Buffer.from([length]);
  if (length < 0x100) return Buffer.from([0x81, length]);
  return Buffer.from([0x82, (length >> 8) & 0xff, length & 0xff]);
}

function der(tag, content) {
  const buffer = Buffer.from(content);
  return Buffer.concat([Buffer.from([tag]), derLength(buffer.length), buffer]);
}

/** 构造只包含 version 和 serialNumber 的最小证书结构 */
function certWithSerial(serialBytes) {
  const version = der(0xa0, der(0x02, [0x02]));
  const serial = der(0x02, serialBytes);
  const tbs = der(0x30, Buffer.concat([version, serial]));
  return new Uint8Array(der(0x30, tbs));
}

function pemOf(certDer) {
  const base64 = Buffer.from(certDer).toString('base64');
  return `-----BEGIN CERTIFICATE-----\n${base64}\n-----END CERTIFICATE-----\n`;
}

/** 内存文件系统，覆盖 PairingManager 读写证书/私钥用到的 fileIo API */
function createFileIo(files) {
  const handles = new Map();
  let nextFd = 1;
  const mode = { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 };

  return {
    OpenMode: mode,
    accessSync: path => files.has(path),
    stat: path => ({ size: files.get(path).length }),
    open: async (path, openMode) => {
      const fd = nextFd++;
      handles.set(fd, path);
      if ((openMode & mode.CREATE) !== 0) {
        files.set(path, Buffer.alloc(0));
      }
      return { fd };
    },
    close: async fd => {
      handles.delete(fd);
    },
    read: async (fd, buffer) => {
      const data = files.get(handles.get(fd)) || Buffer.alloc(0);
      Buffer.from(buffer).set(data.subarray(0, buffer.byteLength));
      return data.length;
    },
    write: async (fd, content) => {
      const data = typeof content === 'string' ? Buffer.from(content, 'utf8') : Buffer.from(content);
      files.set(handles.get(fd), data);
      return data.length;
    }
  };
}

function loadPairingManager(files, serialBytes) {
  const bindings = createBindings(serialBytes);
  // 与 PairingManager 共用同一套 cryptoFramework 绑定，便于统计签名次数
  const { CryptoUtil } = loadArkTsModule(CRYPTO_UTIL, {
    util: bindings.util,
    cryptoFramework: bindings.cryptoFramework,
    canIUse: () => true,
    Logger: quietLogger
  }, ['CryptoUtil']);
  const fileIo = createFileIo(files);

  const { PairingManager } = loadArkTsModule(PAIRING_MANAGER, {
    cryptoFramework: bindings.cryptoFramework,
    fileIo,
    util: bindings.util,
    deviceInfo: { marketName: 'Test Tablet' },
    CryptoUtil,
    StringUtil: { uint8ArrayToString: bytes => Buffer.from(bytes).toString('utf8') },
    HttpClient: {},
    XmlUtil: {},
    NvHttp: { DEFAULT_HTTP_PORT: 47989 },
    parseAddressAndPort: address => ({ host: address, port: undefined }),
    formatAddressForUrl: host => host,
    canIUse: () => true,
    Logger: quietLogger
  }, ['PairingManager']);

  return { PairingManager, signCalls: bindings.signCalls };
}

test('序列号含冗余前导 0 时生成最短 DER，OpenSSL 可解析证书', async () => {
  const { certDer } = await generateCert([0x00, 0x7f, 0x64, 0xec, 0x1a, 0x8f, 0xc4, 0xa2]);
  const certificate = new crypto.X509Certificate(Buffer.from(certDer));
  assert.equal(certificate.serialNumber.toUpperCase(), '7F64EC1A8FC4A2');
});

test('序列号最高位为 1 时补一个前导 0，OpenSSL 可解析证书', async () => {
  const { certDer } = await generateCert([0xff, 0x64, 0xec, 0x1a, 0x8f, 0xc4, 0xa2, 0x11]);
  const certificate = new crypto.X509Certificate(Buffer.from(certDer));
  assert.equal(certificate.serialNumber.toUpperCase(), 'FF64EC1A8FC4A211');
});

test('首字节 0x00 且次字节最高位为 1 时保留必要的前导 0', async () => {
  const { certDer } = await generateCert([0x00, 0xff, 0x64, 0xec, 0x1a, 0x8f, 0xc4, 0xa2]);
  const certificate = new crypto.X509Certificate(Buffer.from(certDer));
  assert.equal(certificate.serialNumber.toUpperCase(), 'FF64EC1A8FC4A2');
});

test('ASN.1 INTEGER 编码只去掉多余前导 0，不影响版本号等短整数', () => {
  const { CryptoUtil } = loadCryptoUtil([]);
  const hex = bytes => Buffer.from(bytes).toString('hex');
  assert.equal(hex(CryptoUtil.asn1Integer(new Uint8Array([0x00, 0x7f]))), '02017f');
  assert.equal(hex(CryptoUtil.asn1Integer(new Uint8Array([0xff]))), '020200ff');
  assert.equal(hex(CryptoUtil.asn1Integer(new Uint8Array([0x00, 0xff]))), '020200ff');
  assert.equal(hex(CryptoUtil.asn1Integer(new Uint8Array([0x00]))), '020100');
  assert.equal(hex(CryptoUtil.asn1Integer(new Uint8Array([0x02]))), '020102');
});

test('坏证书序列号能被识别，合法编码不会被误判', () => {
  const { CryptoUtil } = loadCryptoUtil([]);
  assert.equal(CryptoUtil.hasNonMinimalSerialNumber(certWithSerial([0x00, 0x7f, 0x64])), true);
  assert.equal(CryptoUtil.hasNonMinimalSerialNumber(certWithSerial([0x00, 0x00, 0x7f])), true);
  assert.equal(CryptoUtil.hasNonMinimalSerialNumber(certWithSerial([0x00, 0xff, 0x64])), false);
  assert.equal(CryptoUtil.hasNonMinimalSerialNumber(certWithSerial([0x7f, 0x64])), false);
  assert.equal(CryptoUtil.hasNonMinimalSerialNumber(certWithSerial([0x00])), false);
  assert.equal(CryptoUtil.hasNonMinimalSerialNumber(new Uint8Array(0)), false);
});

test('加载到坏缓存证书时用原私钥重签，重启后不再重签', async () => {
  const keyPem = '-----BEGIN PRIVATE KEY-----\nTEST KEY\n-----END PRIVATE KEY-----\n';
  const badPem = pemOf(certWithSerial([0x00, 0x7f, 0x64, 0xec, 0x1a, 0x8f, 0xc4, 0xa2]));
  const files = new Map([
    ['/files/client_cert.pem', Buffer.from(badPem, 'utf8')],
    ['/files/client_key.pem', Buffer.from(keyPem, 'utf8')]
  ]);

  const { PairingManager, signCalls } = loadPairingManager(
    files, [0x00, 0x7f, 0x64, 0xec, 0x1a, 0x8f, 0xc4, 0xa2]);

  // 第一次启动：检测到坏证书，用现有私钥重签
  await new PairingManager('192.168.2.15', 'ABCDEF0123456789', { filesDir: '/files' }).initialize();
  assert.equal(signCalls(), 1, '坏证书应触发一次重签');
  const repairedPem = files.get('/files/client_cert.pem').toString('utf8');
  const repaired = new crypto.X509Certificate(repairedPem);
  assert.equal(repaired.serialNumber.toUpperCase(), '7F64EC1A8FC4A2');
  assert.equal(files.get('/files/client_key.pem').toString('utf8'), keyPem, '私钥必须保持不变');

  // 重启：证书已合法，不应再次重签
  const repairedBytes = files.get('/files/client_cert.pem');
  await new PairingManager('192.168.2.15', 'ABCDEF0123456789', { filesDir: '/files' }).initialize();
  assert.equal(signCalls(), 1, '合法证书不应再次重签');
  assert.deepEqual(files.get('/files/client_cert.pem'), repairedBytes);
  assert.equal(files.get('/files/client_key.pem').toString('utf8'), keyPem);
});

test('已有的合法证书和私钥在升级后保持不变', async () => {
  const { CryptoUtil } = loadCryptoUtil([]);
  const validDer = await CryptoUtil.generateSelfSignedCert({
    pubKey: { getEncoded: () => ({ data: new Uint8Array(RSA_SPKI) }) },
    priKey: { getEncodedPem: () => '' }
  });
  const certPem = CryptoUtil.derToPem(validDer);
  const keyPem = '-----BEGIN PRIVATE KEY-----\nTEST KEY\n-----END PRIVATE KEY-----\n';
  const files = new Map([
    ['/files/client_cert.pem', Buffer.from(certPem, 'utf8')],
    ['/files/client_key.pem', Buffer.from(keyPem, 'utf8')]
  ]);

  const { PairingManager, signCalls } = loadPairingManager(files, [0x7f, 0x64, 0xec, 0x1a, 0x8f, 0xc4, 0xa2, 0x11]);
  await new PairingManager('192.168.2.15', 'ABCDEF0123456789', { filesDir: '/files' }).initialize();

  assert.equal(signCalls(), 0, '合法身份不应重签');
  assert.equal(files.get('/files/client_cert.pem').toString('utf8'), certPem);
  assert.equal(files.get('/files/client_key.pem').toString('utf8'), keyPem);
});
