#!/usr/bin/env node
// EasyPass 浏览器扩展打包脚本（Chrome / Edge 商店上传用）
//
// 用法：
//   node browser_extension/tools/build_extension_zip.mjs              # 打包 → dist/easypass-extension-<version>.zip
//   node browser_extension/tools/build_extension_zip.mjs --dry-run    # 只校验 + 列出将打包的文件，不写任何文件
//   node browser_extension/tools/build_extension_zip.mjs --out <path> # 自定义输出路径
//
// 设计要点：
//   1. **白名单打包**（不是黑名单）：只有 manifest.json / background.js / content-script.js /
//      popup/ / icons/ / _locales/ 会进 zip —— tools/（自检与探针）、native_host/（桌面端安装用）、
//      任何 .md / .bat / .ps1 / .zip / keys/ 一律不进包，避免把开发脚本送到商店审核员手里。
//   2. **零依赖**：ZIP 由本脚本自己写（zlib.deflateRawSync + CRC32），不装 npm 包 —— CI 里不需要 network。
//      时间戳固定为 1980-01-01，同一份源码永远产出同一个 zip（SHA256 可复现，便于对 tag 校验）。
//   3. **上架前的硬校验**：MV3、版本号与 pubspec.yaml 一致、图标/入口文件都在包里、
//      以及**扩展 ID 四处一致**（manifest `key` 推导出的 ID 必须等于 Dart 常量 / .iss / native host manifest）。
//      这条 ID 是 native messaging 的准入名单，改了就等于老用户全部失联，所以让它每次都跑一遍。
//   4. **权限最小化体检**：声明了但代码里没用到的权限会告警（商店审核会问），
//      代码里用了但没声明的权限会直接失败（运行时会坏）。
//
// 退出码：0 = 通过（--dry-run 时表示"可以打包"）；1 = 校验失败；2 = 环境/参数错误。

import { deflateRawSync } from 'node:zlib';
import { createHash } from 'node:crypto';
import { readFileSync, existsSync, statSync, readdirSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve, relative, posix } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const extDir = resolve(here, '..');            // browser_extension/
const repoRoot = resolve(extDir, '..');        // 仓库根

const argv = process.argv.slice(2);
const dryRun = argv.includes('--dry-run');
const outFlag = argv.indexOf('--out');
const outPath = outFlag >= 0 ? resolve(argv[outFlag + 1] || '') : null;
if (outFlag >= 0 && !argv[outFlag + 1]) {
  console.error('❌ --out 需要一个路径参数');
  process.exit(2);
}

const problems = [];
const warnings = [];
const notes = [];
const fail = (m) => problems.push(m);
const warn = (m) => warnings.push(m);

// ─── 1. manifest 基础校验 ────────────────────────────────────
const manifestPath = join(extDir, 'manifest.json');
if (!existsSync(manifestPath)) {
  console.error('❌ 找不到 manifest.json');
  process.exit(2);
}
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));

if (manifest.manifest_version !== 3) fail(`manifest_version 必须是 3，当前 ${manifest.manifest_version}`);

const pubspec = readFileSync(join(repoRoot, 'pubspec.yaml'), 'utf8');
const pubVersion = (pubspec.match(/^version:\s*([0-9]+\.[0-9]+\.[0-9]+)/m) || [])[1];
if (!pubVersion) {
  fail('无法从 pubspec.yaml 读出 version');
} else if (manifest.version !== pubVersion) {
  fail(`版本号不一致：manifest.json=${manifest.version}，pubspec.yaml=${pubVersion}`);
}

// 商店文案：name ≤ 45、description ≤ 132（Chrome Web Store 列表字段上限）
const locales = {};
for (const loc of ['en', 'zh_CN']) {
  const p = join(extDir, '_locales', loc, 'messages.json');
  locales[loc] = existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null;
  if (!locales[loc]) fail(`缺少 _locales/${loc}/messages.json`);
}
function msg(manifestValue, field) {
  const m = /^__MSG_([A-Za-z0-9_]+)__$/.exec(manifestValue || '');
  if (!m) {
    warn(`manifest.${field} 不是 __MSG_key__ 形式（商店会直接用字面量，注意多语言）`);
    return manifestValue || '';
  }
  for (const [loc, table] of Object.entries(locales)) {
    if (!table) continue;
    if (!table[m[1]] || !table[m[1]].message) fail(`_locales/${loc}/messages.json 缺少 ${m[1]}`);
  }
  return (locales.en && locales.en[m[1]] && locales.en[m[1]].message) || '';
}
const storeName = msg(manifest.name, 'name');
const storeDesc = msg(manifest.description, 'description');
if (storeName.length > 45) fail(`名称超过 45 字符（${storeName.length}）：${storeName}`);
if (storeDesc.length > 132) fail(`简短说明超过 132 字符（${storeDesc.length}）：${storeDesc}`);

// ─── 2. 扩展 ID 四处一致（native messaging 的准入名单）─────────
if (!manifest.key) {
  fail('manifest.json 缺少 key —— 扩展 ID 会随安装路径变化，native messaging 准入名单将失配');
}
let derivedId = null;
if (manifest.key) {
  const der = Buffer.from(manifest.key, 'base64');
  const hex = createHash('sha256').update(der).digest('hex').slice(0, 32);
  derivedId = hex.replace(/[0-9a-f]/g, (c) => String.fromCharCode(97 + parseInt(c, 16)));
  const dart = readFileSync(join(repoRoot, 'lib/features/browser_bridge/browser_host_installer.dart'), 'utf8');
  const dartId = (dart.match(/extensionId\s*=\s*'([^']+)'/) || [])[1];
  const iss = readFileSync(join(repoRoot, 'installer/easypass_setup.iss'), 'utf8');
  const issId = (iss.match(/ExtensionId\s*=\s*'([^']+)'/) || [])[1];
  const host = JSON.parse(readFileSync(join(extDir, 'native_host/com.easypass.app.json'), 'utf8'));
  const hostIds = (host.allowed_origins || []).map((o) => String(o).replace(/^chrome-extension:\/\//, '').replace(/\/$/, ''));
  const expected = [
    ['browser_host_installer.dart', dartId],
    ['easypass_setup.iss', issId],
    ['native_host/com.easypass.app.json', hostIds.join(',')],
  ];
  for (const [where, got] of expected) {
    if (got !== derivedId) fail(`扩展 ID 不一致：${where} = ${got}，manifest.key 推导 = ${derivedId}`);
  }
  notes.push(`扩展 ID（manifest.key 推导）：${derivedId} —— 与 Dart 常量 / .iss / native host manifest 一致`);
  notes.push('上架后请复核商店实际分配的 ID 是否仍是这个（Edge 尤其）；若不同，用 EASYPASS_BROWSER_HOST_EXTENSION_ID 追加并重新注册宿主');
}

// ─── 3. 白名单文件收集 ──────────────────────────────────────
const INCLUDE = ['manifest.json', 'background.js', 'content-script.js', 'popup', 'icons', '_locales'];
const FORBIDDEN = [/^tools\//, /^native_host\//, /\.md$/i, /\.zip$/i, /\.bat$/i, /\.ps1$/i, /(^|\/)keys\//, /\.map$/i];

function collect(abs, prefix = '') {
  const out = [];
  const st = statSync(abs);
  if (st.isFile()) {
    out.push({ name: prefix, data: readFileSync(abs) });
    return out;
  }
  for (const entry of readdirSync(abs, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    out.push(...collect(join(abs, entry.name), prefix ? posix.join(prefix, entry.name) : entry.name));
  }
  return out;
}

let files = [];
for (const item of INCLUDE) {
  const abs = join(extDir, item);
  if (!existsSync(abs)) {
    fail(`白名单条目不存在：${item}`);
    continue;
  }
  files.push(...collect(abs, item));
}
for (const f of files) {
  for (const re of FORBIDDEN) if (re.test(f.name)) fail(`不该进包的文件：${f.name}`);
}
files.sort((a, b) => a.name.localeCompare(b.name));

// manifest 引用的运行时文件必须都在包里
const referenced = new Set();
const walkManifest = (v) => {
  if (typeof v === 'string') {
    if (/\.(png|js|html|css|json)$/i.test(v) && !v.startsWith('__MSG')) referenced.add(v);
  } else if (Array.isArray(v)) v.forEach(walkManifest);
  else if (v && typeof v === 'object') Object.values(v).forEach(walkManifest);
};
walkManifest(manifest);
const packed = new Set(files.map((f) => f.name));
for (const ref of referenced) if (!packed.has(ref)) fail(`manifest 引用的文件不在包里：${ref}`);
if (!packed.has('manifest.json')) fail('zip 根目录必须直接是 manifest.json（商店会拒绝嵌套目录的包）');

// ─── 4. 权限最小化体检 ──────────────────────────────────────
const runtimeJs = files.filter((f) => f.name.endsWith('.js')).map((f) => f.data.toString('utf8')).join('\n');
const declared = new Set([...(manifest.permissions || []), ...(manifest.optional_permissions || [])]);
const API_PERMISSION = [
  { id: 'nativeMessaging', required: true, re: /chrome\.runtime\.(connectNative|sendNativeMessage)\s*\(/ },
  { id: 'storage', required: true, re: /chrome\.storage\.(local|sync|session|onChanged)/ },
  { id: 'scripting', required: true, re: /chrome\.scripting\./ },
  { id: 'clipboardWrite', required: true, re: /navigator\.clipboard\.writeText|execCommand\(\s*['"]copy['"]/ },
  // chrome.tabs.query / sendMessage 本身不需要 tabs 权限（有 host_permissions 即可读 url），故不强制
  { id: 'tabs', required: false, re: /chrome\.tabs\./ },
];
for (const { id, required, re } of API_PERMISSION) {
  const used = re.test(runtimeJs);
  if (required && used && !declared.has(id)) fail(`代码用到了 ${id} 对应的 API，但 manifest 没声明该权限`);
  if (!used && declared.has(id)) warn(`声明了 ${id} 但代码里没用到 —— 商店审核会问"为什么需要"，建议删除`);
}
if (declared.has('activeTab') && (manifest.host_permissions || []).includes('<all_urls>')) {
  warn('activeTab 与 host_permissions 的 <all_urls> 重复（有了全站宿主权限就不需要 activeTab），建议删除');
}

// ─── 5. ZIP 写入（零依赖、可复现）────────────────────────────
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
const DOS_DATE = 0x0021; // 1980-01-01
const DOS_TIME = 0x0000;

function buildZip(entries) {
  const parts = [];
  const central = [];
  let offset = 0;
  for (const e of entries) {
    const nameBuf = Buffer.from(e.name, 'ascii');
    const deflated = deflateRawSync(e.data, { level: 9 });
    const useDeflate = deflated.length < e.data.length;
    const body = useDeflate ? deflated : e.data;
    const method = useDeflate ? 8 : 0;
    const crc = crc32(e.data);

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(DOS_TIME, 10);
    local.writeUInt16LE(DOS_DATE, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(body.length, 18);
    local.writeUInt32LE(e.data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);
    parts.push(local, nameBuf, body);

    const cd = Buffer.alloc(46);
    cd.writeUInt32LE(0x02014b50, 0);
    cd.writeUInt16LE(0x031e, 4); // made by UNIX
    cd.writeUInt16LE(20, 6);
    cd.writeUInt16LE(0, 8);
    cd.writeUInt16LE(method, 10);
    cd.writeUInt16LE(DOS_TIME, 12);
    cd.writeUInt16LE(DOS_DATE, 14);
    cd.writeUInt32LE(crc, 16);
    cd.writeUInt32LE(body.length, 20);
    cd.writeUInt32LE(e.data.length, 24);
    cd.writeUInt16LE(nameBuf.length, 28);
    cd.writeUInt16LE(0, 30);
    cd.writeUInt16LE(0, 32);
    cd.writeUInt16LE(0, 34);
    cd.writeUInt16LE(0, 36);
    cd.writeUInt32LE((0o100644 << 16) >>> 0, 38); // >>> 0：32 位位移会溢出成负数
    cd.writeUInt32LE(offset, 42);
    central.push(cd, nameBuf);

    offset += local.length + nameBuf.length + body.length;
  }
  const centralBuf = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  eocd.writeUInt16LE(0, 20);
  return Buffer.concat([...parts, centralBuf, eocd]);
}

// ─── 6. 报告 ────────────────────────────────────────────────
const totalBytes = files.reduce((n, f) => n + f.data.length, 0);
console.log(`EasyPass 浏览器扩展打包${dryRun ? '（--dry-run，不写文件）' : ''}`);
console.log(`  版本：${manifest.version}   文件：${files.length} 个   源码合计：${(totalBytes / 1024).toFixed(1)} KiB`);
console.log(`  名称：${storeName}（${storeName.length}/45）   简短说明：${storeDesc}（${storeDesc.length}/132）`);
console.log('  将打包：');
for (const f of files) console.log(`    ${f.name.padEnd(38)} ${String(f.data.length).padStart(7)} B`);
console.log('  排除：tools/（自检与探针）、native_host/（桌面端安装用）、*.md / *.bat / *.ps1 / keys/');
for (const n of notes) console.log(`  ℹ️  ${n}`);
for (const w of warnings) console.log(`  ⚠️  ${w}`);
for (const p of problems) console.log(`  ❌ ${p}`);

if (problems.length) {
  console.log(`\n❌ ${problems.length} 项校验失败，未打包。`);
  process.exit(1);
}

const target = outPath || join(repoRoot, 'dist', `easypass-extension-${manifest.version}.zip`);
if (dryRun) {
  console.log(`\n✅ 校验通过，可以打包。去掉 --dry-run 即写入：${relative(repoRoot, target).replace(/\\/g, '/')}`);
  process.exit(0);
}

const zip = buildZip(files);
mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, zip);
const sha = createHash('sha256').update(zip).digest('hex');
console.log(`\n✅ 已写入 ${relative(repoRoot, target).replace(/\\/g, '/')}`);
console.log(`   大小：${(zip.length / 1024).toFixed(1)} KiB   SHA256：${sha}`);
if (warnings.length) console.log('   （上面有告警 —— 上架前建议处理，尤其是"没用到的权限"）');
