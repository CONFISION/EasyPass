import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

/// 系统剪贴板写入（核心是**无 Flutter** 的 AOT 控制台程序，用不了 `Clipboard.setData`）。
///
/// 为什么智能体接口需要它：密码**不该进入模型上下文**。核心把值写进剪贴板、
/// 只回一个 `ok`，智能体负责去目标窗口粘贴——明文从未进入模型的消息。
///
/// **为什么不用 `dart:ffi` 直接调 `SetClipboardData`**（我试过，且必须记下来）：
/// `OpenClipboard` / `EmptyClipboard` / `CloseClipboard` / `GlobalAlloc` 都正常，
/// 但一旦把真实的 `HGLOBAL` 交给 `SetClipboardData`，进程就以
/// `0xC0000374`（堆损坏）**直接崩掉**，最小可复现脚本也一样。
/// 崩溃点在一个**持有保险库密钥的常驻进程**里，代价是整个保险库不可用 ——
/// 换成一个短命的 `powershell` 子进程来做这件事，风险小得多。
///
/// 安全细节：
/// - PowerShell 用 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`
///   **绝对路径**启动，不走 PATH/CWD。核心与 UI 都装在用户可写目录，裸名
///   `powershell` 可能被同账户进程投放的同名程序劫持，而明文正好从 stdin 进去；
/// - 明文**只走子进程的 stdin**，绝不出现在命令行参数里（否则任何进程
///   都能从进程列表中读到密码）；
/// - 显式按 UTF-8 解码，避免系统代码页（本机 936）把中文写成乱码；
/// - 子进程内**回读校验**（`Get-Clipboard -Raw` 比对），防止 `Set-Clipboard`
///   静默失败时向调用方谎报成功；
/// - 子进程失败一律返回 false，调用方回错误，不再尝试别的路径。
class SystemClipboard {
  SystemClipboard._();

  static bool get isSupported => Platform.isWindows;

  /// 子进程超时：PowerShell 冷启动通常 200–500ms，给足余量但不无限等。
  static const Duration _timeout = Duration(seconds: 10);

  /// 从 stdin 按 UTF-8 读入、写入剪贴板、再**读回比对**的 PowerShell 脚本。
  ///
  /// 为什么要在脚本里回读：`Set-Clipboard` 不报错不等于内容真的进了剪贴板
  /// （剪贴板被别的进程占着、RDP/会话切换都可能静默失败），而 Dart 侧只看得到
  /// 退出码。用 `Get-Clipboard -Raw` 读回；不一致退 3，调用方拿到 false。
  /// 行尾做 CRLF→LF 归一化并对末尾换行宽容：Windows 剪贴板按 CRLF 存文本，
  /// `Set-Clipboard`/`Get-Clipboard` 往返会改写行尾，不能按字节比较。
  ///
  /// **读回最多重试 5 次（每次 60ms）**：剪贴板是系统级共享资源，写入与立即读回
  /// 之间可能被其他进程的复制/剪贴板历史服务打断，一次不一致不代表写入失败；
  /// 全量测试并发时曾实测到这种假失败。重试仍不一致才判失败。
  static const String _script = r'''
$ErrorActionPreference = 'Stop'
$reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
$text = $reader.ReadToEnd()
Set-Clipboard -Value $text
$expected = $text.Replace("`r`n", "`n").TrimEnd([char[]]"`r`n")
$ok = $false
for ($i = 0; $i -lt 5; $i++) {
  $back = Get-Clipboard -Raw
  if ($null -eq $back) { $back = '' }
  $actual = $back.Replace("`r`n", "`n").TrimEnd([char[]]"`r`n")
  if ($actual -eq $expected) { $ok = $true; break }
  Start-Sleep -Milliseconds 60
}
if (-not $ok) { exit 3 }
''';

  /// 由 `%SystemRoot%` 构造 PowerShell 的绝对路径；不可用时返回 null。
  ///
  /// 取不到 `SystemRoot` 或文件不存在 ⇒ null，调用方必须**直接失败**，
  /// 绝不退回 PATH 查找（那正是要避免的劫持面）。
  @visibleForTesting
  static String? powershellPathFor(String? systemRoot) {
    if (systemRoot == null || systemRoot.trim().isEmpty) return null;
    final path = p.join(
      systemRoot,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    return File(path).existsSync() ? path : null;
  }

  /// 把 [text] 写进剪贴板。返回 false 表示失败（或平台不支持）。
  static Future<bool> writeText(String text) {
    if (!isSupported) return Future.value(false);
    final executable = powershellPathFor(Platform.environment['SystemRoot']);
    if (executable == null) return Future.value(false);
    return _writeTextWithRetry(executable, text);
  }

  /// 测试入口：给定可执行文件路径直接走写入流程。
  ///
  /// 抽出来是为了单测"绝对路径解析失败 ⇒ fail closed"，不必在测试里 mock
  /// `Process.start`。生产代码只用 [writeText]。
  @visibleForTesting
  static Future<bool> debugWriteTextWithExecutable(
    String text,
    String? executable,
  ) {
    if (!isSupported || executable == null || !File(executable).existsSync()) {
      return Future.value(false);
    }
    return _writeTextWithRetry(executable, text);
  }

  /// 整次写入最多重试 3 次：系统负载高时 PowerShell 冷启动/剪贴板服务可能
  /// 短暂不可用，失败一次不代表这次复制真的坏了（调用方是智能体，重试一次
  /// 比让它把"复制失败"转述给用户更划算）。只有连续失败才返回 false。
  static Future<bool> _writeTextWithRetry(String executable, String text) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await _writeText(executable, text)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return false;
  }

  static Future<bool> _writeText(String executable, String text) async {
    Process? process;
    try {
      process = await Process.start(
        executable,
        [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-Command',
          _script,
        ],
        runInShell: false,
      );

      // 先把 stdout/stderr 排空：不消费的话管道填满会让子进程挂住。
      final outFuture = process.stdout.drain<void>();
      final errFuture = process.stderr.drain<void>();

      process.stdin.add(utf8.encode(text));
      await process.stdin.flush();
      await process.stdin.close();

      final exitCode = await process.exitCode.timeout(_timeout);
      await outFuture;
      await errFuture;
      return exitCode == 0;
    } catch (_) {
      try {
        process?.kill();
      } catch (_) {
        // 已经退出。
      }
      return false;
    }
  }
}
