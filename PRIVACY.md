# EasyPass Privacy Policy · 隐私政策

Applies to the **EasyPass browser extension** (Chrome / Edge) and, where noted, the
**EasyPass desktop app** it talks to.
适用于 **EasyPass 浏览器扩展**（Chrome / Edge），部分条款同时说明它所连接的 **EasyPass 桌面端**。

> Last updated: see the commit history of this file. · 最近一次修订见本文件的提交历史。

---

## English

### 1. Summary

EasyPass is a **local-first** password manager. The extension has no server, no account,
no analytics and no telemetry. Your passwords never leave your own computer.

### 2. What the extension accesses, and why

| What | When | Where it goes |
| --- | --- | --- |
| The URL of the page you are on | When you click the in-field EasyPass icon to fill a login | Sent to the **EasyPass app on the same computer** over Chrome's native messaging channel, so it can find entries matching that site |
| Login form fields on a page | It looks for username/password fields so it can offer the fill icon; values are written only when **you** click fill | Stays in the page; never transmitted |
| Your vault entries | When you open the popup (list, search, generator, health report) | Read from the local EasyPass app; rendered in the popup only |
| The clipboard | Only when you press copy, or right after a fill you triggered | Your system clipboard |

The extension itself **stores nothing** — it does not request the `storage` permission.
Any session state lives in the EasyPass desktop app and is discarded when it locks.

### 3. What we never do

- We do **not** transmit your data anywhere off your device. There is no EasyPass server,
  no cloud sync, no crash reporting, no analytics, no advertising, no third-party SDK.
- We do **not** sell or share your data with anyone.
- We do **not** execute remote code, and we do not load scripts from the network.
- We do **not** read page content beyond the form fields needed to fill a login, and we do
  not log or persist plaintext passwords, TOTP secrets or private keys.

### 4. Permissions

- `nativeMessaging` — talk to the EasyPass app installed on the same machine. This is the
  only channel the extension uses; it is a local pipe, not a network connection.
- `clipboardWrite` — copy a password, username or one-time code, including the automatic
  copy that follows a successful fill you triggered.
- Host access to all sites (`<all_urls>`) — login forms can be on any site, so the fill icon
  and the fill action must be available wherever you have an account. The content script
  only looks for input fields; it never sends page content anywhere.

We deliberately do **not** request `storage`, `activeTab`, `scripting`, `tabs`, history or
bookmark permissions.

### 5. Your data, retention and deletion

The extension keeps no data, so uninstalling it removes everything it had. Your vault is
stored and encrypted by the EasyPass desktop app on your machine (AES-256-CBC with a key
derived from your master password via PBKDF2; only a salted hash of the master password is
kept, in the operating system's credential store). You can delete individual entries, or
use **Settings → Danger zone → Delete All Data** in the app; uninstalling the app removes
its data directory. Backups you exported are ordinary files on your disk — delete them
yourself.

### 6. Children, changes, contact

The extension is not directed at children and collects nothing from anyone. Material
changes to this policy will be committed to this file. Questions or reports:
<https://github.com/CONFISION/EasyPass/issues>.

---

## 中文

### 1. 一句话

EasyPass 是**本地优先**的密码管理器。扩展没有服务器、没有账号、没有统计与遥测，
密码不会离开你自己的电脑。

### 2. 扩展会访问什么、为什么

| 内容 | 时机 | 去向 |
| --- | --- | --- |
| 当前页面的网址 | 你点输入框里的 EasyPass 图标要求填充时 | 通过 Chrome 原生消息通道发给**同一台电脑上的 EasyPass 应用**，用来匹配该网站的条目 |
| 页面上的登录表单字段 | 为了显示填充图标而查找用户名/密码输入框；只有**你点击填充**时才写入 | 留在页面里，不对外发送 |
| 你的保险库条目 | 你打开 popup（列表、搜索、生成器、健康报告）时 | 从本机 EasyPass 应用读取，只在 popup 中显示 |
| 剪贴板 | 仅在你点复制时，或你触发的填充成功之后 | 你的系统剪贴板 |

扩展自身**不保存任何数据** —— 它连 `storage` 权限都没有申请。
会话状态由 EasyPass 桌面端持有，锁定即丢弃。

### 3. 我们绝不做的事

- **不**把数据传到你的设备之外：没有 EasyPass 服务器、没有云同步、没有崩溃上报、
  没有统计、没有广告、没有第三方 SDK。
- **不**出售或分享你的数据。
- **不**执行远程代码，不从网络加载脚本。
- 除填充登录所需的表单字段外，**不**读取页面内容；不记录、不持久化明文密码、
  TOTP 密钥与私钥。

### 4. 权限说明

- `nativeMessaging` —— 与本机安装的 EasyPass 应用通信，这是扩展唯一的通道，
  是本机管道而不是网络连接。
- `clipboardWrite` —— 复制密码、用户名或动态验证码，也包括填充成功后你触发的自动复制。
- 全站访问权限（`<all_urls>`）—— 登录表单可能出现在任何网站，填充图标与填充动作
  需要在你有账号的地方都可用。内容脚本只查找输入框，不把页面内容发往任何地方。

我们刻意**不**申请 `storage`、`activeTab`、`scripting`、`tabs`、历史记录与书签权限。

### 5. 数据、保留与删除

扩展不保存数据，卸载即清空。保险库由 EasyPass 桌面端保存在本机并加密
（AES-256-CBC，密钥由主密码经 PBKDF2 派生；只把主密码的加盐哈希存进操作系统凭据库）。
你可以在应用里逐条删除，或用**设置 → 危险区域 → 删除所有数据**；卸载应用会删除其数据目录。
你自行导出的备份是磁盘上的普通文件，请自行删除。

### 6. 儿童、变更与联系方式

本扩展不面向儿童，也不收集任何人的数据。政策的实质性变更会提交到本文件。
问题与反馈：<https://github.com/CONFISION/EasyPass/issues>。
