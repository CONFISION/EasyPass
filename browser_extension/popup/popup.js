/* EasyPass Browser Extension - Popup Script
 *
 * Single popup with three tabs (vault / generator / health). The popup talks to
 * the background service worker only (chrome.runtime.sendMessage), which
 * forwards to the native host, and to the page only through
 * chrome.tabs.sendMessage({action:'fillCredentials'}).
 *
 * Discipline:
 *  - every user-visible string goes through chrome.i18n.getMessage() using the
 *    keys frozen in HANDOFF_V21_CONTRACT.md §4 (no hard-coded copy);
 *  - every dynamic value inserted into the DOM is escaped (escapeHtml/escapeAttr);
 *  - plaintext passwords / TOTP codes live in memory only: never logged, never
 *    written to chrome.storage.
 */

'use strict';

// ─── Constants ────────────────────────────────────────────

const TABS = ['vault', 'generator', 'health'];
const SEARCH_DEBOUNCE_MS = 200;
const GENERATOR_DEBOUNCE_MS = 150;
const STATUS_TIMEOUT_MS = 8000;
const AUTO_LOCK_SYNC_MIN_MS = 10000;
const UNLOCK_TIMEOUT_MS = 20000;
const LOCK_TIMEOUT_MS = 6000;
const CONTENT_TIMEOUT_MS = 4000;
const CLOSE_AFTER_FILL_MS = 700;
const DEFAULT_TOTP_PERIOD = 30;
const GENERATOR_MIN_LENGTH = 8;
const GENERATOR_MAX_LENGTH = 64;

// ─── State (in-memory only) ───────────────────────────────

const state = {
  // loading | connected | locked | disconnected
  connection: 'loading',
  autoLockDeadline: null, // ms timestamp derived from autoLockRemainingSeconds
  tab: 'vault',
  entries: [],            // current vault list (may contain plaintext fields)
  searchQuery: '',
  rows: new Map(),        // entryId -> { showPassword, totp }
  lastStatusAt: 0,        // ms timestamp of the last successful getStatus
  locking: false,         // a lock round-trip is in flight
  unlocking: false,       // an unlock round-trip is in flight
  generator: { result: '', error: null },
  health: { loading: false, data: null, error: null, expanded: {} },
  pageMatch: { known: false, hasMatch: false }
};

const dom = {};
let searchTimer = null;
let generatorTimer = null;
let toastTimer = null;
let autoLockTimer = null;
let totpTickTimer = null;

// ─── i18n ─────────────────────────────────────────────────

/** chrome.i18n.getMessage with a key fallback: a missing locale entry shows the
 *  key name instead of an empty label (never render blank UI). */
function msg(key, substitutions) {
  try {
    const text = chrome.i18n.getMessage(key, substitutions);
    return text || key;
  } catch (e) {
    return key;
  }
}

function applyI18n() {
  document.querySelectorAll('[data-i18n]').forEach(el => {
    const key = el.dataset.i18n;
    if (key) el.textContent = msg(key);
  });
  document.querySelectorAll('[data-i18n-placeholder]').forEach(el => {
    const key = el.dataset.i18nPlaceholder;
    if (key) el.placeholder = msg(key);
  });
  document.querySelectorAll('[data-i18n-title]').forEach(el => {
    const key = el.dataset.i18nTitle;
    if (key) el.title = msg(key);
  });
  document.querySelectorAll('[data-i18n-aria]').forEach(el => {
    const key = el.dataset.i18nAria;
    if (key) el.setAttribute('aria-label', msg(key));
  });
  try {
    document.documentElement.lang = chrome.i18n.getUILanguage();
  } catch (e) {
    /* keep the default lang attribute */
  }
}

// ─── Small helpers ────────────────────────────────────────

function byId(id) {
  return document.getElementById(id);
}

function clamp(value, min, max) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

function toInt(value, fallback) {
  const n = typeof value === 'number' ? value : parseInt(value, 10);
  return Number.isFinite(n) ? n : fallback;
}

function firstDefined() {
  for (let i = 0; i < arguments.length; i++) {
    const value = arguments[i];
    if (value !== undefined && value !== null) return value;
  }
  return null;
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text === undefined || text === null ? '' : String(text);
  return div.innerHTML;
}

/** escapeHtml + quote escaping, for values placed inside HTML attributes. */
function escapeAttr(text) {
  return escapeHtml(text).replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function truncateUrl(url) {
  const raw = typeof url === 'string' ? url : '';
  if (!raw) return '';
  try {
    return new URL(raw).hostname;
  } catch (e) {
    /* fall through: try to parse a scheme-less host */
  }
  try {
    return new URL('https://' + raw).hostname;
  } catch (e) {
    return raw;
  }
}

function getEntryIcon(name) {
  const lowerName = (name || '').toLowerCase();
  if (lowerName.includes('google')) return '🔍';
  if (lowerName.includes('github')) return '🐙';
  if (lowerName.includes('facebook') || lowerName.includes('meta')) return '📘';
  if (lowerName.includes('twitter') || lowerName.includes('x.com')) return '🐦';
  if (lowerName.includes('amazon')) return '📦';
  if (lowerName.includes('apple') || lowerName.includes('icloud')) return '🍎';
  if (lowerName.includes('microsoft') || lowerName.includes('outlook')) return '🪟';
  if (lowerName.includes('bank') || lowerName.includes('finance')) return '🏦';
  if (lowerName.includes('mail') || lowerName.includes('email')) return '✉️';
  return '🔑';
}

// ─── Messaging ────────────────────────────────────────────

/** The background resolves with the payload on success and with
 *  { error: message } on failure (native host down, vault locked, ...). */
function isErrorResponse(res) {
  return !!res && typeof res === 'object' && res.error !== undefined;
}

function errorMessage(res) {
  if (!res) return '';
  if (typeof res === 'string') return res;
  if (res.error !== undefined) return String(res.error);
  if (res.message !== undefined) return String(res.message);
  return String(res);
}

/** Popup-side timeout so a hung round-trip cannot leave the popup stuck. */
function sendWithTimeout(message, ms) {
  const timeout = ms || STATUS_TIMEOUT_MS;
  return Promise.race([
    chrome.runtime.sendMessage(message),
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error('background timeout after ' + timeout + 'ms')), timeout)
    )
  ]);
}

function sendToTabWithTimeout(tabId, message, ms) {
  const timeout = ms || CONTENT_TIMEOUT_MS;
  return Promise.race([
    chrome.tabs.sendMessage(tabId, message),
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error('content script timeout after ' + timeout + 'ms')), timeout)
    )
  ]);
}

/** The native host reports lock problems as "Vault is locked" (Dart side). */
function isLockedError(text) {
  return !!text && String(text).toLowerCase().indexOf('locked') !== -1;
}

/** True when the response is an error that means "session gone". */
function handleLockedResponse(res) {
  if (!isErrorResponse(res)) return false;
  if (!isLockedError(errorMessage(res))) return false;
  handleLocked();
  return true;
}

// ─── Error grading ────────────────────────────────────────
//
// Failures are not interchangeable and the user has to be told which one
// happened — a blanket "cannot connect" was actively misleading. The case that
// started this: an *outdated* EasyPass daemon (still running from a previous
// build) answers "Unknown action: getHealthReport", which the background
// worker reports as the `staleDaemon` code.
//
//   staleDaemon  desktop background service older than the extension
//   locked       vault session gone (handled by handleLocked)
//   timeout      no answer inside the popup-side budget
//   unreachable  host / service worker not there at all

/** True when the host answered "I don't know this action". */
function isStaleDaemonError(text) {
  if (!text) return false;
  const raw = String(text);
  if (raw.toLowerCase().indexOf('staledaemon') !== -1) return true;
  const localizedStale = msg('staleDaemon');
  if (localizedStale && localizedStale !== 'staleDaemon' && raw.indexOf(localizedStale) !== -1) {
    return true;
  }
  // Legacy shape: an old worker/daemon only said "Unknown action: <name>".
  // The localized wording is derived from the locale template rather than
  // hard-coded here, so this file stays copy-free.
  if (/unknown action/i.test(raw)) return true;
  const localizedUnknown = msg('unknownAction', ['']);
  return !!localizedUnknown && localizedUnknown !== 'unknownAction' &&
    localizedUnknown.length > 2 && raw.indexOf(localizedUnknown) !== -1;
}

/** True when the failure means "no answer in time": the popup-side budget, the
 *  service worker's own timeout, or a host that stopped responding. */
function isTimeoutError(raw) {
  if (/timeout|timed out/i.test(raw)) return true;
  const localized = msg('requestTimedOut');
  return !!localized && localized !== 'requestTimedOut' && raw.indexOf(localized) !== -1;
}

/** Map a raw failure (error text or thrown Error message) to presentation data. */
function describeError(rawText) {
  const raw = rawText === undefined || rawText === null ? '' : String(rawText);
  if (isStaleDaemonError(raw)) {
    return {
      kind: 'staleDaemon',
      tone: 'error',
      title: msg('staleDaemon'),
      detail: msg('restartApp')
    };
  }
  if (isLockedError(raw)) {
    return { kind: 'locked', tone: 'warn', title: msg('vaultLocked'), detail: '' };
  }
  if (isTimeoutError(raw)) {
    const title = msg('requestTimedOut');
    // The service worker already sends the localized timeout sentence; don't
    // repeat it as a detail line. Only keep the raw text when it adds
    // information (e.g. which side of the round trip ran out of time).
    const detail = raw && raw.indexOf(title) === -1 ? raw : '';
    return { kind: 'timeout', tone: 'error', title: title, detail: detail };
  }
  return { kind: 'unreachable', tone: 'error', title: msg('cannotConnect'), detail: raw };
}

async function getActiveTab() {
  try {
    const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
    return Array.isArray(tabs) && tabs.length ? tabs[0] : null;
  } catch (e) {
    return null;
  }
}

// ─── Clipboard ────────────────────────────────────────────

function legacyCopy(text) {
  try {
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.top = '-1000px';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    area.setSelectionRange(0, area.value.length);
    const ok = document.execCommand('copy');
    document.body.removeChild(area);
    return ok;
  } catch (e) {
    return false;
  }
}

async function writeClipboard(text) {
  if (!text) return false;
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch (e) {
    /* fall back to the legacy path below */
  }
  return legacyCopy(text);
}

/** Copy a value and toast the matching "copied*" key. */
async function copyValue(text, successKey) {
  const value = typeof text === 'string' ? text : '';
  if (!value) {
    showToast(msg('nothingToCopy'), '', 'warn');
    return false;
  }
  const ok = await writeClipboard(value);
  if (ok) {
    showToast(msg(successKey), '', 'success');
  } else {
    showToast(msg('copyFailed'), '', 'error');
  }
  return ok;
}

// ─── Toast ────────────────────────────────────────────────

const TOAST_ICONS = { success: '✓', warn: '!', error: '✕', info: 'i' };

function showToast(text, detail, kind) {
  if (!dom.toast) return;
  const tone = TOAST_ICONS[kind] ? kind : 'info';
  dom.toastText.textContent = text || '';
  dom.toastDetail.textContent = detail || '';
  dom.toastDetail.hidden = !detail;
  if (dom.toastIcon) dom.toastIcon.textContent = TOAST_ICONS[tone];
  dom.toast.className = 'toast toast-' + tone;
  dom.toast.hidden = false;
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    dom.toast.hidden = true;
  }, detail ? 4200 : 2400);
}

// ─── View switching ───────────────────────────────────────

function hideAllViews() {
  dom.loadingView.hidden = true;
  dom.errorView.hidden = true;
  dom.unlockView.hidden = true;
  dom.mainView.hidden = true;
}

function showLoadingView() {
  hideAllViews();
  dom.loadingView.hidden = false;
}

/** Error view action: re-run the status handshake (typically after the user
 *  restarted an outdated EasyPass build). */
function onRetry() {
  showLoadingView();
  refreshStatus({ retries: 2 });
}

function showErrorView(desc) {
  // Accepts either a descriptor from describeError() or a raw string.
  const data = desc && typeof desc === 'object' ? desc : describeError(desc);
  hideAllViews();
  if (dom.errorTitle) dom.errorTitle.textContent = data.title || msg('cannotConnect');
  dom.errorDetail.textContent = data.detail || '';
  dom.errorDetail.hidden = !data.detail;
  dom.errorView.hidden = false;
}

function showUnlockView() {
  hideAllViews();
  dom.unlockView.hidden = false;
  window.setTimeout(() => {
    try {
      dom.masterPassword.focus();
    } catch (e) {
      /* focus is best-effort */
    }
  }, 0);
}

function showMainView() {
  hideAllViews();
  dom.mainView.hidden = false;
}

// ─── Status / connection ──────────────────────────────────

function updateStatusTitle() {
  if (!dom.statusDot) return;
  if (state.connection === 'connected') {
    let title = msg('connected');
    if (state.autoLockDeadline !== null) {
      const secondsLeft = Math.max(0, Math.round((state.autoLockDeadline - Date.now()) / 1000));
      const minutes = Math.max(0, Math.ceil(secondsLeft / 60));
      title += ' · ' + msg('autoLockIn', [String(minutes)]);
    }
    dom.statusDot.title = title;
  } else if (state.connection === 'locked') {
    dom.statusDot.title = msg('vaultLocked');
  } else if (state.connection === 'loading') {
    dom.statusDot.title = msg('loading');
  } else {
    dom.statusDot.title = msg('statusDisconnected');
  }
}

function updateStatusIndicator() {
  if (!dom.statusDot) return;
  const cls = state.connection === 'connected' ? 'connected'
    : state.connection === 'locked' ? 'locked'
      : state.connection === 'loading' ? 'loading'
        : 'disconnected';
  dom.statusDot.className = 'status ' + cls;
  updateStatusTitle();
  if (dom.statusText) {
    // Short label inside the pill; the richer sentence stays in the tooltip.
    const labelKey = state.connection === 'connected' ? 'connected'
      : state.connection === 'locked' ? 'lock'
        : state.connection === 'loading' ? 'loading'
          : 'disconnected';
    dom.statusText.textContent = msg(labelKey);
  }
  dom.btnLock.hidden = state.connection !== 'connected';
  // Tabs stay reachable while locked: the vault tab shows the unlock form,
  // the generator works without the vault and health shows healthLocked.
  dom.tabBar.hidden = !(state.connection === 'connected' || state.connection === 'locked');
}

/** Lock button busy state: spinner ring + no double clicks, but always
 *  recoverable — every path out of lockVault() clears it. */
function setLockBusy(busy) {
  if (!dom.btnLock) return;
  dom.btnLock.disabled = !!busy;
  dom.btnLock.classList.toggle('is-busy', !!busy);
  dom.btnLock.setAttribute('aria-busy', busy ? 'true' : 'false');
  if (dom.btnLockLabel) dom.btnLockLabel.textContent = msg(busy ? 'loading' : 'lock');
}

function setUnlockBusy(busy) {
  if (!dom.btnUnlock) return;
  dom.btnUnlock.disabled = !!busy;
  dom.btnUnlock.classList.toggle('is-busy', !!busy);
  dom.btnUnlock.setAttribute('aria-busy', busy ? 'true' : 'false');
  dom.btnUnlock.textContent = msg(busy ? 'loading' : 'unlock');
}

/** Store the auto-lock deadline advertised by getStatus (seconds -> timestamp). */
function applyAutoLockRemaining(status) {
  const remaining = status ? status.autoLockRemainingSeconds : null;
  if (typeof remaining === 'number' && isFinite(remaining) && remaining >= 0) {
    state.autoLockDeadline = Date.now() + remaining * 1000;
  } else {
    state.autoLockDeadline = null;
  }
}

async function refreshStatus(options) {
  const opts = options || {};
  const attempts = opts.retries === undefined ? 3 : opts.retries;
  let lastError = null;
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const status = await sendWithTimeout({ action: 'getStatus' }, STATUS_TIMEOUT_MS);
      if (isErrorResponse(status)) throw new Error(errorMessage(status));
      state.lastStatusAt = Date.now();
      applyStatus(status);
      return true;
    } catch (e) {
      lastError = e;
      // The service worker may be waking up / the daemon may be cold-starting.
      if (attempt < attempts - 1) await delay(1200);
    }
  }
  applyDisconnected(lastError);
  return false;
}

/** Drop every piece of plaintext state plus the rendered rows, so a locked
 *  popup keeps nothing readable in the DOM. */
function clearVaultData() {
  state.entries = [];
  state.rows.clear();
  state.searchQuery = '';
  state.generator = { result: '', error: null };
  state.health = { loading: false, data: null, error: null, expanded: {} };
  if (dom.searchInput) dom.searchInput.value = '';
  if (dom.entryList) dom.entryList.innerHTML = '';
  if (dom.vaultCount) dom.vaultCount.textContent = '';
  if (dom.pageBanner) {
    dom.pageBanner.hidden = true;
    dom.pageBanner.textContent = '';
  }
}

/** Switch to the locked presentation: unlock card on the vault tab, lock
 *  button gone, tab bar still reachable (the generator needs no vault). */
function enterLockedUi() {
  state.connection = 'locked';
  state.autoLockDeadline = null;
  state.tab = 'vault';
  updateStatusIndicator();
  activateTab('vault');
}

function applyStatus(status) {
  const locked = !!(status && status.locked);
  if (locked) {
    clearVaultData();
    enterLockedUi();
    return;
  }
  state.connection = 'connected';
  applyAutoLockRemaining(status);
  updateStatusIndicator();
  showMainView();
  activateTab(state.tab);
}

function applyDisconnected(error) {
  state.connection = 'disconnected';
  state.autoLockDeadline = null;
  updateStatusIndicator();
  showErrorView(describeError(error ? (error.message || String(error)) : ''));
}

/** Any "locked" error from the host: back to the unlock screen. */
function handleLocked() {
  if (state.connection === 'locked') return;
  clearVaultData();
  enterLockedUi();
  showToast(msg('sessionExpired'), '', 'warn');
}

/** Cheap, user-initiated re-sync of the auto-lock countdown (tab switches).
 *  Skipped when getStatus just ran, so opening the popup costs one call. */
async function syncAutoLock() {
  if (state.connection !== 'connected') return;
  if (Date.now() - state.lastStatusAt < AUTO_LOCK_SYNC_MIN_MS) return;
  try {
    const status = await sendWithTimeout({ action: 'getStatus' }, 4000);
    if (isErrorResponse(status)) {
      handleLockedResponse(status);
      return;
    }
    if (status && status.locked) {
      handleLocked();
      return;
    }
    state.lastStatusAt = Date.now();
    applyAutoLockRemaining(status);
    updateStatusTitle();
  } catch (e) {
    /* keep the previous estimate */
  }
}

// ─── Unlock flow ──────────────────────────────────────────

function showUnlockError(detail) {
  const raw = detail === undefined || detail === null ? '' : String(detail);
  // An outdated background service is not a wrong password — say so instead of
  // prefixing it with "failed to unlock".
  if (isStaleDaemonError(raw)) {
    dom.unlockError.textContent = msg('staleDaemon') + ' — ' + msg('restartApp');
    dom.unlockError.hidden = false;
    return;
  }
  const text = raw ? msg('failedToUnlock') + ': ' + raw : msg('failedToUnlock');
  dom.unlockError.textContent = text;
  dom.unlockError.hidden = false;
}

function hideUnlockError() {
  dom.unlockError.textContent = '';
  dom.unlockError.hidden = true;
}

async function submitUnlock() {
  const password = dom.masterPassword.value;
  if (!password || state.unlocking) return;
  state.unlocking = true;
  setUnlockBusy(true);
  hideUnlockError();
  try {
    const res = await sendWithTimeout({ action: 'unlock', password }, UNLOCK_TIMEOUT_MS);
    if (isErrorResponse(res)) throw new Error(errorMessage(res));
    dom.masterPassword.value = '';
    await refreshStatus({ retries: 2 });
  } catch (e) {
    showUnlockError((e && e.message) || '');
  } finally {
    state.unlocking = false;
    setUnlockBusy(false);
  }
}

/** Lock the vault.
 *
 *  Feedback contract (the button used to feel dead):
 *    click      → the popup switches to the locked view immediately, the
 *                 button turns into a spinner ring and shows `loading`
 *    success    → data cleared, `vaultLocked` toast (success tone)
 *    failure    → the previous view is restored, the button becomes clickable
 *                 again, and the toast names the real cause (outdated service,
 *                 timeout, or unreachable host) instead of a generic error.
 */
async function lockVault() {
  if (state.locking || state.connection !== 'connected') return;
  state.locking = true;
  const previous = { connection: state.connection, tab: state.tab };
  setLockBusy(true);
  enterLockedUi(); // optimistic: the click must be visible instantly

  try {
    const res = await sendWithTimeout({ action: 'lock' }, LOCK_TIMEOUT_MS);
    if (isErrorResponse(res)) throw new Error(errorMessage(res));
    clearVaultData();
    showToast(msg('vaultLocked'), '', 'success');
  } catch (e) {
    const desc = describeError(e && e.message);
    restoreAfterFailedLock(previous, desc);
  } finally {
    state.locking = false;
    setLockBusy(false);
  }
}

/** Roll the optimistic lock back: the vault is still open, so show it again
 *  and explain why the click did not take effect. */
function restoreAfterFailedLock(previous, desc) {
  state.connection = previous && previous.connection ? previous.connection : 'connected';
  const tab = previous && TABS.indexOf(previous.tab) !== -1 ? previous.tab : 'vault';
  state.tab = tab;
  updateStatusIndicator();
  if (state.connection === 'connected') {
    showMainView();
    activateTab(tab);
  } else if (state.connection === 'locked') {
    enterLockedUi();
  } else {
    showErrorView(desc);
  }
  showToast(desc.title, desc.detail, desc.tone);
}

// ─── Tabs ─────────────────────────────────────────────────

/** Roving keyboard navigation for the segmented tab bar (role="tablist"). */
function onTabKeydown(event) {
  const key = event.key;
  if (key !== 'ArrowRight' && key !== 'ArrowLeft' && key !== 'Home' && key !== 'End') return;
  event.preventDefault();
  const current = Math.max(0, TABS.indexOf(state.tab));
  let next = current;
  if (key === 'ArrowRight') next = (current + 1) % TABS.length;
  else if (key === 'ArrowLeft') next = (current + TABS.length - 1) % TABS.length;
  else if (key === 'Home') next = 0;
  else next = TABS.length - 1;
  const btn = dom.tabs[next];
  if (!btn) return;
  activateTab(btn.dataset.tab);
  try {
    btn.focus();
  } catch (e) {
    /* focus is best-effort */
  }
}

function activateTab(tab) {
  const target = TABS.indexOf(tab) === -1 ? 'vault' : tab;
  state.tab = target;
  dom.tabs.forEach(btn => {
    const active = btn.dataset.tab === target;
    btn.classList.toggle('active', active);
    btn.setAttribute('aria-selected', active ? 'true' : 'false');
  });
  Object.keys(dom.panels).forEach(key => {
    dom.panels[key].hidden = key !== target;
  });

  if (state.connection === 'locked') {
    // Vault tab = unlock form; generator works without the vault (contract
    // 2.1) and health shows the healthLocked hint.
    if (target === 'vault') {
      showUnlockView();
    } else {
      showMainView();
      if (target === 'generator') {
        syncGeneratorAvailability(readGeneratorOptions());
        if (!state.generator.result) generatePassword();
      } else {
        dom.btnHealthRefresh.disabled = true;
        renderHealth();
      }
    }
    return;
  }
  if (state.connection !== 'connected') return;

  showMainView();
  if (target === 'vault') {
    reloadVault();
    refreshPageMatch();
  } else if (target === 'generator') {
    syncGeneratorAvailability(readGeneratorOptions());
    // Generate once on entering the tab.
    if (!state.generator.result) generatePassword();
  } else if (target === 'health') {
    loadHealth();
  }
  syncAutoLock();
}

// ─── Vault tab ────────────────────────────────────────────

function rowStateOf(entry) {
  const id = entry && entry.id !== undefined && entry.id !== null ? String(entry.id) : '';
  let rowState = state.rows.get(id);
  if (!rowState) {
    rowState = { showPassword: false, totp: null };
    state.rows.set(id, rowState);
  }
  return rowState;
}

function loadingHtml() {
  return '<div class="center-state"><div class="spinner"></div><div>' +
    escapeHtml(msg('loading')) + '</div></div>';
}

function emptyStateHtml(icon, title, detail) {
  let html = '<div class="empty-state">' +
    '<div class="icon">' + escapeHtml(icon) + '</div>' +
    '<div class="empty-title">' + escapeHtml(title) + '</div>';
  if (detail) {
    html += '<div class="empty-detail">' + escapeHtml(detail) + '</div>';
  }
  return html + '</div>';
}

function setVaultLoading() {
  dom.entryList.innerHTML = loadingHtml();
}

async function reloadVault() {
  if (state.connection !== 'connected') return;
  if (state.searchQuery) {
    return searchEntries(state.searchQuery);
  }
  return loadEntries();
}

async function loadEntries() {
  if (!state.entries.length) setVaultLoading();
  try {
    const entries = await sendWithTimeout({ action: 'getAllCredentials' });
    if (isErrorResponse(entries)) {
      if (handleLockedResponse(entries)) return;
      throw new Error(errorMessage(entries));
    }
    state.entries = Array.isArray(entries) ? entries : [];
    renderEntries();
  } catch (e) {
    if (isLockedError(e && e.message)) {
      handleLocked();
      return;
    }
    const desc = describeError(e && e.message);
    dom.entryList.innerHTML = emptyStateHtml('⚠️', desc.title, desc.detail);
  }
}

async function searchEntries(query) {
  try {
    const entries = await sendWithTimeout({ action: 'searchCredentials', query: query });
    if (isErrorResponse(entries)) {
      if (handleLockedResponse(entries)) return;
      throw new Error(errorMessage(entries));
    }
    state.entries = Array.isArray(entries) ? entries : [];
    renderEntries();
  } catch (e) {
    if (isLockedError(e && e.message)) {
      handleLocked();
      return;
    }
    const desc = describeError(e && e.message);
    const title = desc.kind === 'unreachable' ? msg('searchFailed') : desc.title;
    dom.entryList.innerHTML = emptyStateHtml('⚠️', title, desc.detail);
  }
}

function onSearchInput() {
  if (searchTimer) clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    const query = dom.searchInput.value.trim();
    state.searchQuery = query;
    if (state.connection !== 'connected') return;
    if (query) searchEntries(query);
    else loadEntries();
  }, SEARCH_DEBOUNCE_MS);
}

/** Does the current page match any vault entry? (drives the noMatchForPage banner) */
async function refreshPageMatch() {
  try {
    const tab = await getActiveTab();
    const url = tab && typeof tab.url === 'string' ? tab.url : '';
    if (!/^https?:/i.test(url)) {
      state.pageMatch = { known: false, hasMatch: false };
      updateVaultMeta();
      return;
    }
    const matches = await sendWithTimeout({ action: 'getCredentials', url: url }, 6000);
    if (isErrorResponse(matches)) {
      state.pageMatch = { known: false, hasMatch: false };
    } else {
      state.pageMatch = { known: true, hasMatch: Array.isArray(matches) && matches.length > 0 };
    }
  } catch (e) {
    state.pageMatch = { known: false, hasMatch: false };
  }
  updateVaultMeta();
}

function updateVaultMeta() {
  if (!dom.vaultCount) return;
  const count = state.entries.length;
  dom.vaultCount.textContent = count ? msg('entriesCount', [String(count)]) : '';
  const showBanner = !state.searchQuery && count > 0 &&
    state.pageMatch.known && !state.pageMatch.hasMatch;
  dom.pageBanner.hidden = !showBanner;
  dom.pageBanner.textContent = showBanner ? msg('noMatchForPage') : '';
}

function iconButtonHtml(action, icon, title, extraClass) {
  const safeTitle = escapeAttr(title);
  return '<button type="button" class="icon-btn' + (extraClass || '') +
    '" data-action="' + escapeAttr(action) + '" title="' + safeTitle +
    '" aria-label="' + safeTitle + '">' + escapeHtml(icon) + '</button>';
}

function rowButtonsHtml(entry, rowState) {
  const buttons = [
    iconButtonHtml('copy-username', '👤', msg('copyUsername')),
    iconButtonHtml('copy-password', '🗝️', msg('copyPassword')),
    iconButtonHtml('copy-url', '🔗', msg('copyUrl')),
    iconButtonHtml(
      'toggle-password',
      rowState.showPassword ? '🙈' : '👁️',
      rowState.showPassword ? msg('hidePassword') : msg('showPassword')
    )
  ];
  if (entry && entry.hasTotp) {
    buttons.push(iconButtonHtml('totp', '⏱️', msg('totpLabel'), rowState.totp ? ' active' : ''));
  }
  return buttons.join('');
}

function rowExtraHtml(entry, rowState) {
  let html = '';
  if (rowState.showPassword) {
    html += '<div class="entry-extra">' +
      '<code class="secret">' + escapeHtml(entry.password || '') + '</code>' +
      iconButtonHtml('copy-password', '📋', msg('copyPassword')) +
      '</div>';
  }
  if (rowState.totp) {
    html += '<div class="entry-extra">' +
      '<span class="extra-label">' + escapeHtml(msg('totpLabel')) + '</span>';
    if (rowState.totp.loading) {
      html += '<span class="totp-error">' + escapeHtml(msg('loading')) + '</span>';
    } else if (rowState.totp.error || !rowState.totp.code) {
      html += '<span class="totp-error">' + escapeHtml(msg('totpUnavailable')) + '</span>';
    } else {
      const period = rowState.totp.period || DEFAULT_TOTP_PERIOD;
      const pct = clamp(Math.round((rowState.totp.remaining / period) * 100), 0, 100);
      html += '<span class="totp-code">' + escapeHtml(rowState.totp.code) + '</span>' +
        '<span class="totp-countdown" aria-hidden="true">⏱ <span data-totp-remaining>' +
        escapeHtml(String(rowState.totp.remaining)) + '</span></span>' +
        iconButtonHtml('copy-totp', '📋', msg('copyTotp')) +
        '<div class="totp-bar"><div class="totp-bar-fill" data-totp-bar style="width:' + pct + '%"></div></div>';
    }
    html += '</div>';
  }
  return html;
}

function entryRowHtml(entry, index) {
  const rowState = rowStateOf(entry);
  const name = escapeHtml(entry && entry.name ? entry.name : '');
  const username = escapeHtml(entry && entry.username ? entry.username : '');
  return '<div class="entry" data-index="' + index + '">' +
    '<div class="entry-item" data-action="fill" title="' + escapeAttr(msg('fillOnPage')) + '">' +
    '<div class="entry-icon">' + escapeHtml(getEntryIcon(entry && entry.name)) + '</div>' +
    '<div class="entry-info">' +
    '<div class="entry-name">' + (name || '—') + '</div>' +
    '<div class="entry-username">' + username + '</div>' +
    '<div class="entry-url">' + escapeHtml(truncateUrl(entry && entry.url)) + '</div>' +
    '</div>' +
    '<div class="entry-actions">' + rowButtonsHtml(entry, rowState) + '</div>' +
    '</div>' +
    rowExtraHtml(entry, rowState) +
    '</div>';
}

function renderEntries() {
  const scrollTop = dom.entryList.scrollTop;
  if (!state.entries.length) {
    dom.entryList.innerHTML = emptyStateHtml('📭', msg('noPasswordsFound'), msg('addPasswordsHint'));
  } else {
    dom.entryList.innerHTML = state.entries.map(entryRowHtml).join('');
  }
  updateVaultMeta();
  dom.entryList.scrollTop = scrollTop;
}

function onEntryListClick(event) {
  const target = event.target;
  if (!target || !target.closest) return;
  const actionEl = target.closest('[data-action]');
  if (!actionEl) return;
  const wrapper = actionEl.closest('[data-index]');
  if (!wrapper) return;
  const entry = state.entries[toInt(wrapper.dataset.index, -1)];
  if (!entry) return;
  const action = actionEl.dataset.action;

  if (action === 'fill') {
    fillEntry(entry);
  } else if (action === 'copy-username') {
    copyValue(entry.username, 'copiedUsername');
  } else if (action === 'copy-password') {
    copyValue(entry.password, 'copiedPassword');
  } else if (action === 'copy-url') {
    copyValue(entry.url, 'copiedUrl');
  } else if (action === 'copy-totp') {
    const rowState = rowStateOf(entry);
    copyValue(rowState.totp ? rowState.totp.code : '', 'copiedTotp');
  } else if (action === 'toggle-password') {
    const rowState = rowStateOf(entry);
    rowState.showPassword = !rowState.showPassword;
    renderEntries();
  } else if (action === 'totp') {
    toggleTotp(entry);
  }
}

// ─── TOTP (row display, local countdown) ──────────────────

/** Ask the host for a fresh code. Never throws: returns { ok, code, ... }. */
async function requestTotp(entry) {
  try {
    const res = await sendWithTimeout({ action: 'getTotp', entryId: entry.id });
    if (isErrorResponse(res)) {
      if (isLockedError(errorMessage(res))) handleLocked();
      return { ok: false };
    }
    const code = res && res.totp !== undefined && res.totp !== null ? String(res.totp) : '';
    if (!code) return { ok: false };
    const period = clamp(toInt(res.period, DEFAULT_TOTP_PERIOD), 1, 300);
    const remaining = clamp(toInt(res.remaining, period), 1, period);
    return { ok: true, code: code, period: period, remaining: remaining };
  } catch (e) {
    if (isLockedError(e && e.message)) handleLocked();
    return { ok: false };
  }
}

async function toggleTotp(entry) {
  const rowState = rowStateOf(entry);
  if (rowState.totp) {
    rowState.totp = null;
    renderEntries();
    return;
  }
  rowState.totp = { loading: true, code: null, remaining: 0, period: DEFAULT_TOTP_PERIOD, error: false };
  renderEntries();
  const result = await requestTotp(entry);
  const current = rowStateOf(entry);
  if (result.ok) {
    current.totp = {
      loading: false,
      code: result.code,
      remaining: result.remaining,
      period: result.period,
      error: false
    };
  } else {
    current.totp = { loading: false, code: null, remaining: 0, period: DEFAULT_TOTP_PERIOD, error: true };
  }
  renderEntries();
}

/** Local 1s countdown; refetches the code when it hits zero. */
function tickTotp() {
  const wrappers = dom.entryList.querySelectorAll('.entry[data-index]');
  wrappers.forEach(wrapper => {
    const entry = state.entries[toInt(wrapper.dataset.index, -1)];
    if (!entry) return;
    const rowState = state.rows.get(String(entry.id));
    if (!rowState || !rowState.totp || rowState.totp.loading || rowState.totp.error) return;
    rowState.totp.remaining -= 1;
    if (rowState.totp.remaining <= 0) {
      toggleTotpRefresh(entry);
      return;
    }
    const counter = wrapper.querySelector('[data-totp-remaining]');
    if (counter) counter.textContent = String(rowState.totp.remaining);
    const bar = wrapper.querySelector('[data-totp-bar]');
    if (bar) {
      const period = rowState.totp.period || DEFAULT_TOTP_PERIOD;
      bar.style.width = clamp(Math.round((rowState.totp.remaining / period) * 100), 0, 100) + '%';
    }
  });
}

async function toggleTotpRefresh(entry) {
  const rowState = rowStateOf(entry);
  if (!rowState.totp || rowState.totp.loading) return;
  rowState.totp.loading = true;
  const result = await requestTotp(entry);
  const current = rowStateOf(entry);
  if (!current.totp) return;
  if (result.ok) {
    current.totp = {
      loading: false,
      code: result.code,
      remaining: result.remaining,
      period: result.period,
      error: false
    };
  } else {
    current.totp = { loading: false, code: null, remaining: 0, period: DEFAULT_TOTP_PERIOD, error: true };
  }
  renderEntries();
}

// ─── Fill ─────────────────────────────────────────────────

async function fillEntry(entry) {
  if (!entry) return;
  let totp = null;
  // Entry carries hasTotp only; the code must come from getTotp. The content
  // script ignores the field when the page has no TOTP input (expected).
  if (entry.hasTotp) {
    const result = await requestTotp(entry);
    if (result.ok) totp = result.code;
  }

  const tab = await getActiveTab();
  if (!tab || typeof tab.id !== 'number') {
    await fillFallback(entry);
    return;
  }

  const credentials = {
    username: entry.username || '',
    password: entry.password || ''
  };
  if (totp) credentials.totp = totp;

  try {
    const response = await sendToTabWithTimeout(tab.id, {
      action: 'fillCredentials',
      credentials: credentials
    });
    if (response && response.success === false) {
      // A frame accepted the message but could not fill anything (its form did
      // not match): report the fill failure instead of pretending the page is
      // restricted, and do NOT overwrite the clipboard in that case.
      showToast(msg('fillFailed'), '', 'error');
      return;
    }
    showToast(msg('fillSuccess'), '', 'success');
    setTimeout(() => window.close(), CLOSE_AFTER_FILL_MS);
  } catch (e) {
    // No frame answered at all: restricted page (chrome://, Web Store, PDF
    // viewer, ...), a page without any login form, or no content script. Tell
    // the user and fall back to copying the password.
    await fillFallback(entry);
  }
}

async function fillFallback(entry) {
  const copied = await writeClipboard(entry.password || '');
  if (copied) {
    showToast(msg('restrictedPage'), msg('fillFallbackCopied'), 'warn');
  } else {
    showToast(msg('restrictedPage'), '', 'warn');
  }
}

// ─── Generator tab ────────────────────────────────────────

function readGeneratorOptions() {
  return {
    length: clamp(toInt(dom.genLength.value, 16), GENERATOR_MIN_LENGTH, GENERATOR_MAX_LENGTH),
    useUpper: dom.genUpper.checked,
    useLower: dom.genLower.checked,
    useNumbers: dom.genNumbers.checked,
    useSymbols: dom.genSymbols.checked
  };
}

function hasGeneratorCharset(options) {
  return options.useUpper || options.useLower || options.useNumbers || options.useSymbols;
}

/** The contract has no "pick at least one option" string, so the last checked
 *  character set is locked instead: the empty state stays unreachable, and the
 *  buttons are disabled defensively if it ever happens. */
function syncGeneratorAvailability(options) {
  const boxes = [dom.genUpper, dom.genLower, dom.genNumbers, dom.genSymbols];
  const checkedCount = boxes.filter(box => box.checked).length;
  boxes.forEach(box => {
    box.disabled = checkedCount === 1 && box.checked;
  });
  const any = hasGeneratorCharset(options);
  dom.btnRegenerate.disabled = !any;
  dom.btnCopyGenerated.disabled = !any || !state.generator.result;
}

function renderGeneratorResult() {
  const result = state.generator.result;
  dom.genResult.textContent = result || '—';
  dom.genResult.classList.toggle('is-placeholder', !result);
  const err = state.generator.error;
  if (err) {
    dom.genErrorTitle.textContent = err.title || msg('cannotConnect');
    dom.genErrorDetail.textContent = err.detail || '';
    dom.genErrorDetail.hidden = !err.detail;
    dom.genError.hidden = false;
  } else {
    dom.genErrorTitle.textContent = '';
    dom.genErrorDetail.textContent = '';
    dom.genErrorDetail.hidden = true;
    dom.genError.hidden = true;
  }
  syncGeneratorAvailability(readGeneratorOptions());
}

async function generatePassword() {
  const options = readGeneratorOptions();
  syncGeneratorAvailability(options);
  if (!hasGeneratorCharset(options)) {
    state.generator.result = '';
    state.generator.error = null;
    renderGeneratorResult();
    return;
  }
  try {
    const res = await sendWithTimeout({ action: 'generatePassword', options: options });
    if (isErrorResponse(res)) {
      if (handleLockedResponse(res)) return;
      throw new Error(errorMessage(res));
    }
    state.generator.result = res && typeof res.password === 'string' ? res.password : '';
    state.generator.error = null;
  } catch (e) {
    if (isLockedError(e && e.message)) {
      handleLocked();
      return;
    }
    state.generator.result = '';
    state.generator.error = describeError(e && e.message);
  }
  renderGeneratorResult();
}

function onGeneratorLengthInput() {
  dom.genLengthValue.textContent = String(clamp(
    toInt(dom.genLength.value, 16),
    GENERATOR_MIN_LENGTH,
    GENERATOR_MAX_LENGTH
  ));
  if (generatorTimer) clearTimeout(generatorTimer);
  generatorTimer = setTimeout(generatePassword, GENERATOR_DEBOUNCE_MS);
}

function onGeneratorOptionChange() {
  syncGeneratorAvailability(readGeneratorOptions());
  if (generatorTimer) clearTimeout(generatorTimer);
  generatorTimer = setTimeout(generatePassword, GENERATOR_DEBOUNCE_MS);
}

// ─── Health tab ───────────────────────────────────────────

function healthItemList(value) {
  if (!Array.isArray(value)) return [];
  const names = [];
  value.forEach(item => {
    let name = '';
    if (item && typeof item === 'object') {
      const raw = firstDefined(item.entryName, item.name, item.title, item.entryId, item.id);
      name = raw === null ? '' : String(raw);
    } else if (item !== undefined && item !== null) {
      name = String(item);
    }
    if (name) names.push(name);
  });
  return names;
}

function normalizeHealthLevel(value, score) {
  if (typeof value === 'string') {
    const lower = value.toLowerCase();
    if (lower.indexOf('good') !== -1) return 'good';
    if (lower.indexOf('fair') !== -1) return 'fair';
    if (lower.indexOf('poor') !== -1) return 'poor';
  }
  if (typeof value === 'number' && isFinite(value)) {
    // HealthLevel enum index order: good, fair, poor
    return value === 0 ? 'good' : value === 1 ? 'fair' : 'poor';
  }
  return score >= 80 ? 'good' : score >= 50 ? 'fair' : 'poor';
}

/** Tolerant normaliser: accepts the Dart HealthReport field names as well as a
 *  couple of obvious aliases, so a naming mismatch degrades instead of breaking. */
function normalizeHealthReport(raw) {
  const data = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const score = clamp(toInt(firstDefined(data.score, data.healthScore), 0), 0, 100);

  const weakNames = healthItemList(firstDefined(data.weakPasswords, data.weakEntries, data.weak));
  const reusedNames = healthItemList(firstDefined(data.reusedPasswords, data.reusedEntries, data.reused));
  const noTotpNames = healthItemList(firstDefined(data.noTotpEntries, data.noTotp));
  const noUrlNames = healthItemList(firstDefined(data.noUrlEntries, data.noUrl));

  const totalRaw = firstDefined(data.totalEntries, data.total, data.entryCount);

  return {
    score: score,
    level: normalizeHealthLevel(firstDefined(data.level, data.grade), score),
    totalEntries: totalRaw === null ? null : toInt(totalRaw, null),
    categories: [
      {
        key: 'weak',
        labelKey: 'healthWeak',
        count: toInt(firstDefined(data.weakPasswordCount, data.weakCount), weakNames.length),
        names: weakNames
      },
      {
        key: 'reused',
        labelKey: 'healthReused',
        count: toInt(firstDefined(data.reusedEntryCount, data.reusedCount), reusedNames.length),
        names: reusedNames
      },
      {
        key: 'noTotp',
        labelKey: 'healthNoTotp',
        count: toInt(firstDefined(data.noTotpCount), noTotpNames.length),
        names: noTotpNames
      },
      {
        key: 'noUrl',
        labelKey: 'healthNoUrl',
        count: toInt(firstDefined(data.noUrlCount), noUrlNames.length),
        names: noUrlNames
      }
    ]
  };
}

function healthLevelColor(level) {
  if (level === 'good') return '#a6e3a1';
  if (level === 'fair') return '#f9e2af';
  return '#f38ba8';
}

function renderHealth() {
  if (!dom.healthBody) return;

  if (state.connection === 'locked') {
    dom.healthBody.innerHTML = emptyStateHtml('🔒', msg('healthLocked'), '');
    return;
  }
  if (state.health.loading && !state.health.data) {
    dom.healthBody.innerHTML = loadingHtml();
    return;
  }
  if (state.health.error) {
    const desc = state.health.error;
    dom.healthBody.innerHTML = emptyStateHtml('⚠️', desc.title, desc.detail);
    return;
  }
  const data = state.health.data;
  if (!data) {
    dom.healthBody.innerHTML = '';
    return;
  }
  if (data.totalEntries === 0) {
    dom.healthBody.innerHTML = emptyStateHtml('📭', msg('healthEmpty'), '');
    return;
  }

  const levelLabel = data.level === 'good' ? msg('healthGood')
    : data.level === 'fair' ? msg('healthFair') : msg('healthPoor');
  const color = healthLevelColor(data.level);

  let html = '<div class="health-score">' +
    '<div class="score-label">' + escapeHtml(msg('healthScore')) + '</div>' +
    '<div class="score-value" style="color:' + color + '">' + escapeHtml(String(data.score)) + '</div>' +
    '<div class="score-bar"><div class="score-bar-fill" style="width:' + data.score +
    '%;background:' + color + '"></div></div>' +
    '<div class="score-level-row">' +
    '<span class="score-level-label">' + escapeHtml(msg('healthLevel')) + '</span>' +
    '<span class="score-level" style="color:' + color + '">' + escapeHtml(levelLabel) + '</span>' +
    '</div>' +
    '</div>';

  if (data.score >= 100) {
    html += '<div class="health-clear">✅ ' + escapeHtml(msg('healthAllClear')) + '</div>';
  }
  if (data.totalEntries !== null) {
    html += '<div class="health-total">' +
      escapeHtml(msg('entriesCount', [String(data.totalEntries)])) + '</div>';
  }

  html += '<div class="health-list">';
  data.categories.forEach(category => {
    const expanded = !!state.health.expanded[category.key];
    const expandable = category.count > 0 && category.names.length > 0;
    html += '<div class="health-cat' + (category.count > 0 ? ' has-issues' : '') + '">' +
      '<button type="button" class="health-head" data-action="toggle-health" data-cat="' +
      escapeAttr(category.key) + '"' + (expandable ? '' : ' disabled') + '>' +
      '<span class="health-name">' + escapeHtml(msg(category.labelKey)) + '</span>' +
      '<span class="health-count">' + escapeHtml(String(category.count)) + '</span>' +
      (expandable ? '<span class="health-chevron">' + (expanded ? '▾' : '▸') + '</span>' : '') +
      '</button>';
    if (expanded && expandable) {
      html += '<ul class="health-entries">' +
        category.names.map(name => '<li>' + escapeHtml(name) + '</li>').join('') +
        '</ul>';
    }
    html += '</div>';
  });
  html += '</div>';

  dom.healthBody.innerHTML = html;
}

async function loadHealth() {
  if (state.connection === 'locked') {
    renderHealth();
    return;
  }
  state.health.loading = true;
  state.health.error = null;
  dom.btnHealthRefresh.disabled = true;
  if (!state.health.data) renderHealth();
  try {
    const res = await sendWithTimeout({ action: 'getHealthReport' });
    if (isErrorResponse(res)) {
      if (handleLockedResponse(res)) return;
      state.health.error = describeError(errorMessage(res));
      state.health.data = null;
    } else {
      state.health.data = normalizeHealthReport(res);
      state.health.error = null;
    }
  } catch (e) {
    if (isLockedError(e && e.message)) {
      handleLocked();
      return;
    }
    state.health.error = describeError(e && e.message);
    state.health.data = null;
  }
  state.health.loading = false;
  dom.btnHealthRefresh.disabled = false;
  renderHealth();
}

function onHealthBodyClick(event) {
  const target = event.target;
  if (!target || !target.closest) return;
  const head = target.closest('[data-action="toggle-health"]');
  if (!head || head.disabled) return;
  const category = head.dataset.cat;
  if (!category) return;
  state.health.expanded[category] = !state.health.expanded[category];
  renderHealth();
}

// ─── Wiring ───────────────────────────────────────────────

function cacheDom() {
  dom.statusPill = byId('statusPill');
  dom.statusDot = byId('statusDot');
  dom.statusText = byId('statusText');
  dom.btnLock = byId('btnLock');
  dom.btnLockLabel = byId('btnLockLabel');
  dom.tabBar = byId('tabBar');
  dom.tabs = Array.from(document.querySelectorAll('.tab[data-tab]'));
  dom.loadingView = byId('loadingView');
  dom.errorView = byId('errorView');
  dom.errorTitle = byId('errorTitle');
  dom.errorDetail = byId('errorDetail');
  dom.btnRetry = byId('btnRetry');
  dom.unlockView = byId('unlockView');
  dom.unlockError = byId('unlockError');
  dom.masterPassword = byId('masterPassword');
  dom.btnUnlock = byId('btnUnlock');
  dom.mainView = byId('mainView');
  dom.panels = { vault: byId('panelVault'), generator: byId('panelGenerator'), health: byId('panelHealth') };
  dom.searchInput = byId('searchInput');
  dom.entryList = byId('entryList');
  dom.vaultCount = byId('vaultCount');
  dom.pageBanner = byId('pageBanner');
  dom.genResult = byId('genResult');
  dom.genError = byId('genError');
  dom.genErrorTitle = byId('genErrorTitle');
  dom.genErrorDetail = byId('genErrorDetail');
  dom.genLength = byId('genLength');
  dom.genLengthValue = byId('genLengthValue');
  dom.genUpper = byId('genUpper');
  dom.genLower = byId('genLower');
  dom.genNumbers = byId('genNumbers');
  dom.genSymbols = byId('genSymbols');
  dom.btnRegenerate = byId('btnRegenerate');
  dom.btnCopyGenerated = byId('btnCopyGenerated');
  dom.btnHealthRefresh = byId('btnHealthRefresh');
  dom.healthBody = byId('healthBody');
  dom.toast = byId('toast');
  dom.toastIcon = byId('toastIcon');
  dom.toastText = byId('toastText');
  dom.toastDetail = byId('toastDetail');
}

function bindEvents() {
  dom.tabs.forEach(btn => {
    btn.addEventListener('click', () => activateTab(btn.dataset.tab));
  });
  dom.tabBar.addEventListener('keydown', onTabKeydown);
  if (dom.btnRetry) dom.btnRetry.addEventListener('click', onRetry);
  dom.btnLock.addEventListener('click', lockVault);
  dom.btnUnlock.addEventListener('click', submitUnlock);
  dom.masterPassword.addEventListener('keydown', event => {
    if (event.key === 'Enter') {
      event.preventDefault();
      submitUnlock();
    }
  });
  dom.searchInput.addEventListener('input', onSearchInput);
  dom.entryList.addEventListener('click', onEntryListClick);
  dom.genLength.addEventListener('input', onGeneratorLengthInput);
  [dom.genUpper, dom.genLower, dom.genNumbers, dom.genSymbols].forEach(box => {
    box.addEventListener('change', onGeneratorOptionChange);
  });
  dom.btnRegenerate.addEventListener('click', () => generatePassword());
  dom.btnCopyGenerated.addEventListener('click', () => {
    copyValue(state.generator.result, 'copiedGenerated');
  });
  dom.btnHealthRefresh.addEventListener('click', loadHealth);
  dom.healthBody.addEventListener('click', onHealthBodyClick);

  window.addEventListener('unhandledrejection', event => {
    const reason = event && event.reason;
    console.error('EasyPass popup: unhandled rejection', reason && (reason.message || reason));
    if (event && typeof event.preventDefault === 'function') event.preventDefault();
  });
  window.addEventListener('error', event => {
    console.error('EasyPass popup: uncaught error', event && event.message);
  });
}

function startTimers() {
  // Refresh the "auto-locks in N min" tooltip once a minute; when the deadline
  // passes, re-ask the host (the session may already be gone).
  autoLockTimer = setInterval(() => {
    if (state.connection !== 'connected') return;
    updateStatusTitle();
    if (state.autoLockDeadline !== null && state.autoLockDeadline - Date.now() <= 0) {
      refreshStatus({ retries: 1 });
    }
  }, 60000);

  // TOTP codes tick down locally; refetch happens in tickTotp().
  totpTickTimer = setInterval(tickTotp, 1000);
}

function init() {
  cacheDom();
  applyI18n();
  bindEvents();
  startTimers();
  dom.genLengthValue.textContent = String(toInt(dom.genLength.value, 16));
  syncGeneratorAvailability(readGeneratorOptions());
  activateTab('vault');
  showLoadingView();
  refreshStatus();
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
