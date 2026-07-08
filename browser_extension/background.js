// EasyPass Browser Extension - Background Service Worker

// Store the port connection to the native host
let nativePort = null;
let pendingRequests = new Map();

// ─── Native Messaging Connection ──────────────────────────

function connectToNativeHost() {
  try {
    const hostName = 'com.easypass.app';
    nativePort = chrome.runtime.connectNative(hostName);
    
    nativePort.onMessage.addListener((message) => {
      handleNativeMessage(message);
    });
    
    nativePort.onDisconnect.addListener(() => {
      console.log('EasyPass: Native host disconnected');
      nativePort = null;
      // Reject all pending requests
      for (const [id, reject] of pendingRequests) {
        reject(new Error('Native host disconnected'));
      }
      pendingRequests.clear();
      
      // Retry connection after 5 seconds
      setTimeout(connectToNativeHost, 5000);
    });
    
    console.log('EasyPass: Connected to native host');
  } catch (e) {
    console.error('EasyPass: Failed to connect to native host:', e);
    setTimeout(connectToNativeHost, 5000);
  }
}

// ─── Handle Messages from Native Host ─────────────────────

function handleNativeMessage(message) {
  if (message.requestId && pendingRequests.has(message.requestId)) {
    const { resolve, reject } = pendingRequests.get(message.requestId);
    pendingRequests.delete(message.requestId);
    
    if (message.error) {
      reject(new Error(message.error));
    } else {
      resolve(message.data);
    }
  }
}

// ─── Send Message to Native Host ──────────────────────────

function sendToNativeHost(action, data = {}) {
  return new Promise((resolve, reject) => {
    if (!nativePort) {
      reject(new Error('Not connected to EasyPass desktop app'));
      return;
    }
    
    const requestId = generateRequestId();
    pendingRequests.set(requestId, { resolve, reject });
    
    nativePort.postMessage({
      requestId,
      action,
      ...data
    });
    
    // Timeout after 30 seconds
    setTimeout(() => {
      if (pendingRequests.has(requestId)) {
        pendingRequests.delete(requestId);
        reject(new Error('Request timed out'));
      }
    }, 30000);
  });
}

function generateRequestId() {
  return Date.now().toString(36) + Math.random().toString(36).substr(2);
}

// ─── Message Handlers from Content Scripts & Popup ────────

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  handleExtensionMessage(request).then(sendResponse).catch(error => {
    sendResponse({ error: error.message });
  });
  return true; // Keep the message channel open for async response
});

async function handleExtensionMessage(request) {
  switch (request.action) {
    case 'getCredentials':
      return await sendToNativeHost('getCredentials', { url: request.url });
    
    case 'getAllCredentials':
      return await sendToNativeHost('getAllCredentials');
    
    case 'searchCredentials':
      return await sendToNativeHost('searchCredentials', { query: request.query });
    
    case 'getStatus':
      return await sendToNativeHost('getStatus');
    
    case 'unlock':
      return await sendToNativeHost('unlock', { password: request.password });
    
    case 'generatePassword':
      return await sendToNativeHost('generatePassword', request.options || {});
    
    default:
      throw new Error(`Unknown action: ${request.action}`);
  }
}

// ─── Initialize ───────────────────────────────────────────

// Connect to native host on startup
connectToNativeHost();

console.log('EasyPass background service worker initialized');