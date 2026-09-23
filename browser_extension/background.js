// EasyPass Browser Extension - Background Service Worker

// Store the port connection to the native host
let nativePort = null;
let pendingRequests = new Map();

// ─── Daemon error grading ─────────────────────────────────
//
// 扩展比桌面端新时（刚升级、旧的 daemon 进程还在跑），旧 daemon 对本构建新增
// 的动作只会回 `Unknown action: xxx`。原样抛给 popup，用户看到的是"未知操作：
// getHealthReport"这类无从下手的字眼，会被误读成"扩展坏了"。这里按类型分级：
// 这类错误翻译成"后台服务版本过旧 + 请重启应用"；连接类错误（未连接/断开/超时）
// 保持原样，它们已经由扩展自己本地化，原因也不该被吞掉。
//
// EXPECTED_PROTOCOL_VERSION 必须与桌面端
// lib/core/constants/app_constants.dart 的 bridgeProtocolVersion 一致。
// 3 = 2.3.0：条目 JSON 增加 type / identity / sshKey / customFields，
// getCredentials 只返回登录条目（安全笔记 / 身份 / SSH 不参与自动填充）。
const EXPECTED_PROTOCOL_VERSION = 3;

function gradeDaemonError(text) {
  const message = String(text === undefined || text === null ? '' : text);
  if (/unknown action/i.test(message)) {
    return chrome.i18n.getMessage('staleDaemon') + ' — ' +
      chrome.i18n.getMessage('restartApp');
  }
  return message;
}

/** 成功响应里也能看出后台服务是不是旧版本：旧 daemon 不回报 protocolVersion。
 *  这里只记一条控制台警告 —— 不改消息契约，也不把"可用"变成"错误"
 *  （解锁/列表仍可用，只有新动作会走上面的 unknown-action 分级）。 */
function warnIfStaleDaemon(status) {
  if (!status || typeof status !== 'object') return;
  if (status.protocolVersion === EXPECTED_PROTOCOL_VERSION) return;
  console.warn('EasyPass: ' + chrome.i18n.getMessage('staleDaemon') + ' — ' +
    chrome.i18n.getMessage('restartApp'));
}

// ─── Native Messaging Connection ──────────────────────────

function connectToNativeHost() {
  try {
    const hostName = 'com.easypass.app';
    nativePort = chrome.runtime.connectNative(hostName);
    
    nativePort.onMessage.addListener((message) => {
      handleNativeMessage(message);
    });
    
    nativePort.onDisconnect.addListener(() => {
      // Consume chrome.runtime.lastError synchronously inside the handler;
      // otherwise Chrome logs "Unchecked runtime.lastError" and the real
      // cause (e.g. "Specified native messaging host not found") is hidden.
      const lastError = chrome.runtime.lastError;
      if (lastError) {
        console.error(chrome.i18n.getMessage('logNativeHostError', [lastError.message]));
      } else {
        console.log(chrome.i18n.getMessage('logNativeHostDisconnected'));
      }
      nativePort = null;
      // Reject all pending requests
      for (const [id, reject] of pendingRequests) {
        reject(new Error(chrome.i18n.getMessage('nativeHostDisconnected')));
      }
      pendingRequests.clear();
      
      // Retry connection after 5 seconds
      setTimeout(connectToNativeHost, 5000);
    });
    
    console.log(chrome.i18n.getMessage('logConnectedToNativeHost'));
  } catch (e) {
    const lastError = chrome.runtime.lastError;
    console.error(chrome.i18n.getMessage('logFailedToConnect'), lastError ? lastError.message : e);
    setTimeout(connectToNativeHost, 5000);
  }
}

// ─── Handle Messages from Native Host ─────────────────────

function handleNativeMessage(message) {
  if (message.requestId && pendingRequests.has(message.requestId)) {
    const { resolve, reject } = pendingRequests.get(message.requestId);
    pendingRequests.delete(message.requestId);
    
    if (message.error) {
      reject(new Error(gradeDaemonError(message.error)));
    } else {
      resolve(message.data);
    }
  }
}

// ─── Send Message to Native Host ──────────────────────────

function sendToNativeHost(action, data = {}) {
  return new Promise((resolve, reject) => {
    const requestId = generateRequestId();
    pendingRequests.set(requestId, { resolve, reject });
    
    let tries = 0;
    const attempt = () => {
      if (nativePort) {
        nativePort.postMessage({
          requestId,
          action,
          ...data
        });
        // Timeout after 30 seconds
        setTimeout(() => {
          if (pendingRequests.has(requestId)) {
            pendingRequests.delete(requestId);
            reject(new Error(chrome.i18n.getMessage('requestTimedOut')));
          }
        }, 30000);
        return;
      }
      // The service worker may have just been woken up by this very message
      // while connectToNativeHost() is still establishing the port. Retry
      // briefly instead of failing immediately.
      if (tries++ < 8) {
        setTimeout(attempt, 250);
      } else {
        pendingRequests.delete(requestId);
        reject(new Error(chrome.i18n.getMessage('nativeHostNotConnected')));
      }
    };
    
    attempt();
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
    
    case 'getStatus': {
      const status = await sendToNativeHost('getStatus');
      warnIfStaleDaemon(status);
      return status;
    }
    
    case 'unlock':
      return await sendToNativeHost('unlock', { password: request.password });
    
    case 'lock':
      return await sendToNativeHost('lock');
    
    case 'generatePassword':
      return await sendToNativeHost('generatePassword', request.options || {});
    
    case 'getTotp':
      return await sendToNativeHost('getTotp', { entryId: request.entryId });
    
    case 'getHealthReport':
      return await sendToNativeHost('getHealthReport');
    
    default:
      throw new Error(chrome.i18n.getMessage('unknownAction', [request.action]));
  }
}

// ─── Initialize ───────────────────────────────────────────

// Connect to native host on startup
connectToNativeHost();

console.log(chrome.i18n.getMessage('logBackgroundInitialized'));