#!/usr/bin/env node
// EasyPass popup 冒烟测试 —— 用 jsdom 真跑一遍 popup.js（无需浏览器、无需 native host）
//
// 做法：把 popup.html 交给 jsdom 加载（popup.js 真的执行），注入一个假的 `chrome` API：
//   - chrome.i18n.getMessage 从 _locales/zh_CN/messages.json 取值并替换占位符
//   - chrome.runtime.sendMessage 交给一个"假本机宿主"，按 HANDOFF_V21_CONTRACT.md 返回数据
//   - chrome.tabs.query / sendMessage 返回可观测的假 tab
// 然后断言 popup 的关键行为（解锁态渲染 / 填充 / 复制 / 生成器 / 健康 / 锁定）。
//
// 依赖：jsdom（仅开发期需要）。解析顺序：
//   1) 仓库内 node_modules  2) 环境变量 EASYPASS_JSDOM  3) %TEMP%/easypass-smoke/node_modules
//   安装：cd %TEMP% && mkdir easypass-smoke && cd easypass-smoke && npm i jsdom
//   用法：node browser_extension/tools/smoke_popup.mjs
//   退出码：0 = 全通过；1 = 有失败

import { readFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const here = dirname(fileURLToPath(import.meta.url));
const extDir = resolve(here, '..');
const require = createRequire(import.meta.url);

// ─── 定位 jsdom ───────────────────────────────────────────
function loadJsdom() {
  const candidates = [
    null, // 仓库内直接 require
    process.env.EASYPASS_JSDOM,
    join(process.env.TEMP || '', 'easypass-smoke', 'node_modules', 'jsdom'),
    join(process.env.LOCALAPPDATA || '', 'Temp', 'easypass-smoke', 'node_modules', 'jsdom'),
  ].filter(Boolean);
  try {
    return require('jsdom');
  } catch {
    for (const c of candidates) {
      try {
        if (existsSync(c)) return require(c);
      } catch {
        /* try next */
      }
    }
  }
  console.error('❌ 未找到 jsdom。安装后重试：');
  console.error('   cd %TEMP% && mkdir easypass-smoke && cd easypass-smoke && npm i jsdom');
  process.exit(2);
}
const { JSDOM } = loadJsdom();

// ─── 假数据 / 假本机宿主 ──────────────────────────────────
const zh = JSON.parse(readFileSync(join(extDir, '_locales/zh_CN/messages.json'), 'utf8'));
function t(key, args) {
  const entry = zh[key];
  if (!entry) throw new Error(`缺少 i18n 键：${key}`);
  let msg = entry.message;
  const subs = Array.isArray(args) ? args : args === undefined ? [] : [args];
  if (entry.placeholders) {
    let i = 1;
    for (const [name, spec] of Object.entries(entry.placeholders)) {
      const idx = Number(String(spec.content).replace('$', '')) - 1;
      msg = msg.split(`$${name}$`).join(String(subs[idx] ?? ''));
      i++;
    }
  }
  return msg;
}

const ENTRIES = [
  {
    id: 'entry-github',
    name: 'GitHub',
    url: 'https://github.com/login',
    username: 'octocat',
    password: 'S3cret-Pa55!',
    notes: '',
    hasTotp: true,
    isFavorite: false,
  },
  {
    id: 'entry-example',
    name: 'Example Site',
    url: 'https://example.com',
    username: 'user@example.com',
    password: 'hunter2-hunter2',
    notes: '',
    hasTotp: false,
    isFavorite: false,
  },
];

const calls = []; // 记录所有发往"本机宿主"的动作
const tabMessages = []; // 记录发往 content-script 的消息
const copied = []; // 记录剪贴板写入
let hostLocked = false; // 假宿主是有状态的：lock/unlock 会改变后续 getStatus

function fakeHost(request) {
  const { action } = request;
  calls.push(request);
  switch (action) {
    case 'getStatus':
      return {
        connected: true,
        locked: hostLocked,
        entryCount: ENTRIES.length,
        idleTimeoutSeconds: 300,
        autoLockRemainingSeconds: hostLocked ? null : 231,
      };
    case 'unlock':
      hostLocked = false;
      return { success: true };
    case 'lock':
      hostLocked = true;
      return { success: true };
    case 'getAllCredentials':
      return ENTRIES;
    case 'searchCredentials': {
      const q = String(request.query || '').toLowerCase();
      return ENTRIES.filter(
        (e) =>
          e.name.toLowerCase().includes(q) ||
          e.username.toLowerCase().includes(q) ||
          e.url.toLowerCase().includes(q),
      );
    }
    case 'getCredentials': {
      const host = String(request.url || '').replace(/^https?:\/\//, '').split('/')[0];
      return ENTRIES.filter((e) => e.url.includes(host));
    }
    case 'getTotp':
      return { totp: '123456', remaining: 21, period: 30 };
    case 'generatePassword': {
      const o = request.options || {};
      const len = o.length ?? 16;
      const sets = [];
      if (o.useUpper ?? true) sets.push('ABCDEFGHIJKLMNOPQRSTUVWXYZ');
      if (o.useLower ?? true) sets.push('abcdefghijklmnopqrstuvwxyz');
      if (o.useNumbers ?? true) sets.push('0123456789');
      if (o.useSymbols ?? true) sets.push('!@#$%^&*');
      let out = sets.map((s) => s[0]).join('');
      while (out.length < len) out += sets.join('')[out.length % sets.join('').length];
      return { password: out.slice(0, len) };
    }
    case 'getHealthReport':
      return {
        score: 72,
        level: 'fair',
        totalEntries: ENTRIES.length,
        reusedGroupCount: 0,
        weakPasswords: [{ id: 'entry-example', name: 'Example Site', reason: 'commonPassword' }],
        reusedPasswords: [],
        noTotp: [{ id: 'entry-example', name: 'Example Site' }],
        noUrl: [],
      };
    case 'unlock':
      return { success: true };
    case 'lock':
      return { success: true };
    default:
      return { error: `unknown action: ${action}` };
  }
}

// ─── 断言工具 ─────────────────────────────────────────────
const failures = [];
const passes = [];
function check(name, cond, detail = '') {
  if (cond) passes.push(name);
  else failures.push(`${name}${detail ? ' — ' + detail : ''}`);
}
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
const text = (doc) => doc.body.textContent.replace(/\s+/g, ' ');

/** 元素是否真的可见：自身与所有祖先都不能带 hidden 属性。
 *  （textContent 会把 hidden 子树也算进去，不能用它判"看不见"。） */
function isVisible(el) {
  if (!el || !el.isConnected) return false;
  let node = el;
  while (node && node.nodeType === 1) {
    if (node.hasAttribute('hidden')) return false;
    node = node.parentElement;
  }
  return true;
}

/** 按可见文本找元素（button/a/div/span 等） */
function byText(doc, needle, tag = '*') {
  return [...doc.querySelectorAll(tag)].find((el) =>
    (el.textContent || '').replace(/\s+/g, ' ').includes(needle),
  );
}
/** 找可点击的最小元素（自身文本包含关键字且没有更深的包含同关键字的子元素） */
function clickableByText(doc, needle) {
  const all = [...doc.querySelectorAll('button,[role="button"],a,li,div,span,label')];
  const hits = all.filter((el) => (el.textContent || '').includes(needle));
  return hits.length ? hits[hits.length - 1] : null;
}
function click(el) {
  el.dispatchEvent(new el.ownerDocument.defaultView.MouseEvent('click', { bubbles: true }));
}

// ─── 加载 popup ───────────────────────────────────────────
const htmlPath = join(extDir, 'popup/popup.html');
let dom;
try {
  dom = new JSDOM(readFileSync(htmlPath, 'utf8'), {
    url: pathToFileURL(htmlPath).href,
    runScripts: 'dangerously',
    resources: 'usable',
    pretendToBeVisual: true,
    beforeParse(window) {
      window.chrome = {
        i18n: {
          getMessage: (key, args) => {
            try {
              return t(key, args);
            } catch (e) {
              failures.push(`i18n：${e.message}`);
              return `!!${key}!!`;
            }
          },
          getUILanguage: () => 'zh-CN',
        },
        runtime: {
          lastError: undefined,
          getURL: (p) => `chrome-extension://test/${p}`,
          sendMessage: (msg, cb) => {
            const run = async () => {
              await tick(0);
              return fakeHost(msg);
            };
            const p = run();
            if (typeof cb === 'function') {
              p.then(cb);
              return undefined;
            }
            return p;
          },
          onMessage: { addListener: () => {} },
        },
        tabs: {
          query: async () => [{ id: 1, url: 'https://github.com/login' }],
          sendMessage: async (tabId, msg) => {
            tabMessages.push(msg);
            return { success: true, filled: { username: true, password: true, totp: false } };
          },
          create: async () => ({ id: 2 }),
        },
        storage: {
          local: { get: async () => ({}), set: async () => {} },
        },
      };
      Object.defineProperty(window.navigator, 'clipboard', {
        configurable: true,
        value: {
          writeText: async (v) => {
            copied.push(v);
          },
        },
      });
      window.document.execCommand = () => true;
    },
  });
} catch (e) {
  console.error('❌ popup 加载失败：', e.message);
  process.exit(1);
}

const { window } = dom;
const doc = window.document;

// 捕获未处理异常
const pageErrors = [];
window.addEventListener('error', (e) => pageErrors.push(e.message));
window.addEventListener('unhandledrejection', (e) => pageErrors.push(String(e.reason)));
const consoleErrors = [];
const origError = window.console.error;
window.console.error = (...a) => {
  consoleErrors.push(a.map(String).join(' '));
  if (process.env.VERBOSE) origError(...a);
};

await tick(400); // 等脚本执行 + getStatus 往返
await tick(400);

// ─── 断言 ─────────────────────────────────────────────────
check('加载期间无未捕获异常', pageErrors.length === 0, pageErrors.join(' | '));
check('调用了 getStatus', calls.some((c) => c.action === 'getStatus'));
check(
  '解锁态渲染出条目',
  text(doc).includes('GitHub') && text(doc).includes('octocat'),
  text(doc).slice(0, 200),
);
// 解锁表单常驻 DOM（hidden 切换），所以判可见性而不是判存在
check(
  '未误显示解锁界面',
  doc.getElementById('unlockView')?.hidden === true &&
    doc.getElementById('mainView')?.hidden === false,
  `unlockView.hidden=${doc.getElementById('unlockView')?.hidden} mainView.hidden=${doc.getElementById('mainView')?.hidden}`,
);

// 填充：点击 GitHub 条目行 → 应通过 tabs.sendMessage 下发 fillCredentials
{
  const row = doc.querySelector('.entry-item[data-action="fill"]');
  if (row) {
    click(row);
    await tick(300);
  }
  const fill = tabMessages.find((m) => m.action === 'fillCredentials');
  check('点击条目触发 fillCredentials', !!fill);
  if (fill) {
    check(
      '填充内容为该条目凭据',
      fill.credentials?.username === 'octocat' && fill.credentials?.password === 'S3cret-Pa55!',
      JSON.stringify(fill.credentials),
    );
    check(
      'hasTotp 条目随填充下发验证码（走 getTotp 而不是密钥）',
      fill.credentials?.totp === '123456' && calls.some((c) => c.action === 'getTotp'),
      JSON.stringify(fill.credentials),
    );
  }
}

// 复制密码
{
  const before = copied.length;
  const btn =
    doc.querySelector('.entry [data-action="copy-password"]') ||
    [...doc.querySelectorAll('button,[role="button"],span,a')].find((el) => {
      const label = `${el.getAttribute('title') || ''}${el.getAttribute('aria-label') || ''}`;
      return label.includes(t('copyPassword')) || label.includes(t('copyUsername'));
    });
  if (btn) click(btn);
  await tick(200);
  check('复制按钮写入剪贴板', copied.length > before, `copied=${JSON.stringify(copied)}`);
}

// 生成器 tab
{
  const tab = doc.querySelector('.tab[data-tab="generator"]');
  if (tab) click(tab);
  await tick(300);
  check('生成器 tab 调用了 generatePassword', calls.some((c) => c.action === 'generatePassword'));
  const shown = doc.getElementById('genResult')?.textContent?.trim() || '';
  check('生成器显示结果', shown.length >= 8 && shown !== '—', `genResult=${shown}`);
  const regen = doc.getElementById('btnRegenerate');
  if (regen) {
    click(regen);
    await tick(250);
  }
  const genCount = calls.filter((c) => c.action === 'generatePassword').length;
  check('重新生成会再次请求', genCount >= 2, `generatePassword 调用 ${genCount} 次`);
}

// 健康 tab
{
  const tab = doc.querySelector('.tab[data-tab="health"]');
  if (tab) click(tab);
  await tick(300);
  check('健康 tab 调用了 getHealthReport', calls.some((c) => c.action === 'getHealthReport'));
  check('健康 tab 显示分数', text(doc).includes('72'), text(doc).slice(0, 200));
}

// 锁定 → 必须真的切到"已锁定"视图（用户报过"锁定按钮无效"）
{
  const lockBtn = doc.getElementById('btnLock');
  check('解锁态显示锁定按钮', lockBtn && lockBtn.hidden === false, `hidden=${lockBtn?.hidden}`);
  if (lockBtn) click(lockBtn);
  await tick(500);
  check('锁定按钮调用了 lock', calls.some((c) => c.action === 'lock'));
  check(
    '锁定后切到解锁视图',
    doc.getElementById('unlockView')?.hidden === false && doc.getElementById('mainView')?.hidden === true,
    `unlockView.hidden=${doc.getElementById('unlockView')?.hidden} mainView.hidden=${doc.getElementById('mainView')?.hidden}`,
  );
  check('锁定后隐藏锁定按钮', doc.getElementById('btnLock')?.hidden === true);
  check(
    '锁定后条目行不可见',
    !isVisible(doc.querySelector('.entry-item')),
    `entry-item visible=${isVisible(doc.querySelector('.entry-item'))}`,
  );
}

// 重新解锁 → 回到主视图并重新拉取条目
{
  const input = doc.getElementById('masterPassword');
  const unlockBtn = doc.getElementById('btnUnlock');
  if (input && unlockBtn) {
    input.value = 'master-password';
    click(unlockBtn);
    await tick(600);
  }
  check('解锁后回到主视图', doc.getElementById('mainView')?.hidden === false);
  check('解锁后重新渲染条目', text(doc).includes('GitHub'), text(doc).slice(0, 160));
}

check('无 console.error 噪音', consoleErrors.length === 0, consoleErrors.slice(0, 3).join(' | '));

// ─── 输出 ─────────────────────────────────────────────────
console.log('EasyPass popup 冒烟测试（jsdom）');
console.log(`  本机宿主调用：${calls.map((c) => c.action).join(', ') || '（无）'}`);
console.log(`  content-script 消息：${tabMessages.map((m) => m.action).join(', ') || '（无）'}`);
console.log(`  剪贴板写入：${copied.length} 次`);
for (const p of passes) console.log(`  ✅ ${p}`);
for (const f of failures) console.log(`  ❌ ${f}`);
if (failures.length) {
  console.log(`❌ ${failures.length} 项失败 / ${passes.length} 项通过`);
  process.exit(1);
}
console.log(`✅ 全部 ${passes.length} 项通过`);
process.exit(0);
