#!/usr/bin/env node
// EasyPass 发布产物收集：SHA256SUMS.txt + release-manifest.json
//
// 背景：发布时"该附哪些文件、各自的 SHA-256 是多少"过去靠人回忆 —— 早期发布说明里那句
// `SHA256  <构建后填这里>` 一直没人填。本脚本把这件事固定下来：产物清单与校验和由脚本产出，
// 缺产物就是失败，不允许悄悄生成一份"半份"校验和。
//
// 用法（在仓库根执行）：
//   node installer/release/collect_artifacts.mjs --dry-run
//       只读预检：报出找到/缺失的产物，并且**真的算一遍** SHA-256，但不写任何文件（agent / CI 预检用）
//   node installer/release/collect_artifacts.mjs
//       真正收集：把产物拷进 dist/release/<version>/，写出 SHA256SUMS.txt 与 release-manifest.json
//   node installer/release/collect_artifacts.mjs --deb dist/easypass_3.0.0_amd64.deb
//   node installer/release/collect_artifacts.mjs --skip linux             # 只发 Windows 时
//   node installer/release/collect_artifacts.mjs --require extension-zip  # 扩展包也必须存在
//   node installer/release/collect_artifacts.mjs --extra dist/portable.zip
//
// 参数：
//   --dry-run            预检，不写任何文件
//   --strict             --dry-run 时也把"缺产物"当错误（CI 预检用）
//   --installer <path>   Windows 安装包（默认 build/installer/EasypassSetup.exe）
//   --deb <path>         Linux .deb 包（不给则在仓库里自动发现）
//   --extension <path>   扩展商店包（默认 dist/easypass-extension-<version>.zip）
//   --extra <path>       额外产物，可重复（例如将来的便携包 / .deb）
//   --out-dir <path>     输出目录（默认 dist/release/<version>）
//   --skip <key>         跳过某个产物（key 或别名，逗号分隔、可重复）
//   --require <key>      把默认可选的产物升级为"必须有"
//   --help               用法
//   显式给出的路径按当前工作目录解析；默认路径按仓库根解析。
//
// 产出（默认 dist/release/<version>/）：
//   <产物本体>             从构建目录**拷贝**进来 —— 校验和与文件同目录，整目录即可上传 Release
//   SHA256SUMS.txt         `<hex>  <文件名>`，按文件名排序，固定 LF 换行、无注释行
//                          （Linux 上 `sha256sum -c SHA256SUMS.txt` 直接可用；注释行会破坏"标准格式"）
//   release-manifest.json  机器可读清单（名称 / 大小 / sha256 / 版本 / 来源命令）—— 发布说明由它生成
//
// 设计要点：
//   1. **版本号只从 pubspec.yaml 读**（与 installer/deb/build_deb.sh 同一套读法），脚本里不写死版本号。
//   2. **零依赖**：只用 node:fs / node:crypto / node:path，CI 里不需要 npm install；大文件流式哈希，不整份读进内存。
//   3. **缺产物 = 失败，且不产出半份清单**：真正收集时任何"应有却没有"的产物都会让脚本以 1 退出，并且**一个文件都不写**。
//      --dry-run 例外（只报告并以 0 退出，专门给"还没构建过"的机器用），加 --strict 可与真实运行同样严格。
//   4. **可复现**：SHA256SUMS.txt 只取决于产物字节（排序固定、LF、不含时间戳）；manifest 里的时间戳可用
//      SOURCE_DATE_EPOCH 固定（reproducible-builds 约定），CI 里两次运行可得到同一份 manifest。
//   5. **拷贝后重新哈希核对**：产物在收集过程中被并行重建（exe 被覆盖）会立刻失败，
//      而不是悄悄写一份和实际要上传的文件对不上的校验和。
//
// 退出码：0 = 通过（--dry-run 表示"可以收集"）；1 = 产物缺失 / 哈希不一致；2 = 参数或环境错误。

import { createHash } from 'node:crypto';
import { copyFileSync, createReadStream, existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { die, formatBytes, isInside, log, parseArgs, readVersion, repoRoot, samePath, show } from './lib/release_common.mjs';

const HELP = `EasyPass 发布产物收集（SHA256SUMS.txt + release-manifest.json）
  node installer/release/collect_artifacts.mjs --dry-run          预检，不写文件
  node installer/release/collect_artifacts.mjs                    收集 → dist/release/<version>/
  --installer <path>  --deb <path>  --extension <path>  --extra <path>（可重复）
  --out-dir <path>    --skip <key>  --require <key>    --strict  --dry-run  --help
  产物名（--skip / --require 用）：windows-installer / linux-deb / extension-zip
  别名：windows / linux / extension`;

// ─── 0. 参数、版本号、输出目录 ─────────────────────────────────
const { flags, values, multi } = parseArgs(process.argv.slice(2), {
  'dry-run': 'bool',
  strict: 'bool',
  help: 'bool',
  installer: 'value',
  deb: 'value',
  extension: 'value',
  extra: 'list',
  'out-dir': 'value',
  skip: 'list',
  require: 'list',
});
if (flags.has('help')) {
  console.log(HELP);
  process.exit(0);
}

const dryRun = flags.has('dry-run');
// 真实收集时"缺产物"必然是错误；--dry-run 只报告（好让没构建过的机器也能预检），
// 需要 dry-run 也当错误时加 --strict（CI 预检用）。
const strict = !dryRun || flags.has('strict');

const { version, buildNumber, full } = readVersion();
// 显式路径按当前工作目录解析（CLI 常规），默认值按仓库根解析。
const outDir = values.has('out-dir') ? resolve(values.get('out-dir')) : resolve(repoRoot, 'dist', 'release', version);

// ─── 1. 一次发布"应该"有哪些产物 ───────────────────────────────
// required=true：默认必须有，缺了说明流程没走完；
// required=false：存在就收，不存在只告警（扩展包是单独上架商店的，不跟着桌面端一起发）。
const ARTIFACTS = [
  {
    key: 'windows-installer',
    aliases: ['windows', 'installer', 'exe'],
    label: 'Windows 安装包（Inno Setup）',
    platform: 'windows',
    required: true,
    flag: 'installer',
    // installer/easypass_setup.iss: OutputDir=..\\build\\installer, OutputBaseFilename=EasypassSetup
    defaultPath: () => 'build/installer/EasypassSetup.exe',
    producedBy: 'flutter build windows && "C:\\Program Files\\Inno Setup 7\\ISCC.exe" installer\\easypass_setup.iss',
  },
  {
    key: 'linux-deb',
    aliases: ['linux', 'deb', 'appimage'],
    label: 'Linux .deb 安装包',
    platform: 'linux',
    required: true,
    flag: 'deb',
    // 输出名由 installer/deb/build_deb.sh 的调用者决定（默认 dist/easypass_<version>_<arch>.deb），
    // 这里不写死路径 —— 走 discoverDeb()。
    defaultPath: null,
    producedBy:
      'flutter build linux --release && bash tool/build_core.sh --out-dir build/linux/x64/release/bundle && bash installer/deb/build_deb.sh'
  },
  {
    key: 'extension-zip',
    aliases: ['extension', 'ext', 'zip'],
    label: '浏览器扩展商店包',
    platform: 'any',
    required: false,
    flag: 'extension',
    defaultPath: (v) => `dist/easypass-extension-${v}.zip`,
    producedBy: 'node browser_extension/tools/build_extension_zip.mjs',
  },
];

function resolveKey(name) {
  const n = String(name).trim().toLowerCase();
  const hit = ARTIFACTS.find((a) => a.key === n || a.aliases.includes(n));
  if (!hit) {
    const keys = ARTIFACTS.map((a) => `${a.key}（别名 ${a.aliases.join('/')}）`).join('、');
    die(`未知的产物名：${name}。可用：${keys}`);
  }
  return hit.key;
}

// --skip / --require 既可逗号分隔也可重复给出：`--skip linux,extension` 与 `--skip linux --skip extension` 等价。
const listArg = (name) =>
  (multi.get(name) || [])
    .flatMap((v) => String(v).split(','))
    .map((s) => s.trim())
    .filter(Boolean);
const skipped = new Set(listArg('skip').map(resolveKey));
const forced = new Set(listArg('require').map(resolveKey));
for (const k of skipped) forced.delete(k); // --skip 优先于 --require

// ─── 2. .deb 自动发现 ─────────────────────────────────────────
// 只看各候选目录的第一层：build/ 里的同名文件多半是构建中间物，递归进去只会捡到垃圾。
const DEB_DIRS = ['release', 'dist', 'dist/release', 'build', '.'];

function discoverDeb(v, excludeDir) {
  const found = [];
  for (const rel of DEB_DIRS) {
    const dir = resolve(repoRoot, rel);
    if (!existsSync(dir) || !statSync(dir).isDirectory()) continue;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.endsWith('.deb')) continue;
      const abs = join(dir, entry.name);
      if (isInside(abs, excludeDir)) continue; // 上一轮收集进来的拷贝不算"新产物"
      found.push(abs);
    }
  }
  found.sort();
  const versioned = found.filter((p) => basename(p).includes(v));
  if (versioned.length === 1) return { path: versioned[0] };
  if (versioned.length > 1) return { ambiguous: versioned };
  if (found.length === 1) return { path: found[0], note: `文件名里没有版本号 ${v}，按唯一候选使用` };
  if (found.length > 1) return { ambiguous: found };
  return { searched: DEB_DIRS.map((d) => (d === '.' ? './' : `${d}/`)) };
}

// ─── 3. 解析每个产物的来源 ────────────────────────────────────
const plan = []; // { spec, source, note }
const issues = []; // { label, detail, required }
const notes = [];

for (const spec of ARTIFACTS) {
  if (skipped.has(spec.key)) {
    notes.push(`--skip 跳过 ${spec.label}（${spec.key}）`);
    continue;
  }
  const required = spec.required || forced.has(spec.key);
  const explicit = values.get(spec.flag);
  let source = null;

  if (explicit) {
    source = resolve(explicit);
  } else if (spec.defaultPath) {
    source = resolve(repoRoot, spec.defaultPath(version));
  } else {
    const found = discoverDeb(version, outDir);
    if (found.ambiguous) {
      issues.push({
        label: spec.label,
        required: true,
        detail: `发现 ${found.ambiguous.length} 个候选 .deb，无法判断该收哪个 —— 用 --deb 指定：\n         ${found.ambiguous.map(show).join('\n         ')}`,
      });
      continue;
    }
    if (!found.path) {
      issues.push({
        label: spec.label,
        required,
        detail: `未找到（搜索过 ${found.searched.join(' ')}）—— 先构建，或用 --deb 指定路径${required ? '' : '；它属于可选项，但缺了就不会进校验和'}`,
      });
      continue;
    }
    if (found.note) notes.push(`${spec.label}：${found.note}`);
    source = found.path;
  }

  if (!existsSync(source)) {
    issues.push({
      label: spec.label,
      required: required || Boolean(explicit),
      detail: `未找到 ${show(source)}${explicit ? '（--' + spec.flag + ' 显式指定）' : ''}`,
    });
    continue;
  }
  const st = statSync(source);
  if (!st.isFile()) {
    issues.push({ label: spec.label, required: true, detail: `不是普通文件：${show(source)}` });
    continue;
  }
  if (st.size === 0) {
    issues.push({ label: spec.label, required: true, detail: `是 0 字节文件（构建没跑完？）：${show(source)}` });
    continue;
  }
  plan.push({ spec, source });
}

// --extra：显式给出的额外产物，说了就必须在。
for (const extra of multi.get('extra') || []) {
  const abs = resolve(extra);
  const label = `额外产物 ${basename(abs)}`;
  if (!existsSync(abs) || !statSync(abs).isFile()) {
    issues.push({ label, required: true, detail: `未找到 ${show(abs)}（--extra 显式指定）` });
    continue;
  }
  if (statSync(abs).size === 0) {
    issues.push({ label, required: true, detail: `是 0 字节文件：${show(abs)}` });
    continue;
  }
  plan.push({
    spec: { key: `extra:${basename(abs)}`, label, platform: 'any', producedBy: null },
    source: abs,
  });
}

// 同名产物会让 SHA256SUMS.txt 产生歧义（一行哈希对应哪个文件？），必须挡下来。
// 比较用文件名的小写形式：Windows 的目标目录不区分大小写，`Foo.exe` 与 `foo.exe` 会互相覆盖。
const byName = new Map();
for (const item of plan) {
  const name = basename(item.source);
  const key = name.toLowerCase();
  if (byName.has(key)) {
    issues.push({
      label: `产物重名：${name}`,
      required: true,
      detail: `两个来源同名，校验和会歧义（Windows 上还会互相覆盖）：${show(byName.get(key))} 与 ${show(item.source)}`,
    });
  } else {
    byName.set(key, item.source);
  }
}
if (plan.length === 0) {
  issues.push({ label: '产物清单为空', required: true, detail: '一个产物都没收集到，不会生成空的 SHA256SUMS.txt' });
}

// ─── 4. 算哈希（--dry-run 也算，只读）─────────────────────────
/** 流式 SHA-256：安装包几十 MB，不整份读进内存。 */
function sha256File(file) {
  return new Promise((ok, bad) => {
    const hash = createHash('sha256');
    createReadStream(file)
      .on('error', bad)
      .on('data', (chunk) => hash.update(chunk))
      .on('end', () => ok(hash.digest('hex')));
  });
}

const artifacts = [];
for (const { spec, source } of plan) {
  const bytes = statSync(source).size;
  let sha256;
  try {
    sha256 = await sha256File(source);
  } catch (e) {
    issues.push({ label: spec.label, required: true, detail: `读取失败：${show(source)} —— ${e.message}` });
    continue;
  }
  artifacts.push({
    name: basename(source),
    kind: spec.key,
    label: spec.label,
    platform: spec.platform || 'any',
    producedBy: spec.producedBy || null,
    source,
    dest: join(outDir, basename(source)),
    bytes,
    size: formatBytes(bytes),
    sha256,
  });
}
// 按文件名排序：SHA256SUMS.txt 的顺序只取决于名字（先按小写比较，跨平台一致；同分再按原名，稳定）。
artifacts.sort((a, b) => {
  const x = a.name.toLowerCase();
  const y = b.name.toLowerCase();
  if (x !== y) return x < y ? -1 : 1;
  return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
});

// ─── 5. 报告 ─────────────────────────────────────────────────
const hardIssues = issues.filter((i) => i.required);
log.info(`EasyPass 发布产物收集  版本 ${version}（pubspec version: ${full}）`);
log.info(`输出目录 ${show(outDir)}${dryRun ? '（--dry-run：不会写入）' : ''}`);
for (const a of artifacts) log.ok(`${a.name.padEnd(44)} ${a.size.padStart(10)}  ${a.sha256}  ← ${show(a.source)}`);
for (const n of notes) log.note(n);
for (const i of issues) {
  // 严格模式（真实收集，或 --dry-run --strict）下必需产物缺失即错误；否则只告警并标注"正式运行会失败"。
  if (i.required && strict) log.fail(`${i.label}：${i.detail}`);
  else log.warn(`${i.label}：${i.detail}${i.required ? '【必需产物：正式运行时这里会失败】' : ''}`);
}

if (strict && hardIssues.length) {
  log.fail(`缺少 ${hardIssues.length} 个必需产物，未写任何文件（只发 Windows 时加 --skip linux）。`);
  process.exit(1);
}
if (artifacts.length === 0) {
  log.warn('没有任何产物可收集；--dry-run 不算失败，正式运行会以非零码退出。');
  process.exit(0);
}

// ─── 6. 拷贝 + 写出（只有到这里才会动文件系统）──────────────────
if (dryRun) {
  const target = artifacts.length ? show(outDir) : '（无）';
  log.dry(`未写任何文件。去掉 --dry-run 即写入 ${target}`);
  log.dry(`SHA256SUMS.txt 将包含 ${artifacts.length} 行：${artifacts.map((a) => a.name).join('、')}`);
  process.exit(0);
}

mkdirSync(outDir, { recursive: true });

// 上一轮留下的文件会让"整目录上传"变成事故，先提醒。
const planned = new Set(artifacts.map((a) => a.name).concat(['SHA256SUMS.txt', 'release-manifest.json']));
const stale = readdirSync(outDir).filter((n) => !planned.has(n));
if (stale.length) log.warn(`输出目录里还有 ${stale.length} 个非本轮产物（上传前确认是否该删）：${stale.join('、')}`);

let copied = 0;
for (const a of artifacts) {
  if (samePath(a.source, a.dest)) continue; // --out-dir 直接指向产物目录时不做自我拷贝
  copyFileSync(a.source, a.dest);
  const after = await sha256File(a.dest);
  if (after !== a.sha256) {
    log.fail(`拷贝后哈希不一致（产物在收集过程中被改写？）：${show(a.dest)}`);
    process.exit(1);
  }
  copied += 1;
}
log.info(`已拷贝 ${copied} 个产物到 ${show(outDir)}`);

// SHA256SUMS.txt：标准 `<hex>  <文件名>`，LF 换行（不用 os.EOL —— CRLF 会让 Linux 的 sha256sum -c 认不出文件名），
// 且**不写注释行**（保持 sha256sum 的标准格式，任何额外行都可能被当成格式错误）。
const sums = `${artifacts.map((a) => `${a.sha256}  ${a.name}`).join('\n')}\n`;
writeFileSync(join(outDir, 'SHA256SUMS.txt'), sums, 'utf8');
log.ok(`已写入 ${show(join(outDir, 'SHA256SUMS.txt'))}（${artifacts.length} 行）`);

// manifest：机器可读的事实清单，发布说明由 generate_release_notes.mjs 读它生成。
// 时间戳可用 SOURCE_DATE_EPOCH 固定，CI 里可复现；SHA256SUMS.txt 不含时间戳，永远只取决于产物字节。
const epoch = Number(process.env.SOURCE_DATE_EPOCH);
const generatedAt = Number.isFinite(epoch) && epoch > 0 ? new Date(epoch * 1000).toISOString() : new Date().toISOString();
const totalBytes = artifacts.reduce((n, a) => n + a.bytes, 0);
const manifest = {
  product: 'EasyPass',
  version,
  buildNumber,
  versionFull: full,
  generatedAt,
  generator: 'installer/release/collect_artifacts.mjs',
  sha256sumsFile: 'SHA256SUMS.txt',
  artifactCount: artifacts.length,
  totalBytes,
  totalSize: formatBytes(totalBytes),
  artifacts: artifacts.map((a) => ({
    name: a.name,
    kind: a.kind,
    label: a.label,
    platform: a.platform,
    source: show(a.source),
    producedBy: a.producedBy,
    bytes: a.bytes,
    size: a.size,
    sha256: a.sha256,
  })),
};
writeFileSync(join(outDir, 'release-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
log.ok(`已写入 ${show(join(outDir, 'release-manifest.json'))}（${artifacts.length} 个产物，合计 ${formatBytes(totalBytes)}）`);

log.info('校验：Linux `sha256sum -c SHA256SUMS.txt`（在本目录）；Windows `Get-FileHash <文件> -Algorithm SHA256`');
log.info('下一步：node installer/release/generate_release_notes.mjs');

