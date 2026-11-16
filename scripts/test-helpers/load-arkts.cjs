// Load production ArkTS service classes in Node without device-only imports.
// Node 22+ supplies type stripping; older local Node versions can use the
// TypeScript compiler already bundled with DevEco, or TYPESCRIPT_PATH.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');

/**
 * strip-only 模式不支持 enum（会生成运行时代码）。
 * 测试只需读取枚举值，这里把显式赋值的字符串/数字枚举转成等价的常量对象。
 */
function enumsToObjects(source) {
  return source.replace(/^([ \t]*)(?:export\s+)?enum\s+(\w+)\s*\{([\s\S]*?)\}/gm,
    (match, indent, name, body) => {
      const members = body.split(',').map(entry => entry.trim()).filter(Boolean);
      const properties = members.map(entry => {
        const parts = entry.split('=');
        if (parts.length < 2) {
          throw new Error(`load-arkts: 枚举 ${name} 的成员 ${entry} 缺少显式初始值`);
        }
        return `${parts[0].trim()}: ${parts.slice(1).join('=').trim()}`;
      });
      return `${indent}const ${name} = { ${properties.join(', ')} };`;
    });
}

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
  const source = enumsToObjects(fs.readFileSync(filename, 'utf8')
    .replace(/^import\s[\s\S]*?;\s*$/gm, '')
    // OHOS 编译期注解无运行时语义，装饰器也无法被类型擦除
    .replace(/^\s*@SuppressWarnings\(.*\)\s*$/gm, '')
    .replace(/^export\s+(?=(?:class|interface|const|function|type|enum)\s)/gm, ''));
  const context = vm.createContext({
    Error, console, setTimeout, clearTimeout, setInterval, clearInterval,
    ...bindings
  });
  vm.runInContext(stripTypes(source) +
    '\nglobalThis.__arktsExports = { ' + exportNames.join(', ') + ' };', context, { filename });
  return context.__arktsExports;
}

module.exports = { loadArkTsModule };
