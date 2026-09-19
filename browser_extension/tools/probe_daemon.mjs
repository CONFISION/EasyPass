#!/usr/bin/env node
// EasyPass 守护进程协议探针 —— 直接通过 TCP 跟正在运行的 daemon 对话。
//
// 用途：扩展报错（"无法连接"/"未知操作：xxx"）时，用它区分三种情况：
//   1. daemon 没在跑            → 连接失败 / daemon.json 指向的端口无人应答
//   2. 跑的是旧版本 daemon      → getHealthReport 回 "Unknown action: getHealthReport"
//   3. 跑的是新版本、处于锁定态 → getHealthReport 回 "Vault is locked"
// 这样不必依赖浏览器就能判断"扩展连的到底是哪个 build"。
//
// 用法：
//   node browser_extension/tools/probe_daemon.mjs                      # 只读探针
//   node browser_extension/tools/probe_daemon.mjs getStatus lock       # 显式追加动作
//   node browser_extension/tools/probe_daemon.mjs --info               # 只打印 daemon.json
//   EASYPASS_DAEMON_JSON=<path> node ... （默认 %LOCALAPPDATA%\EasyPass\daemon.json）
//
// 注意：默认动作**只读**。`lock` 会真的把当前会话锁掉（需要重新解锁），
// 必须显式传入才执行。
//
// 不会打印任何凭据；unlock 需要主密码，本工具**不**接受密码参数（请用扩展解锁）。

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { createConnection } from 'node:net';

const DEFAULT_ACTIONS = ['getStatus', 'getHealthReport'];

const infoPath =
  process.env.EASYPASS_DAEMON_JSON ||
  join(process.env.LOCALAPPDATA || '', 'EasyPass', 'daemon.json');

const args = process.argv.slice(2);
const infoOnly = args.includes('--info');
const actions = args.filter((a) => !a.startsWith('--'));

function encode(message) {
  const json = Buffer.from(JSON.stringify(message), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32LE(json.length, 0);
  return Buffer.concat([header, json]);
}

function makeReader(socket) {
  let pending = Buffer.alloc(0);
  const waiters = [];
  socket.on('data', (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    drain();
  });
  function drain() {
    while (waiters.length) {
      if (pending.length < 4) return;
      const length = pending.readUInt32LE(0);
      if (pending.length < 4 + length) return;
      const body = pending.subarray(4, 4 + length).toString('utf8');
      pending = pending.subarray(4 + length);
      waiters.shift()(JSON.parse(body));
    }
  }
  return () =>
    new Promise((resolve) => {
      waiters.push(resolve);
      drain();
    });
}

console.log(`daemon.json: ${infoPath}`);
if (!existsSync(infoPath)) {
  console.log('  ❌ 文件不存在 —— daemon 从未启动，或已被清理');
  process.exit(1);
}
let info;
try {
  info = JSON.parse(readFileSync(infoPath, 'utf8'));
} catch (e) {
  console.log(`  ❌ 无法解析：${e.message}`);
  process.exit(1);
}
console.log(`  port=${info.port} token=${info.token ? info.token.slice(0, 8) + '…' : '(缺失)'}` +
  ` protocolVersion=${info.protocolVersion ?? '(旧版无此字段)'} pid=${info.pid ?? '(旧版无此字段)'}`);
if (infoOnly) process.exit(0);

if (!info.port || !info.token) {
  console.log('  ❌ daemon.json 缺少 port/token');
  process.exit(1);
}

const socket = createConnection({ host: '127.0.0.1', port: info.port });
const read = makeReader(socket);
const timeout = setTimeout(() => {
  console.log('  ❌ 连接超时（端口无人应答 = 残留的 daemon.json 指向已退出的进程）');
  socket.destroy();
  process.exit(2);
}, 5000);

socket.on('error', (err) => {
  clearTimeout(timeout);
  console.log(`  ❌ 连接失败：${err.code || err.message}`);
  console.log('     → daemon 没在运行（应由桥接按需拉起，或手动启动 easypass.exe --service）');
  process.exit(2);
});

socket.on('connect', async () => {
  clearTimeout(timeout);
  socket.write(encode({ token: info.token }));
  for (const action of actions.length ? actions : DEFAULT_ACTIONS) {
    const requestId = `${action}-${Date.now().toString(36)}`;
    socket.write(encode({ requestId, action }));
    const response = await Promise.race([
      read(),
      new Promise((r) => setTimeout(() => r({ error: '（25s 无响应）' }), 25000)),
    ]);
    const payload = response.error
      ? `error: ${response.error}`
      : JSON.stringify(response.data);
    console.log(`  ${action} → ${payload}`);
    if (/unknown action/i.test(String(response.error || ''))) {
      console.log('     ⚠️  这个 daemon **不认识该动作** = 正在运行的是旧版本构建');
    }
  }
  socket.end();
  process.exit(0);
});
