#!/usr/bin/env node
// EasyPass content-script 冒烟测试 —— 用 jsdom 真跑一遍 content-script.js（无需浏览器）
//
// 覆盖：字段内联图标注入 → 点击取匹配条目 → 0/1/多条 三条路径 → 填充（含 input 事件）
//       → popup 下发的 fillCredentials → 无密码框页面必须完全静默。
//
// 注意：jsdom 不做布局，`offsetParent` 恒为 null、`getBoundingClientRect` 恒为 0，
//       所以本脚本会把这些"可见性"API 打桩成"可见"，否则被测代码的可见性判断会误杀。
//
// 依赖：jsdom（同 smoke_popup.mjs）。用法：node browser_extension/tools/smoke_content.mjs

import { readFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const here = dirname(fileURLToPath(import.meta.url));
const extDir = resolve(here, '..');
const require = createRequire(import.meta.url);

function loadJsdom() {
  const candidates = [
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
        /* next */
      }
    }
  }
  console.error('❌ 未找到 jsdom。安装：cd %TEMP% && mkdir easypass-smoke && cd easypass-smoke && npm i jsdom');
  process.exit(2);
}
const { JSDOM } = loadJsdom();

const zh = JSON.parse(readFileSync(join(extDir, '_locales/zh_CN/messages.json'), 'utf8'));
function t(key, args) {
  const entry = zh[key];
  if (!entry) throw new Error(`缺少 i18n 键：${key}`);
  let msg = entry.message;
  const subs = Array.isArray(args) ? args : args === undefined ? [] : [args];
  if (entry.placeholders) {
    for (const [name, spec] of Object.entries(entry.placeholders)) {
      const idx = Number(String(spec.content).replace('$', '')) - 1;
      msg = msg.split(`$${name}$`).join(String(subs[idx] ?? ''));
    }
  }
  return msg;
}

const PAGE_URL = 'https://accounts.example.com/login';
const ENTRIES = [
  {
    id: 'e1',
    name: 'Example Account',
    url: 'https://example.com',
    username: 'alice@example.com',
    password: 'P@ssw0rd-example',
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

const LOGIN_PAGE = `<!DOCTYPE html><html><body>
  <h1>Sign in</h1>
  <form id="login">
    <input id="user" name="username" type="text" autocomplete="username">
    <input id="pass" name="password" type="password" autocomplete="current-password">
    <button type="submit">Sign in</button>
  </form>
</body></html>`;

const NO_FORM_PAGE = `<!DOCTYPE html><html><body><h1>No login here</h1><input id="search" type="text"></body></html>`;

/** 建立一次"页面 + 注入 content-script"的环境 */
async function bootPage(html, { url = PAGE_URL, entries = ENTRIES, locked = false } = {}) {
  const state = {
    hostCalls: [],
    contentListener: null,
    entries,
    locked,
    events: [],
  };
  const dom = new JSDOM(html, {
    url,
    runScripts: 'dangerously',
    pretendToBeVisual: true,
    beforeParse(window) {
      // 让 jsdom 的"不可见"字段看起来可见（见文件头注释）
      Object.defineProperty(window.HTMLElement.prototype, 'offsetParent', {
        configurable: true,
        get() {
          return this.parentElement || this.ownerDocument.body;
        },
      });
      window.HTMLElement.prototype.getBoundingClientRect = function () {
        return { x: 0, y: 0, top: 0, left: 0, right: 100, bottom: 24, width: 100, height: 24 };
      };
      window.HTMLElement.prototype.checkVisibility = function () {
        return true;
      };

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
            const p = (async () => {
              await tick(0);
              state.hostCalls.push(msg);
              switch (msg.action) {
                case 'getStatus':
                  return { connected: true, locked: state.locked, entryCount: state.entries.length };
                case 'getCredentials':
                  return state.entries;
                case 'getTotp':
                  return { totp: '654321', remaining: 12, period: 30 };
                default:
                  return { error: `unknown action: ${msg.action}` };
              }
            })();
            if (typeof cb === 'function') {
              p.then(cb);
              return undefined;
            }
            return p;
          },
          onMessage: {
            addListener: (fn) => {
              state.contentListener = fn;
            },
          },
        },
      };
    },
  });

  const { window } = dom;
  // 记录 input/change 事件，验证填充是否派发（React 受控组件依赖）
  window.document.addEventListener('input', (e) => {
    state.events.push(`input:${e.target.id || e.target.name}`);
  });
  window.document.addEventListener('change', (e) => {
    state.events.push(`change:${e.target.id || e.target.name}`);
  });

  // 注入被测脚本（等价于扩展在页面里执行 content-script.js）
  const scriptEl = window.document.createElement('script');
  scriptEl.textContent = readFileSync(join(extDir, 'content-script.js'), 'utf8');
  window.document.body.appendChild(scriptEl);
  await tick(300);
  await tick(300);
  // 脚本已执行；把 <script> 节点移出 DOM，否则它的源码会污染 textContent 断言
  scriptEl.remove();
  return { dom, window, doc: window.document, state };
}

/** 在页面里找 EasyPass 注入的元素（class 前缀 easypass-） */
function injectedNodes(doc) {
  return [...doc.querySelectorAll('[class*="easypass" i], [data-easypass], [id*="easypass" i]')];
}
function clickEl(window, el) {
  el.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }));
}

// ─── 场景 1：有登录表单 ───────────────────────────────────
{
  const { window, doc, state } = await bootPage(LOGIN_PAGE);

  const nodes = injectedNodes(doc);
  check('在密码框注入 EasyPass 图标/节点', nodes.length > 0, `注入节点数=${nodes.length}`);

  // 点击图标 → 取匹配条目 → 填充
  const icon = nodes.find((n) => n !== doc.body) || nodes[0];
  if (icon) {
    clickEl(window, icon);
    await tick(400);
  }
  check(
    '点击图标按当前地址取凭据',
    state.hostCalls.some((c) => c.action === 'getCredentials'),
    JSON.stringify(state.hostCalls.map((c) => c.action)),
  );

  const user = doc.getElementById('user');
  const pass = doc.getElementById('pass');
  check('填充用户名', user && user.value === 'alice@example.com', `实际=${user && user.value}`);
  check('填充密码', pass && pass.value === 'P@ssw0rd-example', `实际=${pass && pass.value}`);
  check(
    '派发 input 事件（React/Vue 兼容）',
    state.events.includes('input:user') && state.events.includes('input:pass'),
    state.events.join(','),
  );
}

// ─── 场景 2：popup 下发的 fillCredentials ─────────────────
{
  const { window, doc, state } = await bootPage(LOGIN_PAGE);
  check('注册了运行时消息监听器', typeof state.contentListener === 'function');
  if (typeof state.contentListener === 'function') {
    const sent = [];
    state.contentListener(
      { action: 'fillCredentials', credentials: { username: 'bob', password: 'bob-pass-123' } },
      {},
      (resp) => sent.push(resp),
    );
    await tick(200);
    const user = doc.getElementById('user');
    const pass = doc.getElementById('pass');
    check('popup 填充消息生效', user?.value === 'bob' && pass?.value === 'bob-pass-123', `u=${user?.value} p=${pass?.value}`);
    check('填充消息返回 success', sent.some((r) => r && r.success === true), JSON.stringify(sent));
  }
}

// ─── 场景 3：无密码框页面必须静默 ─────────────────────────
{
  const { doc, state } = await bootPage(NO_FORM_PAGE, { url: 'https://example.com/search' });
  await tick(200);
  check('无密码框页面不注入任何节点', injectedNodes(doc).length === 0, `注入节点数=${injectedNodes(doc).length}`);
  check('无密码框页面不打扰本机宿主', state.hostCalls.length === 0, JSON.stringify(state.hostCalls.map((c) => c.action)));
}

// ─── 场景 4：锁定态点击图标 → 提示而不是填充 ───────────────
{
  const { window, doc } = await bootPage(LOGIN_PAGE, { locked: true });
  const nodes = injectedNodes(doc);
  if (nodes.length) {
    clickEl(window, nodes[0]);
    await tick(400);
  }
  const user = doc.getElementById('user');
  check('锁定态不填充', !user || user.value === '', `实际=${user && user.value}`);
  check(
    '锁定态给出提示',
    doc.body.textContent.includes(t('contentLockedHint')) ||
      doc.body.textContent.includes(t('vaultLocked')),
    doc.body.textContent.slice(0, 200),
  );
}

// ─── 场景 5：多条匹配 → 出现选择列表 ──────────────────────
{
  const two = [
    ENTRIES[0],
    { ...ENTRIES[0], id: 'e2', name: 'Work Account', username: 'alice@work.example.com' },
  ];
  const { window, doc } = await bootPage(LOGIN_PAGE, { entries: two });
  const nodes = injectedNodes(doc);
  if (nodes.length) {
    clickEl(window, nodes[0]);
    await tick(400);
  }
  const body = doc.body.textContent;
  check(
    '多条匹配时给出选择',
    body.includes('Work Account') || body.includes(t('contentMultiple')),
    body.slice(0, 200),
  );
  // 选择第二条 → 应填入 work 账号
  const option = [...doc.querySelectorAll('*')].find(
    (el) => el.children.length === 0 && (el.textContent || '').includes('Work Account'),
  );
  if (option) {
    clickEl(window, option);
    await tick(300);
    const user = doc.getElementById('user');
    check('选择后填入所选条目', user?.value === 'alice@work.example.com', `实际=${user?.value}`);
  }
}

// ─── 场景 6：空 frame 对 fillCredentials 必须保持沉默（iframe 抢答回归）──
// popup 不带 frameId 广播 fillCredentials 时，只有"第一个响应"会被采用。
// 没有登录框的 frame 若抢先回 {success:false}，popup 会把填好的页面误判为
// "受限页面"并去复制密码 —— 所以这类 frame 必须完全不响应。
{
  const { state } = await bootPage(NO_FORM_PAGE, { url: 'https://example.com/other' });
  if (typeof state.contentListener === 'function') {
    const sent = [];
    const keepChannel = state.contentListener(
      { action: 'fillCredentials', credentials: { username: 'a', password: 'b' } },
      {},
      (r) => sent.push(r),
    );
    await tick(300);
    check(
      '无表单 frame 不应答 fillCredentials（避免抢答）',
      sent.length === 0 && keepChannel !== true,
      `responses=${JSON.stringify(sent)} keepChannel=${keepChannel}`,
    );
  } else {
    check('无表单 frame 不应答 fillCredentials（避免抢答）', false, '未注册监听器');
  }
}

// ─── 场景 7：陈旧 daemon 返回非登录条目 → 绝不填充（协议 3 回归）──────────
// daemon 侧的 getCredentials 只应返回登录条目；这里故意返回安全笔记 / 身份信息 /
// SSH 密钥，验证 content-script 自己再挡一道：既不出现在选择面板里，也不会被
// 填进页面（笔记 / 密钥的 username / password 是空串，一旦放行就是"看起来填了、
// 其实什么都没填"或更糟）。
{
  const FOREIGN = [
    { id: 'n1', type: 'secure_note', name: 'Bank note', username: '', password: '', notes: 'secret note body' },
    { id: 'i1', type: 'identity', name: 'Alice ID', username: '', password: '', notes: '' },
    { id: 'k1', type: 'ssh_key', name: 'Deploy key', username: '', password: '', notes: '' },
  ];
  const { window, doc, state } = await bootPage(LOGIN_PAGE, { entries: FOREIGN });
  const nodes = injectedNodes(doc);
  if (nodes.length) {
    clickEl(window, nodes[0]);
    await tick(400);
  }
  const user = doc.getElementById('user');
  const pass = doc.getElementById('pass');
  check('非登录条目不会被填充',
    (!user || user.value === '') && (!pass || pass.value === ''),
    `user=${user && user.value} pass=${pass && pass.value}`);
  check('非登录条目不进入填充面板',
    !doc.body.textContent.includes('Bank note') &&
      !doc.body.textContent.includes('Alice ID') &&
      !doc.body.textContent.includes('Deploy key'),
    doc.body.textContent.slice(0, 200));
  check('非登录条目只得到"没有匹配"提示',
    doc.body.textContent.includes(t('contentNoMatch')),
    doc.body.textContent.slice(0, 200));
  check('仍向本机宿主取过凭据（是过滤而不是没请求）',
    state.hostCalls.some((c) => c.action === 'getCredentials'),
    JSON.stringify(state.hostCalls.map((c) => c.action)));
}

// ─── 输出 ─────────────────────────────────────────────────
console.log('EasyPass content-script 冒烟测试（jsdom）');
for (const p of passes) console.log(`  ✅ ${p}`);
for (const f of failures) console.log(`  ❌ ${f}`);
if (failures.length) {
  console.log(`❌ ${failures.length} 项失败 / ${passes.length} 项通过`);
  process.exit(1);
}
console.log(`✅ 全部 ${passes.length} 项通过`);
process.exit(0);
