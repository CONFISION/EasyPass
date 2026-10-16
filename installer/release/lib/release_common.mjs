// EasyPass 发布脚本共用工具（零依赖：只用 node 内置模块）
//
// 两个脚本（collect_artifacts.mjs / generate_release_notes.mjs）共用的东西只有三样：
// 版本号读取、字节格式化、控制台输出。放在这里是为了让"版本号只有一个读法"。
//
// 版本号的唯一来源是 pubspec.yaml —— 读法与 installer/appimage/build_appimage.sh 保持一致
// （那支脚本用 awk 取 `version:` 的值，再砍掉 `+build` 号）。发布脚本里**不写死版本号**：
// 版本一变，这里跟着变，不需要改脚本。

import { existsSync, readFileSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

/** installer/release/ */
export const releaseDir = resolve(here, '..');
/** 仓库根 */
export const repoRoot = resolve(releaseDir, '..', '..');

/**
 * 统一的前缀输出：`[ok]` / `[warn]` / `[fail]` …… 便于在 CI 日志里 grep。
 * 一律走 **stderr**：stdout 只留给"机器要的载荷"（例如 generate_release_notes.mjs --dry-run 的文档），
 * 这样 `node … --dry-run > notes.md` 得到的是一份干净的 Markdown。
 */
const emit = (tag) => (m) => console.error(`${tag} ${m}`);

export const log = {
  info: emit('[info]'),
  ok: emit('[ok]  '),
  warn: emit('[warn]'),
  fail: emit('[fail]'),
  note: emit('[note]'),
  dry: emit('[dry] '),
};

/** 环境 / 参数错误：写 stderr 后退出（默认 2，与仓库里其它 node 工具一致）。 */
export function die(message, code = 2) {
  console.error(`[fail] ${message}`);
  process.exit(code);
}

/** 仓库内路径显示为相对路径 + 正斜杠（Windows 上也能直接贴进文档与 CI 日志）；仓库外的绝对路径原样显示。 */
export function show(p) {
  const rel = relative(repoRoot, p);
  if (!rel || rel.startsWith('..')) return p.replace(/\\/g, '/');
  return rel.replace(/\\/g, '/');
}

/** 12345678 → "11.8 MiB"（与 build_extension_zip.mjs 一样用 1024 进制）。 */
export function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KiB', 'MiB', 'GiB'];
  let n = bytes / 1024;
  let i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i += 1;
  }
  return `${n.toFixed(1)} ${units[i]}`;
}

/**
 * 读 pubspec.yaml 里的 `version: x.y.z+build`。
 * 解析不出来直接退出（2）—— 版本号宁可报错也不能猜。
 * @returns {{version: string, buildNumber: string, full: string}}
 */
export function readVersion() {
  const pubspecPath = resolve(repoRoot, 'pubspec.yaml');
  if (!existsSync(pubspecPath)) die(`找不到 pubspec.yaml：${pubspecPath}`);
  const m = /^version:\s*([^\s#]+)/m.exec(readFileSync(pubspecPath, 'utf8'));
  if (!m) die('无法从 pubspec.yaml 读出 version（期望形如 `version: 2.3.3+13`）');
  const full = m[1];
  const [version, buildNumber = ''] = full.split('+');
  if (!/^\d+\.\d+\.\d+$/.test(version)) die(`pubspec.yaml 的 version 不是 x.y.z（+build）形式：${full}`);
  return { version, buildNumber, full };
}

/** 不区分大小写的路径比较（Windows 用；Linux 上路径本身区分大小写，所以只在 win32 上归一化）。 */
export function samePath(a, b) {
  const norm = (p) => {
    const r = resolve(p);
    return process.platform === 'win32' ? r.toLowerCase() : r;
  };
  return norm(a) === norm(b);
}

/** child 是否在 parent 目录内（含自身）。 */
export function isInside(child, parent) {
  const sep = process.platform === 'win32' ? '\\' : '/';
  const norm = (p) => {
    const r = resolve(p);
    return process.platform === 'win32' ? r.toLowerCase() : r;
  };
  const c = norm(child);
  const p = norm(parent);
  return c === p || c.startsWith(p.endsWith(sep) ? p : p + sep);
}

/**
 * 极简参数解析：
 *   'bool'  → `--flag`
 *   'value' → `--flag value`（重复给出即报错，避免"后一个静默覆盖前一个"）
 *   'list'  → `--flag value` 可重复，收进 multi（值里可以带逗号，如路径）
 * 未知参数直接报错退出（2）—— 打错参数却按默认值静默跑起来是发布脚本最不该有的行为。
 *
 * @param {string[]} argv process.argv.slice(2)
 * @param {Record<string, 'bool'|'value'|'list'>} spec
 * @returns {{flags: Set<string>, values: Map<string, string>, multi: Map<string, string[]>}}
 */
export function parseArgs(argv, spec) {
  const flags = new Set();
  const values = new Map();
  const multi = new Map();
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) die(`无法识别的参数：${arg}（--help 看用法）`);
    const name = arg.slice(2);
    const kind = spec[name];
    if (!kind) die(`未知参数：${arg}（--help 看用法）`);
    if (kind === 'bool') {
      flags.add(name);
      continue;
    }
    const value = argv[i + 1];
    if (value === undefined || value.startsWith('--')) die(`--${name} 需要一个参数值`);
    if (kind === 'list') {
      multi.set(name, [...(multi.get(name) || []), value]);
    } else {
      if (values.has(name)) die(`--${name} 重复给出（只接受一个值）`);
      values.set(name, value);
    }
    i += 1;
  }
  return { flags, values, multi };
}
