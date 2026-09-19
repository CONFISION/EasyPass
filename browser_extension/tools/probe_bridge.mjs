#!/usr/bin/env node
// EasyPass 端到端链路探针 —— 像浏览器那样启动 native messaging 桥接进程并对话。
//
// 覆盖的真实链路（与 Chrome/Edge 完全一致）：
//   本脚本 →(stdio, 4 字节小端长度 + JSON)→ easypass_native_host.exe
//          →(loopback TCP + token)→ easypass.exe --service（daemon）→ SQLite
//
// 它能一次性回答"到底是哪一层坏了"：
//   - 桥接进程起不来 / 找不到            → 安装或路径问题
//   - 桥接拉不起 daemon（超时）           → daemon.exe 缺失或启动失败
//   - 响应里是 "Unknown action: xxx"      → **连到的是旧版本 daemon**（升级后没重启）
//   - 响应里是 "Vault is locked"          → 链路正常，只是保险库锁着（去扩展解锁）
//   - 正常 data                            → 全链路通
//
// 用法：
//   node browser_extension/tools/probe_bridge.mjs                    # 默认 getStatus + getHealthReport
//   node browser_extension/tools/probe_bridge.mjs getStatus
//   EASYPASS_BRIDGE=<path> 覆盖桥接 exe 路径（默认用安装目录里的）
//
// 只读：不会发送 unlock/lock，不打印任何凭据。

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const DEFAULT_ACTIONS = ['getStatus', 'getHealthReport'];
const actions = process.argv.slice(2).filter((a) => !a.startsWith('--'));

const candidates = [
  process.env.EASYPASS_BRIDGE,
  join(process.env.LOCALAPPDATA || '', 'Programs', 'EasyPass', 'easypass_native_host.exe'),
  join(process.cwd(), 'build', 'windows', 'x64', 'runner', 'Release', 'easypass_native_host.exe'),
].filter(Boolean);
const bridge = candidates.find((p) => existsSync(p));

console.log('EasyPass 端到端链路探针（stdio → 桥接 → daemon）');
if (!bridge) {
  console.log('  ❌ 找不到 easypass_native_host.exe，试过：');
  for (const c of candidates) console.log(`     ${c}`);
  process.exit(1);
}
console.log(`  桥接：${bridge}`);

function frame(message) {
  const json = Buffer.from(JSON.stringify(message), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32LE(json.length, 0);
  return Buffer.concat([header, json]);
}

const child = spawn(bridge, [], { stdio: ['pipe', 'pipe', 'inherit'] });

let pending = Buffer.alloc(0);
const queue = [];
child.stdout.on('data', (chunk) => {
  pending = Buffer.concat([pending, chunk]);
  while (queue.length) {
    if (pending.length < 4) return;
    const length = pending.readUInt32LE(0);
    if (pending.length < 4 + length) return;
    const body = pending.subarray(4, 4 + length).toString('utf8');
    pending = pending.subarray(4 + length);
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch (e) {
      parsed = { error: `无法解析响应帧：${e.message}` };
    }
    queue.shift()(parsed);
  }
});

function readFrame(timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`等待响应超时（${timeoutMs}ms）`)), timeoutMs);
    queue.push((message) => {
      clearTimeout(timer);
      resolve(message);
    });
  });
}

let failures = 0;
child.on('error', (err) => {
  console.log(`  ❌ 无法启动桥接：${err.message}`);
  process.exit(1);
});
child.on('exit', (code) => {
  if (queue.length) {
    console.log(`  ❌ 桥接在响应前退出（exit=${code}）—— daemon 拉不起来或桥接崩溃`);
    process.exit(1);
  }
});

(async () => {
  const list = actions.length ? actions : DEFAULT_ACTIONS;
  for (const action of list) {
    const requestId = `${action}-${Date.now().toString(36)}`;
    child.stdin.write(frame({ requestId, action }));
    let response;
    try {
      // 冷启动要拉起整个 Flutter daemon 进程，第一次响应可能很慢。
      response = await readFrame(45000);
    } catch (e) {
      console.log(`  ${action} → ❌ ${e.message}（冷启动失败：daemon 没能起来）`);
      failures++;
      continue;
    }
    if (response.requestId !== requestId) {
      console.log(`  ${action} → ⚠️  requestId 不匹配（期望 ${requestId}，收到 ${response.requestId}）`);
      failures++;
    }
    if (response.error) {
      const unknown = /unknown action/i.test(String(response.error));
      console.log(`  ${action} → error: ${response.error}`);
      if (unknown) {
        console.log('     ⚠️  连到的是**旧版本 daemon**：请退出 EasyPass（托盘 → Exit）后重试');
        failures++;
      } else if (/locked/i.test(String(response.error))) {
        console.log('     ℹ️  链路正常，保险库处于锁定态（在扩展里解锁即可）');
      }
    } else {
      console.log(`  ${action} → ${JSON.stringify(response.data)}`);
    }
  }
  child.stdin.end();
  setTimeout(() => {
    child.kill();
    console.log(failures ? `❌ ${failures} 项异常` : '✅ 链路正常');
    process.exit(failures ? 1 : 0);
  }, 300);
})();
