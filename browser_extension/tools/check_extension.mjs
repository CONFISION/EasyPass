#!/usr/bin/env node
// EasyPass 浏览器扩展静态检查（无需浏览器 / 无需构建）
//
// 用途：扩展 JS 没有测试框架，本脚本提供一层"能自动跑"的回归网：
//   1. `node --check` 语法检查（background / popup / content-script）
//   2. i18n 键存在性：JS 里 getMessage('key') 引用的键必须在 en + zh_CN 都存在
//   3. 两份 locale 键集合必须完全一致（防止只补一种语言）
//   4. manifest.json 可解析 + 引用的文件真实存在
//   5. 协议动作覆盖：契约动作必须在 background.js 的分发里出现
//
// 用法：node browser_extension/tools/check_extension.mjs
// 退出码：0 = 全部通过；1 = 有失败项

import { execFileSync } from 'node:child_process';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const extDir = resolve(here, '..');
const failures = [];
const warnings = [];

function fail(msg) {
  failures.push(msg);
}
function warn(msg) {
  warnings.push(msg);
}
function readJson(p) {
  return JSON.parse(readFileSync(p, 'utf8'));
}

// ─── 1. 语法检查 ───────────────────────────────────────────
const jsFiles = ['background.js', 'content-script.js', 'popup/popup.js'];
for (const rel of jsFiles) {
  const abs = join(extDir, rel);
  if (!existsSync(abs)) {
    fail(`缺少文件：${rel}`);
    continue;
  }
  try {
    execFileSync(process.execPath, ['--check', abs], { stdio: 'pipe' });
  } catch (e) {
    fail(`语法错误 ${rel}：${(e.stderr || '').toString().trim()}`);
  }
}

// 开发工具脚本自身也做一次语法检查（tools/*.mjs）
const toolDir = join(extDir, 'tools');
const toolFiles = existsSync(toolDir)
  ? readdirSync(toolDir).filter((f) => f.endsWith('.mjs'))
  : [];
for (const rel of toolFiles) {
  const abs = join(toolDir, rel);
  try {
    execFileSync(process.execPath, ['--check', abs], { stdio: 'pipe' });
  } catch (e) {
    fail(`语法错误 tools/${rel}：${(e.stderr || '').toString().trim()}`);
  }
}

// ─── 2/3. i18n 键 ─────────────────────────────────────────
const locales = {
  en: readJson(join(extDir, '_locales/en/messages.json')),
  zh_CN: readJson(join(extDir, '_locales/zh_CN/messages.json')),
};
const enKeys = new Set(Object.keys(locales.en));
const zhKeys = new Set(Object.keys(locales.zh_CN));

for (const k of enKeys) if (!zhKeys.has(k)) fail(`locale 缺键（zh_CN 缺）：${k}`);
for (const k of zhKeys) if (!enKeys.has(k)) fail(`locale 缺键（en 缺）：${k}`);

const RE_GET_MESSAGE = /getMessage\(\s*['"]([A-Za-z0-9_]+)['"]/g;
const RE_DYNAMIC_MESSAGE = /getMessage\(\s*[^'"\s)]/g;
for (const rel of jsFiles) {
  const abs = join(extDir, rel);
  if (!existsSync(abs)) continue;
  const src = readFileSync(abs, 'utf8');
  for (const m of src.matchAll(RE_GET_MESSAGE)) {
    if (!enKeys.has(m[1])) fail(`${rel} 引用了不存在的 i18n 键：${m[1]}`);
  }
  if (RE_DYNAMIC_MESSAGE.test(src)) {
    warn(`${rel} 存在动态 getMessage(...) 调用，脚本无法静态校验其键名`);
  }
}

// HTML 里的 data-i18n* 属性也要存在于两份 locale
const RE_DATA_I18N = /data-i18n(?:-placeholder|-title)?\s*=\s*["']([A-Za-z0-9_]+)["']/g;
for (const rel of ['popup/popup.html']) {
  const abs = join(extDir, rel);
  if (!existsSync(abs)) {
    fail(`缺少文件：${rel}`);
    continue;
  }
  const html = readFileSync(abs, 'utf8');
  for (const m of html.matchAll(RE_DATA_I18N)) {
    if (!enKeys.has(m[1])) fail(`${rel} 引用了不存在的 i18n 键：${m[1]}`);
  }
}

// 带占位符的键必须传参数（$name$ 形式）
const placeholderKeys = new Set();
for (const [k, v] of Object.entries(locales.en)) {
  if (typeof v.message === 'string' && /\$[A-Za-z0-9_]+\$/.test(v.message)) {
    placeholderKeys.add(k);
  }
}
for (const rel of jsFiles) {
  const abs = join(extDir, rel);
  if (!existsSync(abs)) continue;
  const src = readFileSync(abs, 'utf8');
  for (const key of placeholderKeys) {
    const re = new RegExp(`getMessage\\(\\s*['"]${key}['"]\\s*\\)`, 'g');
    if (re.test(src)) fail(`${rel} 的 ${key} 含占位符但未传参数数组`);
  }
}

// ─── 4. manifest 引用完整性 ────────────────────────────────
const manifestPath = join(extDir, 'manifest.json');
let manifest = null;
try {
  manifest = readJson(manifestPath);
} catch (e) {
  fail(`manifest.json 无法解析：${e.message}`);
}
if (manifest) {
  const referenced = new Set();
  const add = (p) => p && referenced.add(p);
  add(manifest.action?.default_popup);
  add(manifest.background?.service_worker);
  for (const cs of manifest.content_scripts ?? []) {
    for (const f of cs.js ?? []) add(f);
    for (const f of cs.css ?? []) add(f);
  }
  for (const p of Object.values(manifest.icons ?? {})) add(p);
  for (const p of Object.values(manifest.action?.default_icon ?? {})) add(p);
  for (const rel of referenced) {
    if (!existsSync(join(extDir, rel))) fail(`manifest 引用了不存在的文件：${rel}`);
  }
  if (!manifest.permissions?.includes('nativeMessaging')) {
    fail('manifest 缺少 nativeMessaging 权限');
  }
  if (!manifest.permissions?.includes('clipboardWrite')) {
    warn('manifest 缺少 clipboardWrite 权限：popup 复制功能可能被浏览器拒绝');
  }
  if (!manifest.key) fail('manifest 缺少固定扩展 ID 的 key 字段');
}

// ─── 5. 协议动作覆盖 ──────────────────────────────────────
// 与 HANDOFF_V21_CONTRACT.md 第 2.1 节保持同步
const PROTOCOL_ACTIONS = [
  'getStatus',
  'getAllCredentials',
  'searchCredentials',
  'getCredentials',
  'unlock',
  'lock',
  'generatePassword',
  'getTotp',
  'getHealthReport',
];
const bgPath = join(extDir, 'background.js');
if (existsSync(bgPath)) {
  const bg = readFileSync(bgPath, 'utf8');
  for (const action of PROTOCOL_ACTIONS) {
    if (!new RegExp(`case\\s+['"]${action}['"]`).test(bg)) {
      fail(`background.js 未分发协议动作：${action}`);
    }
  }
}

// ─── 6. 硬编码文案（软检查）────────────────────────────────
// 去掉注释后，若 JS 里仍出现中日韩字符，多半是漏走 i18n（仅警告）
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/[^\n]*/g, '$1');
}
for (const rel of jsFiles) {
  const abs = join(extDir, rel);
  if (!existsSync(abs)) continue;
  const body = stripComments(readFileSync(abs, 'utf8'));
  const cjk = body.match(/[\u4e00-\u9fff]+/g);
  if (cjk) {
    warn(`${rel} 疑似硬编码中文文案（应走 i18n）：${[...new Set(cjk)].slice(0, 5).join(' / ')}`);
  }
}

// ─── 6. 版本号三处一致（AGENTS.md 的版本约定）──────────────
// pubspec.yaml `version: x.y.z+n`  ↔  manifest.json `"version"`  ↔  settings_screen.dart 显示串
{
  const repoRoot = resolve(extDir, '..');
  const pubspecPath = join(repoRoot, 'pubspec.yaml');
  const settingsPath = join(repoRoot, 'lib/features/settings/screens/settings_screen.dart');
  const issPath = join(repoRoot, 'installer/easypass_setup.iss');
  const pubVersion = existsSync(pubspecPath)
    ? (readFileSync(pubspecPath, 'utf8').match(/^version:\s*([0-9]+\.[0-9]+\.[0-9]+)/m) || [])[1]
    : null;
  const extVersion = manifest?.version ?? null;
  const settingsVersion = existsSync(settingsPath)
    ? (readFileSync(settingsPath, 'utf8').match(/Text\('([0-9]+\.[0-9]+\.[0-9]+)'\)/) || [])[1]
    : null;
  const issText = existsSync(issPath) ? readFileSync(issPath, 'utf8') : '';
  const issVersion = (issText.match(/#define\s+MyAppVersion\s+"([0-9]+\.[0-9]+\.[0-9]+)"/) || [])[1];
  const issFileVersion = (issText.match(/^VersionInfoVersion=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/m) || [])[1];

  if (!pubVersion) fail('pubspec.yaml 未找到 version: x.y.z');
  if (!extVersion) fail('manifest.json 未找到 version');
  if (!settingsVersion) warn('settings_screen.dart 未找到版本显示串（Text(\'x.y.z\')）');
  if (!issVersion) warn('installer/easypass_setup.iss 未找到 #define MyAppVersion "x.y.z"');
  if (!issFileVersion) warn('installer/easypass_setup.iss 未找到 VersionInfoVersion=x.y.z');

  const seen = new Set([pubVersion, extVersion, settingsVersion, issVersion].filter(Boolean));
  if (seen.size > 1) {
    fail(
      `版本号不一致：pubspec=${pubVersion} manifest=${extVersion} settings=${settingsVersion} installer=${issVersion}`,
    );
  } else if (pubVersion) {
    console.log(
      `  版本号：${pubVersion}（pubspec / manifest / settings_screen / installer 一致）`,
    );
  }
  if (issFileVersion && pubVersion && issFileVersion !== `${pubVersion}.0`) {
    fail(`安装包文件版本应为 ${pubVersion}.0，实际 ${issFileVersion}（installer/easypass_setup.iss）`);
  }
}

// ─── 输出 ─────────────────────────────────────────────────
console.log('EasyPass 扩展静态检查');
console.log(`  语法检查：${jsFiles.join(', ')}`);
console.log(`  i18n 键：en=${enKeys.size} zh_CN=${zhKeys.size}（含占位符键 ${placeholderKeys.size} 个）`);
console.log(`  协议动作：${PROTOCOL_ACTIONS.length} 个`);
for (const w of warnings) console.log(`  ⚠️  ${w}`);
if (failures.length === 0) {
  console.log('✅ 全部检查通过');
  process.exit(0);
}
for (const f of failures) console.log(`  ❌ ${f}`);
console.log(`❌ ${failures.length} 项失败`);
process.exit(1);
