// Load production ArkTS service classes in Node without device-only imports.
// Node 22+ supplies type stripping; older local Node versions can use the
// TypeScript compiler already bundled with DevEco, or TYPESCRIPT_PATH.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');

function stripTypes(source) {
  if (typeof stripTypeScriptTypes === 'function') {
    return stripTypeScriptTypes(source);
  }
  const candidates = [
    process.env.TYPESCRIPT_PATH,
    'typescript',
    process.env.DEVECO_HOME && path.join(process.env.DEVECO_HOME,
      'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'),
    process.env.DEVECO_HOME && path.join(process.env.DEVECO_HOME,
      'Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'),
    '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript',
    '/Applications/DevEco Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'
  ].filter(Boolean);
  for (const candidate of candidates) {
    let compiler;
    try {
      compiler = require(candidate);
    } catch (error) {
      if (error.code === 'MODULE_NOT_FOUND') continue;
      throw error;
    }
    return compiler.transpileModule(source, {
      compilerOptions: {
        target: compiler.ScriptTarget.ES2020,
        module: compiler.ModuleKind.CommonJS
      }
    }).outputText;
  }
  throw new Error('Use Node 22.13+ or set TYPESCRIPT_PATH to a TypeScript compiler.');
}

function loadArkTsModule(relativePath, bindings, exportNames) {
  const filename = path.resolve(__dirname, '../..', relativePath);
  const source = fs.readFileSync(filename, 'utf8')
    .replace(/^import\s[\s\S]*?;\s*$/gm, '')
    .replace(/^export\s+(?=(?:class|interface|const|function|type)\s)/gm, '');
  const context = vm.createContext({
    Error, console, setTimeout, clearTimeout, setInterval, clearInterval,
    ...bindings
  });
  vm.runInContext(stripTypes(source) +
    '\nglobalThis.__arktsExports = { ' + exportNames.join(', ') + ' };', context, { filename });
  return context.__arktsExports;
}

module.exports = { loadArkTsModule };
