// EasyPass Browser Extension - Popup Script

const statusDot = document.getElementById('statusDot');
const searchInput = document.getElementById('searchInput');
const contentDiv = document.getElementById('content');

// ─── i18n (Internationalization) ──────────────────────────

function applyI18n() {
  document.querySelectorAll('[data-i18n]').forEach(el => {
    const key = el.dataset.i18n;
    if (key) el.textContent = chrome.i18n.getMessage(key);
  });
  document.querySelectorAll('[data-i18n-placeholder]').forEach(el => {
    const key = el.dataset.i18nPlaceholder;
    if (key) el.placeholder = chrome.i18n.getMessage(key);
  });
  document.querySelectorAll('[data-i18n-title]').forEach(el => {
    const key = el.dataset.i18nTitle;
    if (key) el.title = chrome.i18n.getMessage(key);
  });
  // Adapt the document language to the browser UI language
  document.documentElement.lang = chrome.i18n.getUILanguage();
}

applyI18n();

// ─── Initialize ───────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  // checkStatus drives the whole flow: locked -> unlock screen,
  // unlocked -> entry list, failure -> error state. loadEntries is only
  // called once the host reports unlocked.
  checkStatus();
  
  searchInput.addEventListener('input', (e) => {
    const query = e.target.value.trim();
    if (query) {
      searchEntries(query);
    } else {
      loadEntries();
    }
  });
  
  document.getElementById('btnGenerator').addEventListener('click', openGenerator);
  document.getElementById('btnOpenApp').addEventListener('click', openDesktopApp);
});

// The background script resolves with the payload on success and resolves
// with { error: message } on failure (native host unavailable, locked, ...).
function isErrorResponse(res) {
  return res && typeof res === 'object' && res.error !== undefined;
}

function errorMessage(res) {
  return res && res.error ? res.error : String(res);
}

// Popup-side timeout so a hung background/service-worker round-trip cannot
// leave the popup stuck on the spinner forever; the error text then shows
// exactly which stage stalled.
function sendWithTimeout(message, ms = 8000) {
  return Promise.race([
    chrome.runtime.sendMessage(message),
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error('background timeout after ' + ms + 'ms')), ms)
    )
  ]);
}

function showErrorState(detail) {
  contentDiv.innerHTML = `
    <div class="empty-state">
      <div class="icon">⚠️</div>
      <div>${chrome.i18n.getMessage('cannotConnect')}</div>
      <div style="margin-top: 8px; font-size: 12px;">${escapeHtml(detail || '')}</div>
    </div>
  `;
}

// ─── Check Connection Status ──────────────────────────────

async function checkStatus() {
  // Retry a few times: on the very first launch the service worker is
  // waking up and the daemon may still be cold-starting (bridge + daemon
  // startup takes a couple of seconds). Without retries the user would see
  // a timeout and have to close/reopen the popup once.
  let lastError = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const status = await sendWithTimeout({ action: 'getStatus' });
      if (isErrorResponse(status)) {
        throw new Error(errorMessage(status));
      }
      if (status && status.locked) {
        statusDot.className = 'status locked';
        statusDot.title = chrome.i18n.getMessage('vaultLocked');
        showLockedState();
      } else {
        statusDot.className = 'status connected';
        statusDot.title = chrome.i18n.getMessage('connected');
        loadEntries();
      }
      return;
    } catch (e) {
      lastError = e;
      if (attempt < 2) await new Promise(r => setTimeout(r, 1200));
    }
  }
  statusDot.className = 'status disconnected';
  statusDot.title = chrome.i18n.getMessage('statusDisconnected');
  showErrorState(lastError ? lastError.message : '');
}

// ─── Load Entries ─────────────────────────────────────────

async function loadEntries() {
  try {
    const entries = await sendWithTimeout({ action: 'getAllCredentials' });
    if (isErrorResponse(entries)) {
      throw new Error(errorMessage(entries));
    }
    renderEntries(entries);
  } catch (e) {
    contentDiv.innerHTML = `
      <div class="empty-state">
        <div class="icon">⚠️</div>
        <div>${chrome.i18n.getMessage('cannotConnect')}</div>
        <div style="margin-top: 8px; font-size: 12px;">${e.message}</div>
      </div>
    `;
  }
}

// ─── Search Entries ───────────────────────────────────────

async function searchEntries(query) {
  try {
    const entries = await sendWithTimeout({ 
      action: 'searchCredentials', 
      query 
    });
    if (isErrorResponse(entries)) {
      throw new Error(errorMessage(entries));
    }
    renderEntries(entries);
  } catch (e) {
    contentDiv.innerHTML = `<div class="empty-state"><div>${chrome.i18n.getMessage('searchFailed')}</div></div>`;
  }
}

// ─── Render Entry List ────────────────────────────────────

function renderEntries(entries) {
  if (!Array.isArray(entries) || entries.length === 0) {
    contentDiv.innerHTML = `
      <div class="empty-state">
        <div class="icon">📭</div>
        <div>${chrome.i18n.getMessage('noPasswordsFound')}</div>
        <div style="margin-top: 8px; font-size: 12px;">${chrome.i18n.getMessage('addPasswordsHint')}</div>
      </div>
    `;
    return;
  }
  
  let html = '<div class="entry-list">';
  entries.forEach(entry => {
    const icon = getEntryIcon(entry.name);
    html += `
      <div class="entry-item" data-id="${entry.id}">
        <div class="entry-icon">${icon}</div>
        <div class="entry-info">
          <div class="entry-name">${escapeHtml(entry.name)}</div>
          <div class="entry-username">${escapeHtml(entry.username || '')}</div>
          <div class="entry-url">${escapeHtml(truncateUrl(entry.url || ''))}</div>
        </div>
      </div>
    `;
  });
  html += '</div>';
  contentDiv.innerHTML = html;
  
  // Add click handlers
  document.querySelectorAll('.entry-item').forEach(item => {
    item.addEventListener('click', async () => {
      const id = item.dataset.id;
      fillCredentialsOnCurrentTab(id);
    });
  });
}

// ─── Fill Credentials on Current Tab ──────────────────────

async function fillCredentialsOnCurrentTab(entryId) {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    
    // Request full credentials from native host
    const credentials = await sendWithTimeout({
      action: 'getCredentials',
      url: tab.url
    });
    if (isErrorResponse(credentials)) {
      throw new Error(errorMessage(credentials));
    }
    
    // Find the matching entry
    if (!Array.isArray(credentials)) return;
    const entry = credentials.find(c => c.id === entryId);
    
    if (entry && tab.id) {
      await chrome.tabs.sendMessage(tab.id, {
        action: 'fillCredentials',
        credentials: {
          username: entry.username,
          password: entry.password
        }
      });
      window.close(); // Close popup after filling
    }
  } catch (e) {
    console.error(chrome.i18n.getMessage('logFailedToFill'), e);
  }
}

// ─── Show Locked State ────────────────────────────────────

function showLockedState() {
  contentDiv.innerHTML = `
    <div style="padding: 32px 16px; text-align: center;">
      <div style="font-size: 48px; margin-bottom: 12px;">🔒</div>
      <div style="font-weight: 600; margin-bottom: 8px;">${chrome.i18n.getMessage('vaultLocked')}</div>
      <div style="font-size: 12px; color: #6c7086; margin-bottom: 16px;">
        ${chrome.i18n.getMessage('unlockHint')}
      </div>
      <input type="password" id="masterPassword" 
             placeholder="${chrome.i18n.getMessage('masterPassword')}" 
             style="width: 100%; padding: 8px 12px; border: 1px solid #313244; 
                    border-radius: 8px; background: #313244; color: #cdd6f4; 
                    font-size: 14px; outline: none; margin-bottom: 8px;" />
      <button id="btnUnlock" class="btn btn-primary" style="width: 100%;">
        ${chrome.i18n.getMessage('unlock')}
      </button>
    </div>
  `;
  
  document.getElementById('btnUnlock').addEventListener('click', async () => {
    const password = document.getElementById('masterPassword').value;
    try {
      await chrome.runtime.sendMessage({ action: 'unlock', password });
      await checkStatus(); // refresh in place: now unlocked, show the list
    } catch (e) {
      alert(chrome.i18n.getMessage('failedToUnlock') + ': ' + e.message);
    }
  });
}

// ─── Actions ──────────────────────────────────────────────

function openGenerator() {
  chrome.tabs.create({ url: chrome.runtime.getURL('popup/popup.html?generator=1') });
}

function openDesktopApp() {
  chrome.runtime.sendMessage({ action: 'getStatus' }).catch(() => {});
  // Can't directly open the app from the extension
  alert(chrome.i18n.getMessage('openDesktopApp'));
}

// ─── Helpers ──────────────────────────────────────────────

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

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

function truncateUrl(url) {
  try {
    const u = new URL(url);
    return u.hostname;
  } catch {
    return url;
  }
}