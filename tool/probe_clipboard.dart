/// 手工探针：验证系统剪贴板写入（核心 → powershell 子进程 → 剪贴板）。
///
/// 用法：`dart run tool/probe_clipboard.dart`
/// 退出码：0 = 写入并读回一致；1 = 失败。
library;

import 'dart:io';

import 'package:easypass/core/platform/system_clipboard.dart';

Future<void> main() async {
  if (!SystemClipboard.isSupported) {
    stderr.writeln('仅支持 Windows');
    exit(2);
  }

  const text = 'easypass-clipboard-probe-测试';
  final ok = await SystemClipboard.writeText(text);
  stdout.writeln('writeText -> $ok');
  if (!ok) exit(1);

  final result = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    'Get-Clipboard -Raw',
  ]);
  final readBack = (result.stdout as String).trim();
  stdout.writeln('read back  -> "$readBack"');
  stdout.writeln('match      -> ${readBack == text}');
  exit(readBack == text ? 0 : 1);
}
