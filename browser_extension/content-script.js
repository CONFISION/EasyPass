// EasyPass Browser Extension - Content Script (v2.2)
//
// 职责：
//   1. 登录表单探测 / 字段识别（findLoginForms / identifyField）
//   2. React/Vue/Angular 受控组件友好写入（原生 value setter + input/change 事件）
//   3. 密码框内联 EasyPass 图标 + 自绘气泡 / 条目选择面板（DOM 与样式均以 easypass- 前缀作用域化）
//   4. 响应 popup 的 fillCredentials / detectForms（契约 §3.2），按需向 background 取数（§3.3）
//
// 契约真相：HANDOFF_V21_CONTRACT.md §2.3（entry 结构）§3.2（popup→content）§3.3（content→background）§4（i18n 键）
// 运行环境：manifest `all_frames: true`，每个 frame 各跑一份；取凭据只用本 frame 的 location.href。
// 纪律：不打印任何凭据；用户可见文案一律 chrome.i18n.getMessage('字面量键')（扩展静态检查靠字面量校验键名）。

(function () {
  'use strict';

  // 同一文档被重复注入（扩展重载后再次 executeScript 等）时只运行一份。
  // content script 通常运行在 isolated world，这个标记页面脚本看不到。
  if (window.__easypassContentScriptLoaded) return;
  window.__easypassContentScriptLoaded = true;

  // ─── 常量 ─────────────────────────────────────────────────

  const ICON_CLASS = 'easypass-icon';
  const ICON_ATTR = 'data-easypass-icon';
  const PANEL_CLASS = 'easypass-panel';
  const PANEL_ATTR = 'data-easypass-panel';
  const STYLE_ATTR = 'data-easypass-style';
  const BOUND_ATTR = 'data-easypass-bound';
  const ITEM_CLASS = 'easypass-item';
  const ENTRY_ATTR = 'data-easypass-entry-id';
  const TITLE_CLASS = 'easypass-panel-title';
  const HINT_CLASS = 'easypass-panel-hint';

  const Z_INDEX = '2147483647';
  const ICON_SIZE = 18;
  const ICON_INSET = 8;
  const MIN_FIELD_WIDTH = 48;
  const MIN_FIELD_HEIGHT = 16;
  const PANEL_MIN_WIDTH = 220;
  const PANEL_GAP = 6;
  const PANEL_MARGIN = 8;
  const SCAN_DEBOUNCE_MS = 400;
  const URL_POLL_MS = 1000;
  const REQUEST_TIMEOUT_MS = 10000;
  const FEEDBACK_MS = 1400;
  const MAX_SHADOW_WALK = 4000;

  // 品牌感小锁（currentColor → 由 CSS 的 color 决定颜色），纯静态字符串，无用户数据
  const ICON_SVG =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true">' +
    '<path fill="currentColor" d="M12 2a5 5 0 0 0-5 5v3H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8a2 2 0 0 0-2-2h-1V7a5 5 0 0 0-5-5Zm0 2.5A2.5 2.5 0 0 1 14.5 7v3h-5V7A2.5 2.5 0 0 1 12 4.5Z"/>' +
    '<circle cx="12" cy="15.4" r="1.6" fill="currentColor"/>' +
    '<rect x="11.3" y="15.4" width="1.4" height="3.3" rx="0.7" fill="currentColor"/></svg>';

  // 图标关键样式全部内联：即使页面 CSS（甚至 !important）命中我们的节点，布局也不会被破坏
  const ICON_INLINE_STYLE =
    'position: fixed; left: 0; top: 0; width: ' + ICON_SIZE + 'px; height: ' + ICON_SIZE + 'px;' +
    ' box-sizing: border-box; display: flex; align-items: center; justify-content: center;' +
    ' border-radius: 4px; background: rgba(30, 30, 46, 0.92); color: #89b4fa;' +
    ' box-shadow: 0 0 0 1px rgba(137, 180, 250, 0.35); cursor: pointer; opacity: 0.85;' +
    ' pointer-events: auto; z-index: ' + Z_INDEX + '; line-height: 0;' +
    ' font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;';

  const PANEL_INLINE_STYLE =
    'position: fixed; left: 0; top: 0; min-width: ' + PANEL_MIN_WIDTH + 'px; max-width: 320px;' +
    ' max-height: 260px; overflow-y: auto; box-sizing: border-box; padding: 8px;' +
    ' border: 1px solid #313244; border-radius: 10px; background: #1e1e2e; color: #cdd6f4;' +
    ' box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45); pointer-events: auto; z-index: ' + Z_INDEX + ';' +
    ' font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;' +
    ' font-size: 13px; line-height: 1.45; text-align: left; direction: ltr;';

  // 作用域化样式：只命中我们自己的 easypass- 前缀 class，不触碰页面元素
  const SCOPED_CSS =
    '.' + ICON_CLASS + ':hover { opacity: 1; background-color: #313244; }' +
    '.' + ICON_CLASS + ' svg { display: block; width: 12px; height: 12px; }' +
    '.' + TITLE_CLASS + ' { padding: 2px 4px 4px; font-size: 12px; font-weight: 600; color: #cdd6f4; }' +
    '.' + HINT_CLASS + ' { padding: 0 4px 6px; font-size: 11px; color: #a6adc8; word-break: break-word; }' +
    '.' + ITEM_CLASS + ' { padding: 6px 8px; border-radius: 6px; cursor: pointer; }' +
    '.' + ITEM_CLASS + ':hover { background-color: #313244; }' +
    '.' + ITEM_CLASS + '-name { overflow: hidden; font-size: 12px; color: #cdd6f4; text-overflow: ellipsis; white-space: nowrap; }' +
    '.' + ITEM_CLASS + '-username { overflow: hidden; font-size: 11px; color: #a6adc8; text-overflow: ellipsis; white-space: nowrap; }';

  // ─── 字段识别 ─────────────────────────────────────────────

  const NON_FILLABLE_TYPES = {
    hidden: 1, submit: 1, button: 1, reset: 1, image: 1, file: 1,
    checkbox: 1, radio: 1, range: 1, color: 1,
  };

  const RE_PASSWORD_HINT = /(password|passwd|pwd)/;
  const RE_TOTP_HINT = /(totp|2fa|mfa|otp|one-?time|authenticator|verification|verify|security-?code)/;
  const RE_USERNAME_HINT = /(username|user|login|email|mail|account|phone|mobile|userid)/;

  function fieldType(input) {
    const type = input.getAttribute('type');
    return (type || 'text').toLowerCase();
  }

  function fieldSignature(input) {
    return [
      input.getAttribute('name'),
      input.getAttribute('id'),
      input.getAttribute('autocomplete'),
      input.getAttribute('placeholder'),
      input.getAttribute('aria-label'),
      input.getAttribute('data-testid'),
    ].filter(Boolean).join(' ').toLowerCase();
  }

  /** 判定输入框用途：'password' | 'username' | 'totp' | null */
  function identifyField(input) {
    try {
      if (!input || input.tagName !== 'INPUT') return null;
      const type = fieldType(input);
      if (NON_FILLABLE_TYPES[type] || type === 'search') return null;

      const autocomplete = (input.getAttribute('autocomplete') || '').toLowerCase();
      const attrs = fieldSignature(input);

      // 顺序很关键：password 优先，否则 "login_password" 之类会先命中 username 关键字
      if (type === 'password' || autocomplete === 'current-password' || autocomplete === 'new-password') return 'password';
      if (autocomplete === 'one-time-code') return 'totp';
      if (type === 'email' || autocomplete === 'username' || autocomplete === 'email') return 'username';
      if (RE_PASSWORD_HINT.test(attrs)) return 'password';
      if (RE_TOTP_HINT.test(attrs)) return 'totp';
      if (RE_USERNAME_HINT.test(attrs)) return 'username';
      return null;
    } catch (e) {
      return null;
    }
  }

  // ─── 可见性与查询 ─────────────────────────────────────────

  function computedStyleValue(el, property) {
    try {
      const style = window.getComputedStyle(el);
      return style ? (style.getPropertyValue(property) || '') : '';
    } catch (e) {
      return '';
    }
  }

  /** 隐藏的输入框（offsetParent === null / display:none / 尺寸为 0）一律不处理 */
  function isElementVisible(el) {
    try {
      if (!el || el.nodeType !== 1 || !el.isConnected) return false;
      if (el.disabled) return false;
      const rect = el.getBoundingClientRect();
      if (!rect || rect.width <= 0 || rect.height <= 0) return false;
      // position: fixed 的元素合法地没有 offsetParent；其余情况说明自身或祖先 display:none
      if (el.offsetParent === null && computedStyleValue(el, 'position') !== 'fixed') return false;
      if (typeof el.checkVisibility === 'function' &&
          el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }) === false) {
        return false;
      }
      if (computedStyleValue(el, 'display') === 'none') return false;
      const visibility = computedStyleValue(el, 'visibility');
      if (visibility === 'hidden' || visibility === 'collapse') return false;
      if (computedStyleValue(el, 'opacity') === '0') return false;
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 收集 document + 页面自身 open shadow root，页面把登录框藏进 shadow DOM 时也能识别 */
  function collectSearchRoots() {
    const roots = [document];
    let budget = MAX_SHADOW_WALK;
    try {
      for (let i = 0; i < roots.length && budget > 0; i++) {
        const all = roots[i].querySelectorAll('*');
        for (let j = 0; j < all.length && budget > 0; j++) {
          budget--;
          if (all[j].shadowRoot) roots.push(all[j].shadowRoot);
        }
      }
    } catch (e) {
      // 忽略：某些节点可能不支持查询，退回已收集的 root
    }
    return roots;
  }

  function queryVisiblePasswordInputs(includeShadowRoots) {
    const found = [];
    const roots = includeShadowRoots ? collectSearchRoots() : [document];
    for (let i = 0; i < roots.length; i++) {
      let list;
      try {
        list = roots[i].querySelectorAll('input[type="password"]');
      } catch (e) {
        continue;
      }
      for (let j = 0; j < list.length; j++) {
        const el = list[j];
        if (found.indexOf(el) === -1 && isElementVisible(el)) found.push(el);
      }
    }
    return found;
  }

  /** 在 root 内找可见输入框；kind 为 null 时返回全部可见输入框 */
  function collectVisibleInputs(root, kind) {
    const found = [];
    if (!root || typeof root.querySelectorAll !== 'function') return found;
    let list;
    try {
      list = root.querySelectorAll('input');
    } catch (e) {
      return found;
    }
    for (let i = 0; i < list.length; i++) {
      const el = list[i];
      if (!isElementVisible(el)) continue;
      if (kind === null || identifyField(el) === kind) found.push(el);
    }
    return found;
  }

  function describeInput(el) {
    return {
      element: el,
      type: fieldType(el),
      name: el.getAttribute('name') || '',
      id: el.id || '',
      autocomplete: (el.getAttribute('autocomplete') || '').toLowerCase(),
      placeholder: el.getAttribute('placeholder') ? el.getAttribute('placeholder').toLowerCase() : '',
    };
  }

  /** 探测登录表单：含可见密码框的 <form>，以及 SPA 风格（不在 form 里）的密码框容器 */
  function findLoginForms() {
    const forms = [];
    const claimed = [];
    try {
      document.querySelectorAll('form').forEach(function (form) {
        if (!collectVisibleInputs(form, 'password').length) return;
        const all = collectVisibleInputs(form, null);
        for (let i = 0; i < all.length; i++) claimed.push(all[i]);
        forms.push({ formElement: form, inputs: all.map(describeInput) });
      });

      const loosePasswordInputs = queryVisiblePasswordInputs(true);
      for (let i = 0; i < loosePasswordInputs.length; i++) {
        const input = loosePasswordInputs[i];
        if (claimed.indexOf(input) !== -1) continue;
        const container = (input.form || input.closest('form') || input.parentElement) || input;
        const scoped = collectVisibleInputs(container, 'password').length ? container : input;
        const inputs = collectVisibleInputs(scoped, null);
        if (!inputs.length) inputs.push(input);
        for (let j = 0; j < inputs.length; j++) claimed.push(inputs[j]);
        forms.push({ formElement: container, inputs: inputs.map(describeInput) });
      }
    } catch (e) {
      // 单点失败不影响页面
    }
    return forms;
  }

  // ─── 写入（React/Vue/Angular 受控组件友好）────────────────

  /** 走原型上的原生 setter 写值，绕过框架对 value 的劫持 */
  function setNativeValue(element, value) {
    try {
      const proto = element.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype
        : window.HTMLInputElement.prototype;
      const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
      if (descriptor && typeof descriptor.set === 'function') {
        descriptor.set.call(element, value);
        return true;
      }
      element.value = value;
      return true;
    } catch (e) {
      try {
        element.value = value;
        return true;
      } catch (e2) {
        return false;
      }
    }
  }

  /** 写值 + 派发 input/change（密码框不加多余事件，避免触发页面的意外行为） */
  function fillField(element, value) {
    try {
      if (!element || typeof value !== 'string' || !value.length) return false;
      if (!setNativeValue(element, value)) return false;
      element.dispatchEvent(new Event('input', { bubbles: true }));
      element.dispatchEvent(new Event('change', { bubbles: true }));
      // 页面若立刻清空（受控组件拒绝该值），按未填充处理
      return element.value !== '';
    } catch (e) {
      return false;
    }
  }

  function scopeOf(el) {
    try {
      return el.form || el.closest('form') || el.parentElement || null;
    } catch (e) {
      return null;
    }
  }

  function rootOf(el) {
    try {
      return el.getRootNode() || document;
    } catch (e) {
      return document;
    }
  }

  function candidateScopes(passwordEl) {
    const scopes = [];
    const scope = scopeOf(passwordEl);
    const root = rootOf(passwordEl);
    if (scope) scopes.push(scope);
    if (root && scopes.indexOf(root) === -1) scopes.push(root);
    if (scopes.indexOf(document) === -1) scopes.push(document);
    return scopes;
  }

  /** 用户名框：优先同一表单/容器内、位于密码框之前的最近一个 */
  function pickUsernameFor(passwordEl) {
    try {
      const scopes = candidateScopes(passwordEl);
      for (let i = 0; i < scopes.length; i++) {
        const candidates = collectVisibleInputs(scopes[i], 'username');
        if (!candidates.length) continue;
        const preceding = candidates.filter(function (el) {
          return (passwordEl.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING) !== 0;
        });
        if (preceding.length) return preceding[preceding.length - 1];
        if (candidates.length === 1) return candidates[0];
      }
    } catch (e) {
      // 忽略
    }
    return null;
  }

  /** TOTP 框：同一作用域优先；页面没有 TOTP 框就不要去打扰本机宿主 */
  function pickTotpFor(passwordEl) {
    try {
      const scopes = candidateScopes(passwordEl);
      for (let i = 0; i < scopes.length; i++) {
        const candidates = collectVisibleInputs(scopes[i], 'totp');
        if (candidates.length) return candidates[0];
      }
    } catch (e) {
      // 忽略
    }
    return null;
  }

  /**
   * 填充入口：preferredPasswordInput 为图标点击路径锚定的那个密码框。
   * 返回契约 §3.2 的 filled 结构。
   */
  function fillCredentialsOnPage(credentials, preferredPasswordInput) {
    const filled = { username: false, password: false, totp: false };
    try {
      const source = credentials || {};
      let passwordEl = null;
      if (preferredPasswordInput && preferredPasswordInput.isConnected &&
          identifyField(preferredPasswordInput) === 'password') {
        passwordEl = preferredPasswordInput;
      } else {
        let candidates = queryVisiblePasswordInputs(false);
        if (!candidates.length) candidates = queryVisiblePasswordInputs(true);
        passwordEl = candidates.length ? candidates[0] : null;
      }
      if (!passwordEl) return { filled };

      filled.username = fillField(pickUsernameFor(passwordEl), source.username);
      filled.password = fillField(passwordEl, source.password);
      filled.totp = fillField(pickTotpFor(passwordEl), source.totp);
    } catch (e) {
      // 单点失败不影响页面
    }
    return { filled };
  }

  // ─── UI（图标 / 气泡 / 条目列表）──────────────────────────

  const UI = {
    style: null,
    panel: null,
    icons: new Map(),
    bound: new WeakSet(),
    anchor: null,
    open: false,
    closeTimer: null,
    flowToken: 0,
    dismissAttached: false,
  };

  function isOwnInjectedNode(node) {
    if (!node || node.nodeType !== 1) return false;
    try {
      return node.hasAttribute(ICON_ATTR) || node.hasAttribute(PANEL_ATTR) || node.hasAttribute(STYLE_ATTR);
    } catch (e) {
      return false;
    }
  }

  /** 注入自己的节点时先断开 observer，避免自己触发自己 */
  function withObserverPaused(fn) {
    let paused = false;
    if (observer && observerPaused === 0) {
      try {
        observer.disconnect();
        paused = true;
      } catch (e) {
        paused = false;
      }
    }
    observerPaused++;
    try {
      return fn();
    } finally {
      observerPaused--;
      if (paused && observer) {
        try {
          observer.observe(document.documentElement || document, { childList: true, subtree: true });
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  function ensureStyle() {
    if (UI.style && UI.style.isConnected) return;
    const parent = document.head || document.documentElement || document.body;
    if (!parent) return;
    const style = document.createElement('style');
    // 刻意不带 easypass 字样的 class/id：既不进页面选择器，也便于残留清理
    style.setAttribute(STYLE_ATTR, '1');
    style.textContent = SCOPED_CSS;
    withObserverPaused(function () {
      parent.appendChild(style);
    });
    UI.style = style;
  }

  function ensurePanel() {
    ensureStyle();
    if (UI.panel && UI.panel.isConnected) return true;
    const parent = document.body || document.documentElement;
    if (!parent) return false;
    const panel = document.createElement('div');
    panel.className = PANEL_CLASS;
    panel.setAttribute(PANEL_ATTR, '1');
    panel.setAttribute('role', 'dialog');
    panel.style.cssText = PANEL_INLINE_STYLE + ' display: none;';
    withObserverPaused(function () {
      parent.appendChild(panel);
    });
    UI.panel = panel;
    UI.open = false;
    return true;
  }

  function ensureIconFor(input) {
    if (!input || !input.isConnected || UI.bound.has(input)) return;
    const rect = input.getBoundingClientRect();
    if (!rect || rect.width < MIN_FIELD_WIDTH || rect.height < MIN_FIELD_HEIGHT) return;
    const parent = document.body || document.documentElement;
    if (!parent) return;

    UI.bound.add(input);
    try {
      input.setAttribute(BOUND_ATTR, '1');
    } catch (e) {
      // 忽略
    }

    const icon = document.createElement('div');
    icon.className = ICON_CLASS;
    icon.setAttribute(ICON_ATTR, '1');
    icon.setAttribute('role', 'button');
    icon.title = chrome.i18n.getMessage('fillWithEasyPass');
    icon.innerHTML = ICON_SVG;
    icon.style.cssText = ICON_INLINE_STYLE + ' display: none;';
    // 不让点击图标抢走输入框焦点，同时吞掉事件避免打扰页面
    icon.addEventListener('mousedown', function (ev) {
      try {
        ev.preventDefault();
      } catch (e) {
        // 忽略
      }
    }, true);
    icon.addEventListener('click', function (ev) {
      onIconClick(ev, input);
    }, true);

    withObserverPaused(function () {
      parent.appendChild(icon);
    });
    UI.icons.set(input, icon);
  }

  function pruneIcons() {
    UI.icons.forEach(function (icon, input) {
      if (input.isConnected && icon.isConnected) return;
      try {
        icon.remove();
      } catch (e) {
        // 忽略
      }
      UI.icons.delete(input);
      UI.bound.delete(input);
      try {
        input.removeAttribute(BOUND_ATTR);
      } catch (e) {
        // 忽略
      }
    });
  }

  function repositionAll() {
    try {
      const viewportWidth = window.innerWidth || 0;
      const viewportHeight = window.innerHeight || 0;
      UI.icons.forEach(function (icon, input) {
        if (!input.isConnected || !icon.isConnected) return;
        const rect = input.getBoundingClientRect();
        const visible = isElementVisible(input) &&
          rect.bottom > 0 && rect.top < viewportHeight &&
          rect.right > 0 && rect.left < viewportWidth &&
          rect.width >= MIN_FIELD_WIDTH && rect.height >= MIN_FIELD_HEIGHT;
        if (!visible) {
          icon.style.display = 'none';
          return;
        }
        icon.style.display = 'flex';
        icon.style.left = Math.round(rect.right - ICON_SIZE - ICON_INSET) + 'px';
        icon.style.top = Math.round(rect.top + (rect.height - ICON_SIZE) / 2) + 'px';
      });
      if (UI.open) positionPanel();
    } catch (e) {
      // 忽略
    }
  }

  function scheduleReposition() {
    if (repositionQueued) return;
    repositionQueued = true;
    const run = function () {
      repositionQueued = false;
      repositionAll();
    };
    if (typeof window.requestAnimationFrame === 'function') window.requestAnimationFrame(run);
    else window.setTimeout(run, 16);
  }

  function clearPanel() {
    if (!UI.panel) return;
    while (UI.panel.firstChild) UI.panel.removeChild(UI.panel.firstChild);
  }

  function panelRow(className, text) {
    const row = document.createElement('div');
    row.className = className;
    row.textContent = text;
    return row;
  }

  function positionPanel() {
    const panel = UI.panel;
    const anchor = UI.anchor;
    if (!panel || !anchor || !UI.open) return;
    if (!anchor.isConnected || !isElementVisible(anchor)) {
      closePanel();
      return;
    }
    const rect = anchor.getBoundingClientRect();
    const width = panel.offsetWidth || PANEL_MIN_WIDTH;
    const height = panel.offsetHeight || 0;
    const viewportWidth = window.innerWidth || 0;
    const viewportHeight = window.innerHeight || 0;

    let left = rect.right - width;
    left = Math.max(PANEL_MARGIN, Math.min(left, viewportWidth - width - PANEL_MARGIN));
    let top = rect.bottom + PANEL_GAP;
    if (height && top + height > viewportHeight - PANEL_MARGIN) {
      const above = rect.top - height - PANEL_GAP;
      top = above >= PANEL_MARGIN ? above : Math.max(PANEL_MARGIN, viewportHeight - height - PANEL_MARGIN);
    }
    panel.style.left = Math.round(left) + 'px';
    panel.style.top = Math.round(top) + 'px';
  }

  function openPanel(anchor, build) {
    if (!anchor || !anchor.isConnected) return;
    if (!ensurePanel()) return;
    clearPanel();
    try {
      build(UI.panel);
    } catch (e) {
      // 忽略
    }
    UI.anchor = anchor;
    if (!UI.open) {
      UI.open = true;
      UI.panel.style.display = 'block';
      attachDismissListeners();
    }
    positionPanel();
  }

  function setPanelMessage(anchor, text, hint) {
    openPanel(anchor, function (panel) {
      if (text) panel.appendChild(panelRow(TITLE_CLASS, text));
      if (hint) panel.appendChild(panelRow(HINT_CLASS, hint));
    });
  }

  function closePanel() {
    UI.flowToken++;
    if (UI.closeTimer) {
      window.clearTimeout(UI.closeTimer);
      UI.closeTimer = null;
    }
    UI.anchor = null;
    if (!UI.open) return;
    UI.open = false;
    if (UI.panel) {
      UI.panel.style.display = 'none';
      clearPanel();
    }
    detachDismissListeners();
  }

  function scheduleAutoClose() {
    if (UI.closeTimer) window.clearTimeout(UI.closeTimer);
    UI.closeTimer = window.setTimeout(function () {
      UI.closeTimer = null;
      closePanel();
    }, FEEDBACK_MS);
  }

  /** 事件是否来自我们自己的 UI（图标 / 面板）：是则交给各自的 click 处理，不当作"点击外部" */
  function isOwnUiEvent(ev) {
    try {
      if (typeof ev.composedPath !== 'function') return false;
      const path = ev.composedPath();
      for (let i = 0; i < path.length; i++) {
        const node = path[i];
        if (node === UI.panel) return true;
        if (node && node.nodeType === 1 && typeof node.hasAttribute === 'function' && node.hasAttribute(ICON_ATTR)) return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  function onDocumentPointerDown(ev) {
    if (isOwnUiEvent(ev)) return; // 面板内部的点击交给条目自己的处理函数
    closePanel();
  }

  function onDocumentKeyDown(ev) {
    if (ev.key === 'Escape' || ev.key === 'Esc') closePanel();
  }

  function attachDismissListeners() {
    if (UI.dismissAttached) return;
    UI.dismissAttached = true;
    document.addEventListener('pointerdown', onDocumentPointerDown, true);
    document.addEventListener('keydown', onDocumentKeyDown, true);
  }

  function detachDismissListeners() {
    if (!UI.dismissAttached) return;
    UI.dismissAttached = false;
    document.removeEventListener('pointerdown', onDocumentPointerDown, true);
    document.removeEventListener('keydown', onDocumentKeyDown, true);
  }

  // ─── 消息（content → background，契约 §3.3）───────────────

  function sendToBackground(action, payload) {
    return new Promise(function (resolve) {
      let settled = false;
      const finish = function (value) {
        if (!settled) {
          settled = true;
          resolve(value);
        }
      };
      const message = Object.assign({ action: action }, payload || {});
      const timer = window.setTimeout(function () {
        finish({ error: chrome.i18n.getMessage('requestTimedOut') });
      }, REQUEST_TIMEOUT_MS);
      try {
        chrome.runtime.sendMessage(message, function (response) {
          window.clearTimeout(timer);
          // 同步读取，避免 "Unchecked runtime.lastError" 噪音
          const lastError = chrome.runtime.lastError;
          if (lastError) {
            finish({ error: lastError.message });
            return;
          }
          finish(response === undefined ? { error: chrome.i18n.getMessage('cannotConnect') } : response);
        });
      } catch (e) {
        window.clearTimeout(timer);
        finish({ error: chrome.i18n.getMessage('cannotConnect') });
      }
    });
  }

  function errorDetail(res) {
    if (!res || !res.error) return '';
    return typeof res.error === 'string' ? res.error : String(res.error);
  }

  /** getCredentials 返回的是条目数组（契约 §2.1/§2.3），不是单个对象 */
  function normalizeEntries(res) {
    if (Array.isArray(res)) return { entries: res, error: '' };
    if (res && res.error) return { entries: [], error: errorDetail(res) };
    return { entries: [], error: '' };
  }

  /**
   * 自动填充只认登录条目（契约 §5）。daemon 侧的 getCredentials 已经只返回登录条目，
   * 这里再挡一道：陈旧的 daemon（协议 2 及更早）或异常回退路径可能把安全笔记 /
   * 身份信息 / SSH 密钥塞回来，那些条目的 username/password 是空串，但绝不能
   * 出现在填充面板里，更不该被"填"进页面。
   *
   * type 缺失时按登录处理（与桌面端 EntryType.fromWire 的容错一致，也不会让旧
   * daemon 的既有行为变差）；type 明确不是 login 的一律剔除。
   */
  function isFillableEntry(entry) {
    if (!entry || typeof entry !== 'object') return false;
    const raw = entry.type;
    if (raw === undefined || raw === null) return true; // 旧 daemon：无 type = 登录
    if (typeof raw !== 'string') return false; // 非字符串的 type 一律不信任
    const normalized = raw.trim().toLowerCase().replace(/[\s-]+/g, '_');
    return normalized === '' || normalized === 'login';
  }

  function fillableOnly(entries) {
    if (!Array.isArray(entries)) return [];
    return entries.filter(isFillableEntry);
  }

  function fetchTotp(entryId) {
    if (!entryId) return Promise.resolve('');
    return sendToBackground('getTotp', { entryId: entryId }).then(function (res) {
      if (res && !res.error && typeof res.totp === 'string' && res.totp) return res.totp;
      return '';
    }, function () {
      return '';
    });
  }

  // ─── 交互流程 ─────────────────────────────────────────────

  function onIconClick(ev, input) {
    try {
      ev.preventDefault();
      ev.stopPropagation();
    } catch (e) {
      // 忽略
    }
    if (UI.open && UI.anchor === input) {
      closePanel();
      return;
    }
    runFillFlow(input);
  }

  function openEntryList(anchor, entries) {
    const fillable = fillableOnly(entries);
    if (!fillable.length) {
      setPanelMessage(anchor, chrome.i18n.getMessage('contentNoMatch'), '');
      return;
    }
    openPanel(anchor, function (panel) {
      panel.appendChild(panelRow(TITLE_CLASS, chrome.i18n.getMessage('contentMultiple')));
      panel.appendChild(panelRow(HINT_CLASS, chrome.i18n.getMessage('contentFillHint')));
      for (let i = 0; i < fillable.length; i++) {
        const entry = fillable[i] || {};
        const item = document.createElement('div');
        item.className = ITEM_CLASS;
        item.setAttribute(ENTRY_ATTR, entry.id === undefined || entry.id === null ? '' : String(entry.id));

        const name = document.createElement('div');
        name.className = ITEM_CLASS + '-name';
        name.textContent = String(entry.name || entry.username || '');
        item.appendChild(name);

        if (entry.username) {
          const username = document.createElement('div');
          username.className = ITEM_CLASS + '-username';
          username.textContent = String(entry.username);
          item.appendChild(username);
        }

        item.addEventListener('click', function (ev) {
          onEntryClick(ev, entry, anchor);
        });
        panel.appendChild(item);
      }
    });
  }

  function onEntryClick(ev, entry, anchor) {
    try {
      ev.preventDefault();
      ev.stopPropagation();
    } catch (e) {
      // 忽略
    }
    const token = ++UI.flowToken;
    setPanelMessage(anchor, chrome.i18n.getMessage('loading'), '');
    fillEntry(entry, anchor, token);
  }

  function fillEntry(entry, anchor, token) {
    // 最后一道门槛：非登录条目绝不下发到页面（契约 §5）。
    if (!isFillableEntry(entry)) {
      setPanelMessage(anchor, chrome.i18n.getMessage('contentNoMatch'), '');
      return;
    }
    const credentials = {
      username: entry && entry.username ? entry.username : '',
      password: entry && entry.password ? entry.password : '',
    };
    // 只有页面确实有 TOTP 输入框时才去取验证码（契约 §3.3，也避免无谓地唤醒本机宿主）
    const needsTotp = !!(entry && entry.hasTotp) && !!pickTotpFor(anchor);
    const ready = needsTotp
      ? fetchTotp(entry.id).then(function (code) {
          if (token !== UI.flowToken) return false;
          if (code) credentials.totp = code;
          return true;
        })
      : Promise.resolve(true);

    ready.then(function (ok) {
      if (!ok || token !== UI.flowToken) return;
      const filled = fillCredentialsOnPage(credentials, anchor).filled;
      const any = filled.username || filled.password || filled.totp;
      if (!any) {
        setPanelMessage(anchor, chrome.i18n.getMessage('fillFailed'), '');
        return;
      }
      setPanelMessage(anchor, chrome.i18n.getMessage('fillSuccess'), '');
      scheduleAutoClose();
    }).catch(function () {
      if (token === UI.flowToken) setPanelMessage(anchor, chrome.i18n.getMessage('fillFailed'), '');
    });
  }

  function runFillFlow(input) {
    const token = ++UI.flowToken;
    setPanelMessage(input, chrome.i18n.getMessage('loading'), '');

    sendToBackground('getStatus')
      .then(function (status) {
        if (token !== UI.flowToken) return null;
        if (!status || status.error) {
          setPanelMessage(input, chrome.i18n.getMessage('cannotConnect'), errorDetail(status));
          return null;
        }
        if (status.locked) {
          // 锁定态：只提示（contentLockedHint 已说明去工具栏图标解锁），绝不把主密码框注入网页
          setPanelMessage(input, chrome.i18n.getMessage('contentLockedHint'), '');
          return null;
        }
        return sendToBackground('getCredentials', { url: location.href });
      })
      .then(function (res) {
        if (res === null || token !== UI.flowToken) return;
        const matched = normalizeEntries(res);
        if (matched.error) {
          setPanelMessage(input, chrome.i18n.getMessage('cannotConnect'), matched.error);
          return;
        }
        // 自动填充只认登录条目：陈旧 daemon 可能把笔记 / 密钥一起返回。
        const candidates = fillableOnly(matched.entries);
        if (!candidates.length) {
          setPanelMessage(input, chrome.i18n.getMessage('contentNoMatch'), '');
          return;
        }
        if (candidates.length === 1) {
          fillEntry(candidates[0], input, token);
          return;
        }
        openEntryList(input, candidates);
      })
      .catch(function () {
        if (token === UI.flowToken) setPanelMessage(input, chrome.i18n.getMessage('fillFailed'), '');
      });
  }

  // ─── 扫描 / MutationObserver / SPA ────────────────────────

  let observer = null;
  let observerPaused = 0;
  let scanTimer = null;
  let deepScanRequested = true;
  let repositionQueued = false;
  let urlTimer = null;
  let lastHref = '';

  function scanAndInject() {
    try {
      pruneIcons();
      const deep = deepScanRequested;
      deepScanRequested = false;
      const inputs = queryVisiblePasswordInputs(deep);
      if (!inputs.length) return; // 没有可见密码框：不建 UI、不发消息、完全静默
      ensureStyle();
      for (let i = 0; i < inputs.length; i++) ensureIconFor(inputs[i]);
      repositionAll();
    } catch (e) {
      // 单点失败不影响页面
    }
  }

  function scheduleScan() {
    if (scanTimer !== null) return;
    scanTimer = window.setTimeout(function () {
      scanTimer = null;
      scanAndInject();
    }, SCAN_DEBOUNCE_MS);
  }

  /**
   * 只在新增/删除的子树"可能含表单控件"时才调度扫描（旧版任何 DOM 变动都无条件重扫）。
   * 顺带发现页面自身新挂上的 shadow host → 请求一次深度扫描。
   */
  function noteRelevantNodes(nodes) {
    if (!nodes || !nodes.length) return false;
    let relevant = false;
    for (let i = 0; i < nodes.length; i++) {
      const node = nodes[i];
      if (!node || node.nodeType !== 1 || isOwnInjectedNode(node)) continue;
      if (node.shadowRoot) {
        deepScanRequested = true;
        relevant = true;
        continue;
      }
      if (node.tagName === 'INPUT' || node.tagName === 'FORM' || node.tagName === 'TEXTAREA') {
        relevant = true;
        continue;
      }
      try {
        if (node.querySelector('input, textarea, form')) relevant = true;
      } catch (e) {
        // 忽略
      }
    }
    return relevant;
  }

  function onMutations(mutations) {
    if (observerPaused > 0) return;
    try {
      for (let i = 0; i < mutations.length; i++) {
        const mutation = mutations[i];
        if (mutation.type !== 'childList') continue;
        if (isOwnInjectedNode(mutation.target)) continue; // 我们自己的节点，忽略
        if (noteRelevantNodes(mutation.addedNodes) || noteRelevantNodes(mutation.removedNodes)) {
          scheduleScan();
          return;
        }
      }
    } catch (e) {
      // 忽略
    }
  }

  function startObserver() {
    if (observer || typeof window.MutationObserver !== 'function') return;
    try {
      observer = new window.MutationObserver(onMutations);
      // 只观察 childList：属性/文本变动（例如输入时的 class 抖动）完全不唤醒我们
      observer.observe(document.documentElement || document, { childList: true, subtree: true });
    } catch (e) {
      observer = null;
    }
  }

  function startViewportWatcher() {
    window.addEventListener('scroll', scheduleReposition, { capture: true, passive: true });
    window.addEventListener('resize', scheduleReposition, { passive: true });
  }

  function onLocationMaybeChanged() {
    let href = '';
    try {
      href = location.href;
    } catch (e) {
      return;
    }
    if (href === lastHref) return;
    lastHref = href;
    deepScanRequested = true;
    closePanel();
    scheduleScan();
  }

  function startUrlWatcher() {
    try {
      lastHref = location.href;
    } catch (e) {
      lastHref = '';
    }
    window.addEventListener('popstate', onLocationMaybeChanged, true);
    window.addEventListener('hashchange', onLocationMaybeChanged, true);
    // content script 在 isolated world 里拦不到页面自身的 history.pushState/replaceState
    // （改了也只是改自己 world 的包装），因此用 1s 轻量轮询（只比较字符串）+ popstate/hashchange 兜底。
    urlTimer = window.setInterval(onLocationMaybeChanged, URL_POLL_MS);
  }

  /** 扩展重载后旧实例留下的节点已失去消息通道：清掉残留并解除绑定标记，由本实例重新注入 */
  function cleanupStaleUi() {
    const stale = document.querySelectorAll('[' + ICON_ATTR + '], [' + PANEL_ATTR + '], [' + STYLE_ATTR + ']');
    if (!stale.length) return;
    for (let i = 0; i < stale.length; i++) {
      try {
        stale[i].remove();
      } catch (e) {
        // 忽略
      }
    }
    const marked = document.querySelectorAll('[' + BOUND_ATTR + ']');
    for (let i = 0; i < marked.length; i++) {
      try {
        marked[i].removeAttribute(BOUND_ATTR);
      } catch (e) {
        // 忽略
      }
    }
  }

  // ─── 消息监听（popup → content，契约 §3.2）────────────────

  function replyFillCredentials(request, sendResponse) {
    const credentials = (request && typeof request.credentials === 'object' && request.credentials) ? request.credentials : {};
    let hasForm = false;
    try {
      hasForm = queryVisiblePasswordInputs(true).length > 0;
    } catch (e) {
      hasForm = false;
    }
    // 本 frame 没有可填字段 → **完全不应答**（返回 false 表示不占用消息通道）。
    // tabs.sendMessage 不带 frameId 时会把消息广播到所有 frame，并只把"第一个
    // 响应"交给 popup；空 frame（典型：含 iframe 的页面里没有登录框的子 frame）
    // 抢答会让 popup 误判为受限页面 —— 明明填好了却提示"不支持填充"并去复制
    // 密码。保持沉默，让真正有登录框的那个 frame 回答；所有 frame 都沉默时
    // popup 侧收到 reject，才走受限页面回退（契约 §3.2）。
    if (!hasForm) return false;

    let filled = { username: false, password: false, totp: false };
    try {
      filled = fillCredentialsOnPage(credentials, null).filled;
    } catch (e) {
      filled = { username: false, password: false, totp: false };
    }
    if (filled.username || filled.password || filled.totp) {
      sendResponse({ success: true, filled: filled });
    } else {
      sendResponse({ success: false, error: chrome.i18n.getMessage('fillFailed') });
    }
    return false; // 同步应答完成，无需保持通道
  }

  function replyDetectForms(sendResponse) {
    let forms = 0;
    let url = '';
    try {
      forms = findLoginForms().length;
    } catch (e) {
      forms = 0;
    }
    try {
      url = location.href;
    } catch (e) {
      url = '';
    }
    sendResponse({ forms: forms, url: url });
  }

  chrome.runtime.onMessage.addListener(function (request, sender, sendResponse) {
    if (!request || typeof request.action !== 'string') return; // 不认识的消息不占用通道
    if (request.action === 'fillCredentials') {
      // 返回值 = 是否异步应答；空 frame 返回 false，表示"本 frame 不回答"
      return replyFillCredentials(request, sendResponse);
    }
    if (request.action === 'detectForms') {
      replyDetectForms(sendResponse);
      return false; // 同步应答完成
    }
    return; // 其余动作（例如 popup 广播的本机宿主请求）一律不处理
  });

  // ─── 初始化 ───────────────────────────────────────────────

  function init() {
    try {
      cleanupStaleUi();
    } catch (e) {
      // 忽略
    }
    try {
      scanAndInject();
    } catch (e) {
      // 忽略
    }
    startObserver();
    startViewportWatcher();
    startUrlWatcher();
    try {
      const loaded = chrome.i18n.getMessage('logContentScriptLoaded');
      if (loaded) console.log(loaded);
    } catch (e) {
      // 忽略
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }
})();
