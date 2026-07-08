// EasyPass Browser Extension - Popup Script

const statusDot = document.getElementById('statusDot');
const searchInput = document.getElementById('searchInput');
const contentDiv = document.getElementById('content');

// ─── Initialize ───────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  checkStatus();
  loadEntries();
  
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

// ─── Check Connection Status ──────────────────────────────

async function checkStatus() {
  try {
    const status = await chrome.runtime.sendMessage({ action: 'getStatus' });
    if (status && status.locked) {
      statusDot.className = 'status locked';
      statusDot.title = 'Vault is locked';
      showLockedState();
    } else {
      statusDot.className = 'status connected';
      statusDot.title = 'Connected';
    }
  } catch (e) {
    statusDot.className = 'status disconnected';
    statusDot.title = 'Disconnected - Open EasyPass desktop app';
  }
}

// ─── Load Entries ─────────────────────────────────────────

async function loadEntries() {
  try {
    const entries = await chrome.runtime.sendMessage({ action: 'getAllCredentials' });
    renderEntries(entries);
  } catch (e) {
    contentDiv.innerHTML = `
      <div class="empty-state">
        <div class="icon">⚠️</div>
        <div>Cannot connect to EasyPass</div>
        <div style="margin-top: 8px; font-size: 12px;">${e.message}</div>
      </div>
    `;
  }
}

// ─── Search Entries ───────────────────────────────────────

async function searchEntries(query) {
  try {
    const entries = await chrome.runtime.sendMessage({ 
      action: 'searchCredentials', 
      query 
    });
    renderEntries(entries);
  } catch (e) {
    contentDiv.innerHTML = '<div class="empty-state"><div>Search failed</div></div>';
  }
}

// ─── Render Entry List ────────────────────────────────────

function renderEntries(entries) {
  if (!entries || entries.length === 0) {
    contentDiv.innerHTML = `
      <div class="empty-state">
        <div class="icon">📭</div>
        <div>No passwords found</div>
        <div style="margin-top: 8px; font-size: 12px;">Add passwords in the EasyPass desktop app</div>
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
    const credentials = await chrome.runtime.sendMessage({
      action: 'getCredentials',
      url: tab.url
    });
    
    // Find the matching entry
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
    console.error('Failed to fill credentials:', e);
  }
}

// ─── Show Locked State ────────────────────────────────────

function showLockedState() {
  contentDiv.innerHTML = `
    <div style="padding: 32px 16px; text-align: center;">
      <div style="font-size: 48px; margin-bottom: 12px;">🔒</div>
      <div style="font-weight: 600; margin-bottom: 8px;">Vault is Locked</div>
      <div style="font-size: 12px; color: #6c7086; margin-bottom: 16px;">
        Unlock EasyPass desktop app to access passwords
      </div>
      <input type="password" id="masterPassword" 
             placeholder="Master Password" 
             style="width: 100%; padding: 8px 12px; border: 1px solid #313244; 
                    border-radius: 8px; background: #313244; color: #cdd6f4; 
                    font-size: 14px; outline: none; margin-bottom: 8px;" />
      <button id="btnUnlock" class="btn btn-primary" style="width: 100%;">
        Unlock
      </button>
    </div>
  `;
  
  document.getElementById('btnUnlock').addEventListener('click', async () => {
    const password = document.getElementById('masterPassword').value;
    try {
      await chrome.runtime.sendMessage({ action: 'unlock', password });
      window.close();
    } catch (e) {
      alert('Failed to unlock: ' + e.message);
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
  alert('Please open the EasyPass desktop application.');
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