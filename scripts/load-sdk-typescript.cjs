const fs = require('node:fs');
const path = require('node:path');

module.exports = function findTypeScript() {
  if (process.argv[2]) return require(path.resolve(process.argv[2]));
  try { return require('typescript'); } catch {}
  const roots = [process.env.DEVECO_SDK_HOME];
  if (process.env.DEVECO_HOME) roots.push(path.join(process.env.DEVECO_HOME, 'sdk'), path.join(process.env.DEVECO_HOME, 'Contents/sdk'));
  roots.push('C:/Program Files/Huawei/DevEco Studio/sdk', '/Applications/DevEco-Studio.app/Contents/sdk', '/opt/DevEco-Studio/sdk');
  for (const root of roots.filter(Boolean)) {
    for (const prefix of ['default/openharmony', 'openharmony', '']) {
      const candidate = path.join(root, prefix, 'ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js');
      if (fs.existsSync(candidate)) return require(candidate);
    }
  }
  throw Error('Cannot find SDK TypeScript; pass its typescript.js path as the first argument');
};
