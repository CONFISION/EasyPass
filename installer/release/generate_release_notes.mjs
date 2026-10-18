#!/usr/bin/env node
// EasyPass 发布说明生成：把"产物清单"从手工回忆变成脚本产出
//
// 背景：早期发布说明里的 `SHA256  <构建后填这里>` 一直没人填 —— 因为清单要靠人回忆。
// 现在产物清单、大小、SHA-256、清单时间都由 collect_artifacts.mjs 写进 release-manifest.json，
// 本脚本把它渲染成发布说明里那一段；人只写"亮点 / 升级须知"这类只有人知道的内容。
//
// 用法（在仓库根执行）：
//   node installer/release/generate_release_notes.mjs --dry-run     # 打印到 stdout，不写文件
//   node installer/release/generate_release_notes.mjs               # → docs/release-<version>.md
//   node installer/release/generate_release_notes.mjs --manifest dist/release/2.3.3/release-manifest.json
//   node installer/release/generate_release_notes.mjs --out docs/release-3.0.0.md
//   node installer/release/generate_release_notes.mjs --out docs/release-3.0.0.md --force
//
// 参数：
//   --dry-run          只打印，不写文件（stdout 是干净的 Markdown，可直接重定向）
//   --manifest <path>  产物清单（默认 dist/release/<pubspec 版本>/release-manifest.json）
//   --out <path>       输出文件（默认 docs/release-<清单版本>.md；docs/ 在本仓库是本地文档，不入库）
//   --template <path>  模板（默认 installer/release/release_notes.template.md）
//   --force            目标文件没有生成标记时也覆盖重写（**会丢掉里面手写的内容**）
//   --help             用法
//
// 生成规则（刻意保守，绝不静默吞掉人写的东西）：
//   1. 目标文件不存在 → 用模板起一份，填掉脚本能算的部分（版本、大小、SHA-256、清单时间）。
//   2. 目标文件已存在且两个生成标记各出现一次 → **只替换标记之间的内容**，其余原样保留，可反复跑。
//   3. 目标文件已存在但没有标记 / 标记不成对 → 拒绝写入（exit 1），除非显式 --force。
//   4. 脚本只写"能算出来的事实"；TODO(人工) 段落一律留白，只在最后告警提醒还有几处没写。
//
// 退出码：0 = 完成（--dry-run 表示"可以生成"）；1 = 清单不完整 / 目标文件冲突；2 = 参数或环境错误。

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { die, formatBytes, log, parseArgs, readVersion, releaseDir, repoRoot, show } from './lib/release_common.mjs';

const HELP = `EasyPass 发布说明生成（读 release-manifest.json → docs/release-<version>.md）
  node installer/release/generate_release_notes.mjs --dry-run      打印到 stdout，不写文件
  node installer/release/generate_release_notes.mjs                写入 docs/release-<version>.md
  --manifest <path>  --out <path>  --template <path>  --force  --dry-run  --help`;

// 生成标记：单独成行，替换时把标记之间的内容整段换掉（标记本身保留）。
const BEGIN = '<!-- BEGIN GENERATED:artifacts';
const END = '<!-- END GENERATED:artifacts -->';

// ─── 0. 参数与清单 ───────────────────────────────────────────
const { flags, values } = parseArgs(process.argv.slice(2), {
  'dry-run': 'bool',
  force: 'bool',
  help: 'bool',
  manifest: 'value',
  out: 'value',
  template: 'value',
});
if (flags.has('help')) {
  console.log(HELP);
  process.exit(0);
}
const dryRun = flags.has('dry-run');

const { version } = readVersion();
const manifestPath = values.has('manifest')
  ? resolve(values.get('manifest'))
  : resolve(repoRoot, 'dist', 'release', version, 'release-manifest.json');
if (!existsSync(manifestPath)) {
  die(`找不到产物清单 ${show(manifestPath)} —— 先在构建机上跑：node installer/release/collect_artifacts.mjs`);
}
let manifest;
try {
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
} catch (e) {
  die(`产物清单不是合法 JSON：${show(manifestPath)} —— ${e.message}`, 1);
}
if (!manifest || typeof manifest !== 'object' || !manifest.version) die(`产物清单缺少 version：${show(manifestPath)}`, 1);
const list = Array.isArray(manifest.artifacts) ? manifest.artifacts : [];
if (list.length === 0) {
  log.fail(`产物清单里没有任何产物（${show(manifestPath)}）—— 不生成没有产物的发布说明。`);
  process.exit(1);
}
for (const a of list) {
  if (!a || !a.name || !/^[0-9a-f]{64}$/.test(String(a.sha256 || ''))) {
    die(`产物清单里的条目缺少合法 name/sha256：${JSON.stringify(a && a.name ? a.name : a)}`, 1);
  }
}
if (manifest.version !== version) {
  log.warn(`清单版本 ${manifest.version} 与 pubspec.yaml 的 ${version} 不一致 —— 按清单版本生成，确认要发的是哪个版本`);
}

// ─── 1. 渲染"产物与校验和"区块 ────────────────────────────────
const platformLabel = (p) => ({ windows: 'Windows', linux: 'Linux', any: '通用' })[p] || p || '通用';
// Markdown 表格里 `|` 必须转义，否则一个奇怪的文件名就能把表格撕成两半。
const cell = (s) => String(s).replace(/\|/g, '\\|');
const totalBytes = manifest.totalBytes || list.reduce((n, a) => n + (a.bytes || 0), 0);
const totalSize = manifest.totalSize || formatBytes(totalBytes);

function renderBlock() {
  const rows = list.map(
    (a) => `| \`${cell(a.name)}\` | ${platformLabel(a.platform)} | ${a.size || formatBytes(a.bytes || 0)} | \`${a.sha256}\` |`,
  );
  // SHA256SUMS.txt 的原始内容：贴进发布说明，用户可以直接核对/复现（两空格分隔，与 sha256sum 一致）。
  const sums = list.map((a) => `${a.sha256}  ${a.name}`).join('\n');
  const sources = [...new Set(list.map((a) => a.producedBy).filter(Boolean))];
  const lines = [
    `${BEGIN} —— 由 installer/release/generate_release_notes.mjs 依据 release-manifest.json 生成，勿手工编辑 -->`,
    '',
    `版本 **${manifest.version}**（pubspec \`${manifest.versionFull || manifest.version}\`） · 产物 **${list.length}** 个 · 合计 **${totalSize}** · 清单生成时间 ${manifest.generatedAt || '未知'}`,
    '',
    '| 文件 | 平台 | 大小 | SHA-256 |',
    '| --- | --- | ---: | --- |',
    ...rows,
    '',
    '`SHA256SUMS.txt` 的完整内容（与本文件同目录）：',
    '',
    '```text',
    sums,
    '```',
  ];
  if (sources.length) {
    lines.push('', '产物来源（构建由用户 / CI 执行，脚本只做收集与哈希）：', '', '```text', ...sources, '```');
  }
  lines.push('', END);
  return lines.join('\n');
}
const block = renderBlock();

// ─── 2. 套模板 / 只替换生成区块 ───────────────────────────────
/** 模板开头的说明注释（<!-- … -->）是写给改模板的人看的，不进发布说明。 */
function stripTemplateHeader(text) {
  if (!text.startsWith('<!--')) return text;
  const end = text.indexOf('-->');
  return end < 0 ? text : text.slice(end + 3).replace(/^\s*\n/, '');
}

function fillPlaceholders(text) {
  const map = {
    VERSION: manifest.version,
    VERSION_FULL: manifest.versionFull || manifest.version,
    GENERATED_DATE: String(manifest.generatedAt || '').slice(0, 10) || '未知',
    ARTIFACT_COUNT: String(list.length),
    TOTAL_SIZE: totalSize,
    GENERATED_BLOCK: block,
  };
  return text.replace(/\{\{([A-Z_]+)\}\}/g, (raw, key) => (key in map ? map[key] : raw));
}
const count = (text, needle) => text.split(needle).length - 1;

const templatePath = values.has('template')
  ? resolve(values.get('template'))
  : join(releaseDir, 'release_notes.template.md');
const outPath = values.has('out')
  ? resolve(values.get('out'))
  : resolve(repoRoot, 'docs', `release-${manifest.version}.md`);

let doc;
let mode;
if (existsSync(outPath)) {
  const current = readFileSync(outPath, 'utf8');
  const begins = count(current, BEGIN);
  const ends = count(current, END);
  if (begins === 1 && ends === 1) {
    const b = current.indexOf(BEGIN);
    const e = current.indexOf(END);
    if (e < b) die(`目标文件里生成标记的顺序不对（END 在 BEGIN 之前）：${show(outPath)}`, 1);
    doc = fillPlaceholders(current.slice(0, b) + block + current.slice(e + END.length));
    mode = '只替换生成区块，人工段落原样保留';
  } else if (begins === 0 && ends === 0 && flags.has('force')) {
    mode = '--force：整份按模板重写';
  } else if (begins === 0 && ends === 0) {
    log.fail(`${show(outPath)} 已存在，但没有生成标记 —— 拒绝覆盖（里面可能是手写的发布说明）。`);
    log.fail(`两种改法：把它改写成模板结构（保留 ${BEGIN} 与 ${END} 两行标记），或加 --force 整份重写。`);
    process.exit(1);
  } else {
    die(`目标文件里的生成标记不成对（BEGIN×${begins} / END×${ends}）：${show(outPath)}`, 1);
  }
}
if (!doc) {
  if (!existsSync(templatePath)) die(`找不到发布说明模板 ${show(templatePath)}`);
  doc = fillPlaceholders(stripTemplateHeader(readFileSync(templatePath, 'utf8')));
  mode = mode || `由模板 ${show(templatePath)} 生成`;
}

// 不变量：渲染结果里必须正好一对标记，否则下一次运行就没法安全替换。
if (count(doc, BEGIN) !== 1 || count(doc, END) !== 1) {
  die(`渲染结果里的生成标记不是一对（BEGIN×${count(doc, BEGIN)} / END×${count(doc, END)}）—— 模板里是不是多写了一处标记？`, 1);
}

// ─── 3. 报告 + 写出 ──────────────────────────────────────────
// TODO 只报"还剩几处、大概是哪几节"：取注释文本到第一个中文标点为止，避免把整句截成半截话。
const todos = [...doc.matchAll(/<!--\s*TODO\(人工\)[：:]\s*([^>]*?)-->/g)].map((m) => {
  const text = m[1].replace(/\s+/g, ' ').trim();
  const cut = text.search(/[，；。]/);
  return cut > 0 ? text.slice(0, cut) : text.slice(0, 24);
});
const unknown = [...new Set([...doc.matchAll(/\{\{([A-Za-z_]+)\}\}/g)].map((m) => m[1]))];

log.info(`EasyPass 发布说明  版本 ${manifest.version}（清单 ${show(manifestPath)}）`);
log.info(`产物 ${list.length} 个，合计 ${totalSize}；目标 ${show(outPath)}（${mode}）`);
if (unknown.length) log.warn(`文档里还有没被替换的占位符：${unknown.join('、')}`);
if (todos.length) log.warn(`还有 ${todos.length} 处 TODO(人工) 段落待写：${todos.join(' | ')}`);
else log.ok('没有待写的人工段落');

if (dryRun) {
  process.stdout.write(`${doc}\n`);
  log.dry(`未写任何文件。去掉 --dry-run 即写入 ${show(outPath)}`);
  process.exit(0);
}
mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, doc, 'utf8');
log.ok(`已写入 ${show(outPath)}（${doc.length} 字符，${doc.split('\n').length} 行）`);
if (todos.length) log.warn('人工段落还没写 —— 发布前记得补上（再跑一次本脚本会保留它们）。');


