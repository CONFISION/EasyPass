#!/usr/bin/env node
// EasyPass popup 追加冒烟测试 —— smoke_popup.mjs 的补充护栏
//
// ─── 与 smoke_popup.mjs 的分工 ────────────────────────────────────────────
// smoke_popup.mjs      ：happy path / 主流程（连接 → 渲染条目 → 填充 → 复制 →
//                        生成器 → 健康 → 锁定 → 解锁），断言"功能还在不在"。
// smoke_popup_extra.mjs：**改版后应当保持的行为**（本文件）——
//                        1) 锁定按钮的反馈契约：点击即乐观切视图 + busy 态，
//                           成功清数据、失败回退且按钮恢复可点、失败原因分级
//                           （staleDaemon / 超时 / 连不上）不折叠成 cannotConnect
//                        2) 旧后台服务（协议版本不符）在各入口的提示是否可读
//                        3) 可访问性（role/aria/键盘）
//                        4) 状态 pill 文案与 DOM 钩子契约（改版时的"别改坏"清单）
// 两者都用 jsdom 真跑 popup.js，互不重叠；改 popup/** 后两条都必须绿。
//
// ─── 依赖与用法 ──────────────────────────────────────────────────────────
// 依赖 jsdom（仅开发期，**不要**加进仓库依赖）。解析顺序与其它脚本一致：
//   1) 仓库内 require('jsdom')
//   2) 环境变量 EASY_PASS_JSDOM / EASYPASS_JSDOM（指向 jsdom 包目录）
//   3) %TEMP%\easypass-smoke\node_modules\jsdom
// 安装：cd %TEMP% && mkdir easypass-smoke && cd easypass-smoke && npm i jsdom
// 用法：node browser_extension/tools/smoke_popup_extra.mjs
// 退出码：0 = 全通过；1 = 有失败；2 = 缺 jsdom（或 popup 无法加载）
// 只读：本脚本不写任何文件、不访问网络、不打印任何凭据（假数据均为占位串）。
// 耗时：约 12s（含一次真实的 6s 锁定超时 + 一次 3.2s 的 getStatus 重试退避）。

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
    process.env.EASY_PASS_JSDOM,
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

// ─── i18n（读 zh_CN，让断言与界面文案一致而不是硬编码字符串）────────────
const zh = JSON.parse(readFileSync(join(extDir, '_locales/zh_CN/messages.json'), 'utf8'));
function t(key, args) {
  const entry = zh[key];
  if (!entry) throw new Error(`缺少 i18n 键：${key}`);
  let message = entry.message;
  const subs = Array.isArray(args) ? args : args === undefined ? [] : [args];
  if (entry.placeholders) {
    for (const [name, spec] of Object.entries(entry.placeholders)) {
      const idx = Number(String(spec.content).replace('$', '')) - 1;
      message = message.split(`$${name}$`).join(String(subs[idx] ?? ''));
    }
  }
  return message;
}

// ─── 假数据（占位串，不是真实凭据）────────────────────────
const ENTRIES = [
  {
    id: 'e1',
    name: 'GitHub',
    url: 'https://github.com/login',
    username: 'octocat',
    password: 'fake-placeholder-value',
    notes: '',
    hasTotp: false,
    isFavorite: false,
  },
];

const failures = [];
const passes = [];
function check(name, cond, detail = '') {
  if (cond) passes.push(name);
  else failures.push(`${name}${detail ? ' — ' + detail : ''}`);
}
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

/** 载入 popup 并注入可编程假宿主；handlers 按 action 覆盖默认行为。 */
async function boot(handlers = {}) {
  const calls = [];
  let hostLocked = false;

  const defaultHost = (req) => {
    switch (req.action) {
      case 'getStatus':
        return {
          connected: true,
          locked: hostLocked,
          entryCount: ENTRIES.length,
          idleTimeoutSeconds: 300,
          autoLockRemainingSeconds: hostLocked ? null : 231,
        };
      case 'getAllCredentials':
        return ENTRIES;
      case 'getCredentials':
        return ENTRIES;
      case 'generatePassword':
        return { password: 'Placeholder-123456' };
      case 'getHealthReport':
        return {
          score: 72,
          level: 'fair',
          totalEntries: 1,
          reusedGroupCount: 0,
          weakPasswords: [],
          reusedPasswords: [],
          noTotp: [],
          noUrl: [],
        };
      case 'lock':
        hostLocked = true;
        return { success: true };
      case 'unlock':
        hostLocked = false;
        return { success: true };
      default:
        return { error: `unknown action: ${req.action}` };
    }
  };
  const host = (req) => {
    calls.push(req);
    const custom = handlers[req.action];
    return custom ? custom(req) : defaultHost(req);
  };

  const htmlPath = join(extDir, 'popup/popup.html');
  const dom = new JSDOM(readFileSync(htmlPath, 'utf8'), {
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
              return '';
            }
          },
          getUILanguage: () => 'zh-CN',
        },
        runtime: {
          lastError: undefined,
          getURL: (p) => `chrome-extension://test/${p}`,
          sendMessage: (msg, cb) => {
            const p = (async () => {
              await tick(0);
              return host(msg);
            })();
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
          sendMessage: async () => ({ success: true, filled: { username: true, password: true, totp: false } }),
          create: async () => ({ id: 2 }),
        },
        storage: { local: { get: async () => ({}), set: async () => {} } },
      };
      Object.defineProperty(window.navigator, 'clipboard', {
        configurable: true,
        value: { writeText: async () => {} },
      });
      window.document.execCommand = () => true;
      // 成功填充后 popup 会 window.close()。jsdom 里真关窗口会让它之后所有定时器
      // 变成空操作（不报错、只是不再触发），把同一进程里后续的断言一起带坏；
      // 这里只记录调用，不真关窗口。
      window.closeCalls = 0;
      window.close = () => {
        window.closeCalls += 1;
      };
    },
  });

  const { window } = dom;
  const errors = [];
  window.addEventListener('error', (e) => errors.push(e.message));
  window.addEventListener('unhandledrejection', (e) => errors.push(String(e.reason)));
  const consoleErrors = [];
  const origError = window.console.error;
  window.console.error = (...a) => {
    consoleErrors.push(a.map(String).join(' '));
    if (process.env.VERBOSE) origError(...a);
  };

  await tick(400); // 等脚本执行 + getStatus 往返
  await tick(400);
  return { dom, window, doc: window.document, calls, errors, consoleErrors };
}

const click = (el) =>
  el.dispatchEvent(new el.ownerDocument.defaultView.MouseEvent('click', { bubbles: true }));
const toastState = (doc) => {
  const toast = doc.getElementById('toast');
  return {
    hidden: toast ? toast.hidden : null,
    cls: (toast && toast.className) || '',
    text: (doc.getElementById('toastText') || {}).textContent || '',
    detail: (doc.getElementById('toastDetail') || {}).textContent || '',
  };
};

// ─── 1) 锁定失败 · 旧后台服务（staleDaemon）───────────────────────────────
// 点击必须立刻有反馈（乐观切视图 + busy），失败必须回退、按钮恢复可点、
// 且原因要说是"服务版本过旧、请重启"，不能折叠成"无法连接"。
{
  const { doc, calls, errors, consoleErrors } = await boot({ lock: () => ({ error: 'staleDaemon' }) });
  const lockBtn = doc.getElementById('btnLock');
  check('1.0 初始为解锁态主视图', doc.getElementById('mainView').hidden === false);
  click(lockBtn);
  // 假宿主几乎瞬时返回，所以"进行中"必须在点击后同步断言
  // （lockVault 在第一个 await 之前就已经乐观切视图 + 进入 busy）。
  const during = {
    unlockVisible: doc.getElementById('unlockView').hidden === false,
    mainHidden: doc.getElementById('mainView').hidden === true,
    busy: lockBtn.classList.contains('is-busy'),
    disabled: lockBtn.disabled,
    label: doc.getElementById('btnLockLabel').textContent,
  };
  check('1.1 点击后立刻切到锁定视图（乐观反馈）', during.unlockVisible && during.mainHidden,
    JSON.stringify(during));
  check('1.2 点击后立刻进入 busy 态', during.busy && during.disabled, JSON.stringify(during));
  check('1.3 busy 时按钮文案切到 loading', during.label === t('loading'), during.label);
  await tick(600);
  const toast = toastState(doc);
  check('1.4 lock 已发给本机宿主', calls.some((c) => c.action === 'lock'));
  check('1.5 失败后回退到主视图',
    doc.getElementById('mainView').hidden === false && doc.getElementById('unlockView').hidden === true,
    `main=${doc.getElementById('mainView').hidden} unlock=${doc.getElementById('unlockView').hidden}`);
  check('1.6 失败后锁定按钮恢复可点',
    lockBtn.disabled === false && !lockBtn.classList.contains('is-busy') && lockBtn.hidden === false,
    `disabled=${lockBtn.disabled} busy=${lockBtn.classList.contains('is-busy')} hidden=${lockBtn.hidden}`);
  check('1.7 文案优先显示 staleDaemon 而不是 cannotConnect',
    toast.text === t('staleDaemon'), JSON.stringify(toast));
  check('1.8 给出 restartApp 指引', toast.detail === t('restartApp'), toast.detail);
  check('1.9 错误 toast 用 error 色调', toast.cls.includes('toast-error'), toast.cls);
  check('1.10 回退不丢数据（条目仍在）', doc.body.textContent.includes('GitHub'));
  check('1.11 无未捕获异常 / 无 console.error 噪音',
    errors.length === 0 && consoleErrors.length === 0,
    `${errors.join('|')} ${consoleErrors.join('|')}`);
}

// ─── 2) 锁定失败 · 超时（宿主不回）────────────────────────────────────────
{
  const { doc, errors } = await boot({ lock: () => new Promise(() => {}) });
  const lockBtn = doc.getElementById('btnLock');
  click(lockBtn);
  await tick(400);
  check('2.1 等待期间仍是锁定视图 + busy',
    doc.getElementById('unlockView').hidden === false && lockBtn.classList.contains('is-busy'));
  await tick(6400); // LOCK_TIMEOUT_MS = 6000
  const toast = toastState(doc);
  check('2.2 超时后回退到主视图', doc.getElementById('mainView').hidden === false);
  check('2.3 超时文案为 requestTimedOut', toast.text === t('requestTimedOut'), JSON.stringify(toast));
  check('2.4 超时后按钮可点', lockBtn.disabled === false && lockBtn.hidden === false);
  check('2.5 超时路径无未捕获异常', errors.length === 0, errors.join('|'));
}

// ─── 3) 锁定失败 · 普通错误 ───────────────────────────────────────────────
{
  const { doc } = await boot({ lock: () => ({ error: 'boom-failure' }) });
  click(doc.getElementById('btnLock'));
  await tick(600);
  const toast = toastState(doc);
  check('3.1 普通错误回退到主视图', doc.getElementById('mainView').hidden === false);
  check('3.2 标题 cannotConnect', toast.text === t('cannotConnect'), JSON.stringify(toast));
  check('3.3 detail 保留原始错误便于排查', toast.detail === 'boom-failure', toast.detail);
}

// ─── 4) 锁定成功 ──────────────────────────────────────────────────────────
// 必须真的切到锁定视图、隐藏锁定按钮、清掉条目 DOM、给出成功反馈，
// 且不要追加一次多余的 getStatus（会让乐观视图闪回）。
{
  const { doc, calls, errors } = await boot();
  click(doc.getElementById('btnLock'));
  await tick(600);
  const toast = toastState(doc);
  check('4.1 成功后切到解锁视图',
    doc.getElementById('unlockView').hidden === false && doc.getElementById('mainView').hidden === true);
  check('4.2 成功后锁定按钮隐藏', doc.getElementById('btnLock').hidden === true);
  check('4.3 成功 toast 为 vaultLocked + success 色调',
    toast.text === t('vaultLocked') && toast.cls.includes('toast-success'), JSON.stringify(toast));
  check('4.4 成功后清空条目 DOM（不留明文）', doc.querySelector('.entry-item') === null);
  check('4.5 成功后没有多余的 getStatus 轮询',
    calls.filter((c) => c.action === 'getStatus').length === 1,
    calls.map((c) => c.action).join(','));
  check('4.6 无异常', errors.length === 0, errors.join('|'));
}

// ─── 5) 健康页遇到旧后台服务 ──────────────────────────────────────────────
{
  const { doc } = await boot({ getHealthReport: () => ({ error: 'staleDaemon' }) });
  click(doc.querySelector('.tab[data-tab="health"]'));
  await tick(500);
  const body = doc.getElementById('healthBody').textContent;
  check('5.1 健康页显示 staleDaemon 标题', body.includes(t('staleDaemon')), body.slice(0, 160));
  check('5.2 健康页给出 restartApp 指引', body.includes(t('restartApp')), body.slice(0, 200));
  check('5.3 不再统一折叠为 cannotConnect', !body.includes(t('cannotConnect')), body.slice(0, 160));
}

// ─── 6) 可访问性 ──────────────────────────────────────────────────────────
{
  const { doc, window } = await boot();
  const tabBar = doc.getElementById('tabBar');
  const tabs = [...doc.querySelectorAll('.tab[data-tab]')];
  check('6.1 tablist 角色与段数', tabBar.getAttribute('role') === 'tablist' && tabs.length === 3);
  check('6.2 tab 角色 + aria-selected 唯一',
    tabs.every((b) => b.getAttribute('role') === 'tab') &&
      tabs.filter((b) => b.getAttribute('aria-selected') === 'true').length === 1);
  check('6.3 tab 与面板 aria-controls 关联',
    tabs.every((b) => b.getAttribute('aria-controls') && doc.getElementById(b.getAttribute('aria-controls'))));
  check('6.4 锁定按钮 aria-label 走 i18n',
    doc.getElementById('btnLock').getAttribute('aria-label') === t('lock'),
    doc.getElementById('btnLock').getAttribute('aria-label'));
  check('6.5 解锁输入框有关联 label', !!doc.querySelector('label[for="masterPassword"]'));
  tabBar.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
  await tick(400);
  check('6.6 方向键切换 tab',
    doc.querySelector('.tab[data-tab="generator"]').getAttribute('aria-selected') === 'true',
    tabs.map((b) => `${b.dataset.tab}:${b.getAttribute('aria-selected')}`).join(','));
}

// ─── 7) 状态 pill ─────────────────────────────────────────────────────────
{
  const { doc } = await boot();
  check('7.1 连接态 pill 文案', doc.getElementById('statusText').textContent === t('connected'),
    doc.getElementById('statusText').textContent);
  check('7.2 状态点 title 提供细节（如自动锁定倒计时）',
    (doc.getElementById('statusDot').title || '').length > 0);
  click(doc.getElementById('btnLock'));
  await tick(600);
  check('7.3 锁定后 pill 文案切换', doc.getElementById('statusText').textContent === t('lock'),
    doc.getElementById('statusText').textContent);
  check('7.4 statusDot 仍用契约类名 status locked',
    doc.getElementById('statusDot').className === 'status locked',
    doc.getElementById('statusDot').className);
}

// ─── 8) 真实 background.js 的 staleDaemon 形态 ────────────────────────────
// background.js 把错误拼成 "<staleDaemon> — <restartApp>" 整句；
// 老版本只会说 unknownAction 模板文案。两种都必须识别成 staleDaemon。
{
  const compound = `${t('staleDaemon')} — ${t('restartApp')}`;
  const { doc } = await boot({ lock: () => ({ error: compound }) });
  click(doc.getElementById('btnLock'));
  await tick(600);
  const toast = toastState(doc);
  check('8.1 本地化整句识别为 staleDaemon（标题不重复细节）',
    toast.text === t('staleDaemon') && toast.detail === t('restartApp'), JSON.stringify(toast));
  check('8.2 不误报 cannotConnect', toast.text !== t('cannotConnect'), toast.text);
  check('8.3 失败后仍回退主视图', doc.getElementById('mainView').hidden === false);
}
{
  const { doc } = await boot({ lock: () => ({ error: t('unknownAction', ['lock']) }) });
  click(doc.getElementById('btnLock'));
  await tick(600);
  const toast = toastState(doc);
  check('8.4 旧 unknownAction 文案也识别为 staleDaemon',
    toast.text === t('staleDaemon') && toast.detail === t('restartApp'), JSON.stringify(toast));
}
{
  // 旧 daemon 在 getStatus 阶段就被识别 → 错误视图（而不是"无法连接"）
  const { doc } = await boot({ getStatus: () => ({ error: `${t('staleDaemon')} — ${t('restartApp')}` }) });
  await tick(3200); // refreshStatus 重试 3 次、间隔 1.2s 后才落错误视图
  const title = doc.getElementById('errorTitle').textContent;
  const detail = doc.getElementById('errorDetail').textContent;
  check('8.5 getStatus 阶段旧服务 → 错误页显示 staleDaemon', title === t('staleDaemon'), title);
  check('8.6 错误页给出 restartApp 指引', detail === t('restartApp'), detail);
  check('8.7 错误页提供"刷新"重试按钮',
    !!doc.getElementById('btnRetry') && doc.getElementById('btnRetry').hidden !== true);
}

// ─── 9) DOM 钩子契约（改版护栏：这些被删/改名会让冒烟网失效）──────────────
{
  const { doc } = await boot();
  const has = (sel) => !!doc.querySelector(sel);
  check('9.1 状态点 / 锁定按钮 / 四个视图容器',
    has('#statusDot') && has('#btnLock') && has('#loadingView') && has('#errorView') &&
      has('#unlockView') && has('#mainView'));
  check('9.2 三段 tab 的 data-tab 契约',
    ['vault', 'generator', 'health'].every((k) => has(`.tab[data-tab="${k}"]`)));
  check('9.3 条目填充钩子 #entryList + .entry-item[data-action="fill"]',
    has('#entryList') && has('.entry-item[data-action="fill"]'));
  check('9.4 复制密码钩子 .entry [data-action="copy-password"]',
    has('.entry [data-action="copy-password"]'));
  check('9.5 生成器钩子 #genResult / #btnRegenerate / #btnCopyGenerated',
    has('#genResult') && has('#btnRegenerate') && has('#btnCopyGenerated'));
  check('9.6 解锁钩子 #masterPassword / #btnUnlock / #unlockError',
    has('#masterPassword') && has('#btnUnlock') && has('#unlockError'));
  check('9.7 toast 钩子 #toast / #toastText / #toastDetail',
    has('#toast') && has('#toastText') && has('#toastDetail'));
  check('9.8 滚动容器 #content 保留', has('#content'));
  // 视图切换必须走 hidden 属性（冒烟脚本沿祖先链判可见性，display 会误判）
  check('9.9 视图切换使用 hidden 属性',
    doc.getElementById('loadingView').hidden === true &&
      doc.getElementById('mainView').hasAttribute('hidden') === false);
  // 类型筛选钩子：静态按钮组 + data-type 常量（filter-type 动作）
  const chips = [...doc.querySelectorAll('#typeFilter [data-action="filter-type"]')];
  check('9.10 类型筛选钩子 #typeFilter + [data-action="filter-type"][data-type]',
    has('#typeFilter') && chips.length === 5 &&
      ['all', 'login', 'secure_note', 'identity', 'ssh_key']
        .every((v) => has(`#typeFilter [data-type="${v}"]`)),
    chips.map((c) => c.dataset.type).join(','));
  // 非登录条目只拿到 copy-* 动作，绝不出现 fill（自动填充只认登录条目）
  check('9.11 非登录类型没有 fill 钩子（登录条目保留）',
    has('.entry[data-entry-type="login"] .entry-item[data-action="fill"]') &&
      !has('.entry[data-entry-type="identity"] [data-action="fill"]'));
  check('9.12 条目行带 data-entry-type / data-entry-id 供测试定位',
    has('.entry[data-entry-type="login"][data-entry-id]'));
}

// ─── 输出 ─────────────────────────────────────────────────────────────────
console.log('EasyPass popup 追加冒烟测试（失败路径 / a11y / DOM 契约）');
for (const p of passes) console.log(`  ✅ ${p}`);
for (const f of failures) console.log(`  ❌ ${f}`);
if (failures.length) {
  console.log(`❌ ${failures.length} 项失败 / ${passes.length} 项通过`);
  process.exit(1);
}
console.log(`✅ 全部 ${passes.length} 项通过`);
// popup 自身挂着 setInterval（自动锁定倒计时 / TOTP 秒表），必须显式退出。
process.exit(0);
