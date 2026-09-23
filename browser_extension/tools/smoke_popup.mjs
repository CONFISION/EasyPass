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
    type: 'login',
    name: 'GitHub',
    url: 'https://github.com/login',
    username: 'octocat',
    password: 'S3cret-Pa55!',
    notes: '',
    hasTotp: true,
    isFavorite: false,
    customFields: [
      { label: 'PIN', value: '4821', type: 'text' },
      { label: 'Recovery key', value: 'RECOVERY-PLACEHOLDER-9', type: 'hidden' },
    ],
  },
  {
    id: 'entry-example',
    type: 'login',
    name: 'Example Site',
    url: 'https://example.com',
    username: 'user@example.com',
    password: 'hunter2-hunter2',
    notes: '',
    hasTotp: false,
    isFavorite: false,
  },
  {
    id: 'entry-note',
    type: 'secure_note',
    name: 'Note Entry',
    url: '',
    username: '',
    password: '',
    notes: 'Alpha line of the note\nBeta line should stay hidden',
    hasTotp: false,
    isFavorite: false,
  },
  {
    id: 'entry-identity',
    type: 'identity',
    name: 'Identity Entry',
    url: '',
    username: 'alice-account',
    password: '',
    notes: '',
    hasTotp: false,
    isFavorite: false,
    identity: {
      title: 'Ms',
      first_name: 'Alice',
      middle_name: '',
      last_name: 'Nguyen',
      username: 'alice-account',
      company: 'Example Corp',
      email: 'alice@example.com',
      phone: '+1-555-0100',
      id_number: 'ID-PLACEHOLDER-42',
      passport_number: 'P-PLACEHOLDER-7',
      license_number: '',
      address1: '1 Placeholder Road',
      address2: '',
      city: 'Testville',
      state: 'TS',
      postal_code: '00000',
      country: 'Nowhere',
      birthday: '1990-01-01',
      sex: 'F',
    },
  },
  {
    id: 'entry-ssh',
    type: 'ssh_key',
    name: 'SSH Entry',
    url: '',
    username: '',
    password: '',
    notes: '',
    hasTotp: false,
    isFavorite: false,
    sshKey: {
      public_key: 'ssh-ed25519 AAAAPLACEHOLDERPUBLICKEY user@host',
      private_key: 'PRIVATEKEY-PLACEHOLDER-MUST-NOT-AUTOCOPY',
      passphrase: 'PASSPHRASE-PLACEHOLDER',
      fingerprint: 'SHA256:PlaceholderFingerprint1234',
      key_type: 'ssh-ed25519',
      bits: 256,
      comment: 'user@host',
    },
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
      // 成功填充后 popup 会 window.close()（CLOSE_AFTER_FILL_MS）。jsdom 里真的关掉
      // 窗口会让它之后**所有定时器变成空操作**（不报错、只是不再触发），于是搜索
      // 防抖、TOTP 秒表全部静默失效 —— 后续断言会莫名其妙地失败。这里只记录调用，
      // 不真关窗口（真实浏览器里 popup 本来就是用完即关的一次性页面）。
      window.closeCalls = 0;
      window.close = () => {
        window.closeCalls += 1;
      };
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

// ─── 条目类型（协议 3）：徽章 / 图标 / 徽标 / 副标题 / 每类复制动作 ─────────
{
  const rows = [...doc.querySelectorAll('#entryList .entry[data-index]')];
  check('每条条目行带 data-entry-type', rows.length === ENTRIES.length,
    `rows=${rows.length} entries=${ENTRIES.length}`);

  const rowOf = (type) => doc.querySelector(`#entryList .entry[data-entry-type="${type}"]`);
  const typeRows = { login: rowOf('login'), secure_note: rowOf('secure_note'), identity: rowOf('identity'), ssh_key: rowOf('ssh_key') };
  check('四类条目都渲染出条目行',
    Object.values(typeRows).every(Boolean),
    Object.entries(typeRows).map(([k, v]) => `${k}:${!!v}`).join(' '));

  // 类型徽章：文案走 i18n，data-type 与条目类型一致
  const badgeChecks = [
    ['login', t('typeBadgeLogin')],
    ['secure_note', t('typeBadgeSecureNote')],
    ['identity', t('typeBadgeIdentity')],
    ['ssh_key', t('typeBadgeSshKey')],
  ];
  check('每行渲染类型徽章（文案 + data-type 一致）',
    badgeChecks.every(([type, label]) => {
      const badge = rowOf(type)?.querySelector('.entry-type-badge');
      return badge && badge.dataset.type === type && badge.textContent.trim() === label;
    }),
    badgeChecks.map(([type, label]) => {
      const b = rowOf(type)?.querySelector('.entry-type-badge');
      return `${type}=${b ? b.textContent.trim() : 'null'}/${label}`;
    }).join(' '));

  // 类型图标：登录条目沿用品牌图标，其余三类各用类型图标
  check('非登录类型有各自的类型图标',
    rowOf('secure_note')?.querySelector('.entry-icon')?.textContent.trim() === '📝' &&
      rowOf('identity')?.querySelector('.entry-icon')?.textContent.trim() === '🪪' &&
      rowOf('ssh_key')?.querySelector('.entry-icon')?.textContent.trim() === '🗝️',
    ['secure_note', 'identity', 'ssh_key']
      .map((k) => `${k}=${rowOf(k)?.querySelector('.entry-icon')?.textContent.trim()}`).join(' '));
  check('登录条目保留品牌图标',
    (rowOf('login')?.querySelector('.entry-icon')?.textContent.trim() || '').length > 0,
    rowOf('login')?.querySelector('.entry-icon')?.textContent.trim());

  // 副标题逻辑
  const subOf = (type) => rowOf(type)?.querySelector('.entry-subtitle')?.textContent.trim() || '';
  check('login 副标题为用户名', subOf('login') === 'octocat', subOf('login'));
  check('secure_note 副标题取 notes 第一行',
    subOf('secure_note') === 'Alpha line of the note', subOf('secure_note'));
  check('identity 副标题为姓名', subOf('identity') === 'Ms Alice Nguyen', subOf('identity'));
  check('ssh_key 副标题为指纹',
    subOf('ssh_key') === 'SHA256:PlaceholderFingerprint1234', subOf('ssh_key'));

  // 自动填充只认登录条目：其余三类不得出现 fill 钩子
  check('只有登录条目带 data-action="fill"',
    !!rowOf('login')?.querySelector('[data-action="fill"]') &&
      ['secure_note', 'identity', 'ssh_key'].every((k) => !rowOf(k)?.querySelector('[data-action="fill"]')),
    ['secure_note', 'identity', 'ssh_key']
      .map((k) => `${k}=${!!rowOf(k)?.querySelector('[data-action="fill"]')}`).join(' '));
  check('登录条目保留 copy-password / copy-username / copy-url',
    ['copy-password', 'copy-username', 'copy-url']
      .every((a) => !!rowOf('login')?.querySelector(`[data-action="${a}"]`)));

  // 每类至少一个可用的复制动作（点击后真的写入剪贴板）
  const copyOn = async (type, action, expected) => {
    const before = copied.length;
    const btn = rowOf(type)?.querySelector(`[data-action="${action}"]`);
    if (!btn) return { ok: false, why: 'no button' };
    click(btn);
    await tick(120);
    return {
      ok: copied.length > before && copied[copied.length - 1] === expected,
      why: `copied=${JSON.stringify(copied.slice(before))}`,
    };
  };
  const noteCopy = await copyOn('secure_note', 'copy-note', ENTRIES[2].notes);
  check('secure_note 可复制笔记正文', noteCopy.ok, noteCopy.why);
  const nameCopy = await copyOn('identity', 'copy-full-name', 'Ms Alice Nguyen');
  check('identity 可复制姓名', nameCopy.ok, nameCopy.why);
  const mailCopy = await copyOn('identity', 'copy-email', 'alice@example.com');
  check('identity 可复制邮箱', mailCopy.ok, mailCopy.why);
  const phoneCopy = await copyOn('identity', 'copy-phone', '+1-555-0100');
  check('identity 可复制电话', phoneCopy.ok, phoneCopy.why);
  const idCopy = await copyOn('identity', 'copy-id-number', 'ID-PLACEHOLDER-42');
  check('identity 可复制证件号', idCopy.ok, idCopy.why);
  const pubCopy = await copyOn('ssh_key', 'copy-public-key', ENTRIES[4].sshKey.public_key);
  check('ssh_key 可复制公钥', pubCopy.ok, pubCopy.why);
  const fpCopy = await copyOn('ssh_key', 'copy-fingerprint', ENTRIES[4].sshKey.fingerprint);
  check('ssh_key 可复制指纹', fpCopy.ok, fpCopy.why);

  // 安全笔记：正文默认不可见，点开后渲染（含多行）
  const noteRow = rowOf('secure_note');
  check('secure_note 正文默认不渲染',
    !(noteRow?.textContent || '').includes('Beta line should stay hidden'),
    (noteRow?.textContent || '').slice(0, 120));
  click(noteRow.querySelector('[data-action="toggle-note"]'));
  await tick(150);
  const openNoteRows = [...doc.querySelectorAll('.entry-note .note-body')];
  check('secure_note 点开后渲染完整正文',
    openNoteRows.length === 1 && openNoteRows[0].textContent === ENTRIES[2].notes,
    JSON.stringify(openNoteRows.map((n) => n.textContent)));

  // 身份信息：非空字段逐项渲染，字段标签走 i18n
  const identityRow = rowOf('identity');
  const identityText = identityRow?.textContent || '';
  check('identity 渲染姓名与分组标题',
    identityText.includes(t('identityPersonalSection')) &&
      identityText.includes(t('identityContactSection')) &&
      identityText.includes('Alice') && identityText.includes('Nguyen'),
    identityText.slice(0, 160));
  check('identity 渲染邮箱 / 电话 / 证件号及其标签',
    identityText.includes('alice@example.com') && identityText.includes('+1-555-0100') &&
      identityText.includes('ID-PLACEHOLDER-42') &&
      identityText.includes(t('identityEmailLabel')) &&
      identityText.includes(t('identityPhoneLabel')) &&
      identityText.includes(t('identityIdNumberLabel')),
    identityText.slice(0, 240));

  // SSH：指纹渲染在行内，私钥必须显式点击才出现，且永不自动进剪贴板
  const sshRow = rowOf('ssh_key');
  check('ssh_key 行内渲染指纹',
    (sshRow?.textContent || '').includes('SHA256:PlaceholderFingerprint1234'),
    (sshRow?.textContent || '').slice(0, 160));
  check('ssh_key 私钥默认不进入 DOM（含公开钥渲染块）',
    !(sshRow?.textContent || '').includes('PRIVATEKEY-PLACEHOLDER-MUST-NOT-AUTOCOPY'),
    (sshRow?.textContent || '').slice(0, 200));
  check('ssh_key 私钥从未被自动复制',
    !copied.some((v) => v === 'PRIVATEKEY-PLACEHOLDER-MUST-NOT-AUTOCOPY'),
    JSON.stringify(copied));
  const sshBefore = copied.length;
  const privBtn = sshRow.querySelector('[data-action="copy-private-key"]');
  check('ssh_key 复制私钥按钮存在（显式点击才可复制）', !!privBtn);
  if (privBtn) {
    click(privBtn);
    await tick(120);
  }
  check('ssh_key 显式点击后复制私钥',
    copied.length === sshBefore + 1 && copied[copied.length - 1] === 'PRIVATEKEY-PLACEHOLDER-MUST-NOT-AUTOCOPY',
    JSON.stringify(copied.slice(sshBefore)));

  // 自定义字段：默认收起；隐藏类型在被点开前只渲染掩码，不渲染明文
  // （每次渲染都会重建条目 DOM，所以断言前必须重新取一次行节点；
  //   用 data-entry-id 取行 —— 行上的 data-index 是"条目下标"，按钮上的
  //   data-index 是"自定义字段下标"，两个同名属性不能混用）
  const rowOfLogin = () => doc.querySelector('#entryList .entry[data-entry-id="entry-github"]');
  check('条目行带 data-entry-id（稳定钩子）', !!rowOfLogin());
  check('自定义字段默认收起',
    !(rowOfLogin()?.textContent || '').includes('4821'),
    (rowOfLogin()?.textContent || '').slice(0, 200));
  const customToggle = rowOfLogin()?.querySelector('[data-action="toggle-custom"]');
  check('自定义字段有可点开的入口（🧩）', !!customToggle);
  if (customToggle) {
    click(customToggle);
    await tick(150);
  }
  const customText = rowOfLogin()?.textContent || '';
  check('自定义字段展开后渲染普通字段值', customText.includes('4821'), customText.slice(0, 240));
  check('隐藏类型自定义字段在未点开前不渲染明文',
    !customText.includes('RECOVERY-PLACEHOLDER-9') &&
      !!rowOfLogin()?.querySelector('.field-masked[data-field-masked]'),
    customText.slice(0, 240));
  check('隐藏字段的明文在未显示前不进 DOM（含属性）',
    !(rowOfLogin()?.outerHTML || '').includes('RECOVERY-PLACEHOLDER-9'),
    (rowOfLogin()?.outerHTML || '').slice(0, 300));
  check('隐藏字段的复制按钮不带 data-value 明文（只带索引）',
    (() => {
      const maskedField = rowOfLogin()?.querySelector('.field-masked')?.closest('.field');
      const button = maskedField?.querySelector('[data-action="copy-field"]');
      return !!button && !button.dataset.value && button.dataset.field !== undefined;
    })(),
    (rowOfLogin()?.querySelector('.field-masked')?.closest('.field')?.innerHTML || '').slice(0, 200));
  const hiddenCopyBtn = rowOfLogin()?.querySelector('.field-masked')
    ?.closest('.field')?.querySelector('[data-action="copy-field"]');
  if (hiddenCopyBtn) {
    const before = copied.length;
    click(hiddenCopyBtn);
    await tick(150);
    check('未显示也能复制隐藏字段（值从 state 读，不经过 DOM）',
      copied.length > before && copied[copied.length - 1] === 'RECOVERY-PLACEHOLDER-9',
      String(copied[copied.length - 1]));
  }
  const revealBtn = rowOfLogin()?.querySelector('[data-action="toggle-field"]');
  check('隐藏字段有显式显示按钮', !!revealBtn);
  if (revealBtn) {
    click(revealBtn);
    await tick(150);
  }
  check('点击显示后隐藏字段才渲染明文',
    (() => {
      const fresh = rowOfLogin()?.querySelector('[data-action="toggle-field"]');
      return (rowOfLogin()?.textContent || '').includes('RECOVERY-PLACEHOLDER-9') &&
        !!fresh && fresh.getAttribute('aria-label') === t('hideValue');
    })(),
    (rowOfLogin()?.textContent || '').slice(0, 260));
}

// ─── 类型筛选（客户端过滤已加载列表，且要挺过搜索 / 重渲染）───────────────
{
  const chips = [...doc.querySelectorAll('#typeFilter [data-action="filter-type"]')];
  check('类型筛选有 5 个按钮（全部 / 登录 / 安全笔记 / 身份 / SSH）', chips.length === 5,
    chips.map((c) => c.dataset.type).join(','));
  check('筛选按钮带 aria-pressed（默认只有"全部"按下）',
    chips.every((c) => c.hasAttribute('aria-pressed')) &&
      chips.filter((c) => c.getAttribute('aria-pressed') === 'true').length === 1 &&
      doc.querySelector('#typeFilter [data-type="all"]').getAttribute('aria-pressed') === 'true',
    chips.map((c) => `${c.dataset.type}:${c.getAttribute('aria-pressed')}`).join(' '));
  check('筛选按钮文案走 i18n',
    doc.querySelector('#typeFilter [data-type="secure_note"]').textContent.trim() === t('entryTypeSecureNote'),
    doc.querySelector('#typeFilter [data-type="secure_note"]').textContent.trim());

  const visibleTypes = () =>
    [...doc.querySelectorAll('#entryList .entry[data-entry-type]')].map((r) => r.dataset.entryType);
  const chipOf = (type) => doc.querySelector(`#typeFilter [data-type="${type}"]`);

  click(chipOf('identity'));
  await tick(150);
  check('点"身份"后列表只剩 identity 行',
    visibleTypes().length === 1 && visibleTypes()[0] === 'identity',
    visibleTypes().join(','));
  check('筛选后按钮进入按下态',
    chipOf('identity').getAttribute('aria-pressed') === 'true' &&
      chipOf('all').getAttribute('aria-pressed') === 'false',
    `identity=${chipOf('identity').getAttribute('aria-pressed')} all=${chipOf('all').getAttribute('aria-pressed')}`);
  check('筛选后的计数显示 已显示 / 总数',
    doc.getElementById('vaultCount').textContent.trim() === t('entriesCountFiltered', ['1', String(ENTRIES.length)]),
    doc.getElementById('vaultCount').textContent.trim());

  click(chipOf('ssh_key'));
  await tick(150);
  check('切换筛选后列表更新',
    visibleTypes().length === 1 && visibleTypes()[0] === 'ssh_key',
    visibleTypes().join(','));
  check('同时只有一个按钮按下',
    chips.filter((c) => c.getAttribute('aria-pressed') === 'true').length === 1);

  // 搜索（服务端）之后筛选仍要生效：筛选走客户端，不因重新渲染丢失
  click(chipOf('all'));
  await tick(100);
  doc.getElementById('searchInput').value = 'Entry';
  doc.getElementById('searchInput').dispatchEvent(new window.Event('input', { bubbles: true }));
  await tick(500);
  check('搜索请求发往服务端（searchCredentials）',
    calls.some((c) => c.action === 'searchCredentials' && c.query === 'Entry'),
    calls.map((c) => c.action).join(','));
  const searched = ENTRIES.filter((e) => e.name.includes('Entry')).length;
  check('搜索结果渲染所有类型（含笔记 / 身份 / 密钥）',
    searched > 1 && visibleTypes().length === searched,
    `visible=${visibleTypes().join(',')} expected=${searched}`);

  // 筛选把已加载条目全部隐藏时要有空状态，而不是一片空白
  click(chipOf('login'));
  await tick(150);
  check('筛选到没有匹配行时有空状态（而不是空白）',
    visibleTypes().length === 0 &&
      (doc.getElementById('entryList').textContent || '').includes(t('noEntriesForFilter')),
    `visible=${visibleTypes().join(',')} text=${(doc.getElementById('entryList').textContent || '').slice(0, 80)}`);

  click(chipOf('identity'));
  await tick(150);
  check('搜索后再点筛选依然生效（筛选挺过重渲染）',
    visibleTypes().length === 1 && visibleTypes()[0] === 'identity',
    visibleTypes().join(','));
  check('搜索 + 筛选叠加时筛选按钮状态不丢',
    chipOf('identity').getAttribute('aria-pressed') === 'true' &&
      chipOf('all').getAttribute('aria-pressed') === 'false',
    chips.map((c) => `${c.dataset.type}:${c.getAttribute('aria-pressed')}`).join(' '));
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
