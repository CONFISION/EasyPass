import 'dart:io';

import 'package:easypass/core/platform/system_clipboard.dart';
import 'package:flutter_test/flutter_test.dart';

/// 系统剪贴板写入（`copy_to_clipboard` 的底层）。
///
/// 这条路径是"密码不进模型上下文"的关键：只有真的把值送到剪贴板，
/// 智能体才能靠"粘贴"完成填写而不必看见明文。所以**必须真的读回来验证**，
/// 不能只断言 `writeText` 返回 true。
///
/// 另外钉住一条真机踩过的问题：走子进程 stdin 时若按系统代码页解释，
/// 中文会变成乱码（本机 936）——这里用中文文本做回归。
void main() {
  final onWindows = Platform.isWindows;
  final skipReason = onWindows ? null : '剪贴板实现仅 Windows';

  Future<String> readClipboard() async {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Get-Clipboard -Raw',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (result.stdout as String).trim();
  }

  test('写入后能从系统剪贴板读回同样的文本（含中文）', () async {
    const text = 'easypass-clipboard-测试-42';
    expect(await SystemClipboard.writeText(text), isTrue);
    expect(await readClipboard(), text);
  }, skip: skipReason);

  test('第二次写入会覆盖第一次', () async {
    expect(await SystemClipboard.writeText('first'), isTrue);
    expect(await SystemClipboard.writeText('second'), isTrue);
    expect(await readClipboard(), 'second');
  }, skip: skipReason);

  test('包含引号与换行的文本也能原样写入', () async {
    const text = 'line1\nline2 "quoted" \\backslash';
    expect(await SystemClipboard.writeText(text), isTrue);
    // Get-Clipboard -Raw 会保留内部换行；末端换行由 PowerShell 追加，忽略。
    expect((await readClipboard()).replaceAll(RegExp(r'\r?\n$'), ''),
        text.replaceAll('\r\n', '\n'));
  }, skip: skipReason);

  test('isSupported 在 Windows 上为 true', () {
    expect(SystemClipboard.isSupported, isTrue);
  }, skip: skipReason);
}
