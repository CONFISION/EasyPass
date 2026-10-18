# EasyPass

**English**: [README.md](README.md)

**Windows 上的本地优先密码管理器**，配套 Chrome / Edge 扩展：加密保险库就在自己的
机器上，浏览器里一键自动填充。长期目标：一个可自部署的 Bitwarden 替代品。

![release](https://img.shields.io/badge/release-3.0.0-blue)
![platform](https://img.shields.io/badge/platform-Windows-0078D6)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

## 你能得到什么

- **四种条目类型** —— 登录 / 安全笔记 / 身份信息 / SSH 密钥（含公钥指纹），每种都支持
  自定义字段（文本 / 隐藏 / 勾选）。
- **文件夹与搜索** —— 可换图标、重命名，删除文件夹**绝不会删掉里面的条目**；搜索支持
  `type:` / `folder:` / `url:` 前缀。
- **实时验证码** —— 详情页显示滚动的 6 位 TOTP 码并一键复制；种子只在本地核心进程里解密。
- **生成器与健康报告** —— 长度与字符集可调的密码生成器；报告找出弱密码、重复使用与
  需要更新的条目。
- **导入导出** —— 可还原的加密备份；支持 Bitwarden / Vaultwarden 导入（JSON + CSV）
  与 Bitwarden 兼容导出。
- **浏览器自动填充** —— Chrome / Edge（MV3）；只提供**登录**条目，且只在有可见密码框的
  页面出现。
- **桌面集成** —— 托盘；关窗**即刻锁定**并收起；两档退出（仅退界面 / 连核心一起退）；
  随系统启动；自动锁定（1 / 3 / 5 / 15 / 30 / 60 分钟）。
- **本地优先** —— 无账号、无服务器、无遥测；主密码从不保存
  （PBKDF2-HMAC-SHA256 + AES-256-CBC，见 [SECURITY.md](SECURITY.md)）。

## 架构（3.0.0）

保险库只有一个所有者：一个独立、常驻、无窗口的核心服务进程。Flutter 界面是纯客户端 ——
自己不开库、也不持密钥。

```text
浏览器扩展 ──┐
             ├──▶ easypass_core（独占 easypass.db 与会话密钥）
Flutter 界面 ┘     回环 TCP · 协议 5 · 全帧加密
```

关窗即锁；托盘提供 `Exit UI Only` 与 `Exit UI and Stop Service`；Windows 上二次启动只会把
已有窗口抬到前台。细节：[docs/technical-spec.md](docs/technical-spec.md)。

## 安装

**Windows** —— 从[发布页](https://github.com/CONFISION/EasyPass/releases)下载
`EasypassSetup.exe` 直接运行：按用户安装、免管理员、可选随系统启动。安装包**未代码签名**，
SmartScreen 可能提示未知发布者。

> **仅 Windows。** Linux 桌面适配不在本主分支上 —— 它在仓库的 `linux` 分支里。

保险库位置：`easypass.exe` 旁边（`%LOCALAPPDATA%\Programs\EasyPass\`）。

## 从源码构建

```bash
flutter build windows    # → build\windows\x64\runner\Release\easypass.exe
```

这一条命令同时产出 x86 浏览器桥与核心服务。构建前先停掉正在运行的 EasyPass：构建要替换
界面与核心正打开的文件。

## 浏览器扩展

尚未上架任何商店：打开 `chrome://extensions`（或 `edge://extensions`）→ 开发者模式 →
**加载已解压的扩展程序** → 选 [`browser_extension/`](browser_extension)。它连的是核心
服务，核心没在跑时桥会自动拉起它 —— 不需要开着界面。原生消息宿主由 Windows 安装包注册。

## 想看细节去哪

| 我想… | 看 |
| --- | --- |
| 搞清它怎么运转：运行时拓扑、构建打包、安全边界 | [docs/technical-spec.md](docs/technical-spec.md) |
| 加一个协议动作、改握手、写探针 | [docs/protocol-api.md](docs/protocol-api.md) |
| 改 schema、条目字段、导入导出格式 | [docs/data-model.md](docs/data-model.md) |
| 读威胁模型与已知限制 | [SECURITY.md](SECURITY.md) |
| 搭开发环境、跑门禁、提 PR | [CONTRIBUTING.md](CONTRIBUTING.md) |
| 查仓库约定、踩过的坑与排障方法 | [AGENTS.md](AGENTS.md) |
| 看每个版本改了什么 | [CHANGELOG.md](CHANGELOG.md) |

## 许可证

GPL-3.0 —— 见 [LICENSE](LICENSE)。隐私声明：[PRIVACY.md](PRIVACY.md)。
