import 'dart:io';

import 'package:easypass/core/platform/system_clipboard.dart';
import 'package:flutter_test/flutter_test.dart';

/// 系统剪贴板写入（`copy_to_clipboard` 的底层）。
///
/// 这条路径是"密码不进模型上下文"的关键：只有真的把值送到剪贴板，
/// 智能体才能靠"粘贴"完成填写而不必看见明文。所以**必须真的读回来验证**，
/// 不能只断言 `writeText` 返回 true。
///
/// 另外钉住两条硬化要求：
/// - PowerShell 必须按 `%SystemRoot%\System32\...` 绝对路径启动（不走 PATH），
///   取不到/不存在就 fail closed；
/// - 脚本内回读校验（写后 `Get-Clipboard -Raw` 比对）失败时 `writeText` 返回 false。
///
/// 真机踩过的问题：走子进程 stdin 时若按系统代码页解释，中文会变成乱码
/// （本机 936）——这里用中文文本做回归。
void main() {
  final onWindows = Platform.isWindows;
  final skipReason = onWindows ? null : '剪贴板实现仅 Windows';

  /// 真实系统剪贴板用例依赖交互桌面会话；CI（windows-latest）没有可靠的
  /// 剪贴板窗口站，跑这些用例只会得到环境性假失败。CI 上跳过；本地（以及
  /// 真机验收工具 tool/ui_probe）仍会真实覆盖写→读回。
  final realClipboardSkip =
      skipReason ?? (Platform.environment['CI'] == 'true' ? 'CI 无交互剪贴板' : null);

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

  group('PowerShell 绝对路径解析', () {
    test('SystemRoot 缺失/为空 ⇒ null（绝不退回 PATH 查找）', () {
      expect(SystemClipboard.powershellPathFor(null), isNull);
      expect(SystemClipboard.powershellPathFor(''), isNull);
      expect(SystemClipboard.powershellPathFor('   '), isNull);
    });

    test('SystemRoot 指向不存在的目录 ⇒ null', () {
      expect(
        SystemClipboard.powershellPathFor(r'C:\easypass-no-such-system-root'),
        isNull,
      );
    });

    test('真实 SystemRoot ⇒ System32 下的 powershell.exe 绝对路径', () {
      final path = SystemClipboard.powershellPathFor(
        Platform.environment['SystemRoot'],
      );
      expect(path, isNotNull);
      expect(path, contains('System32'));
      expect(path!.toLowerCase(), endsWith('powershell.exe'));
      expect(File(path).existsSync(), isTrue);
    }, skip: skipReason);
  });

  group('失败即关（返回 false）', () {
    test('可执行文件路径为 null ⇒ false', () async {
      expect(
        await SystemClipboard.debugWriteTextWithExecutable('x', null),
        isFalse,
      );
    });

    test('可执行文件不存在 ⇒ false', () async {
      expect(
        await SystemClipboard.debugWriteTextWithExecutable(
          'x',
          r'C:\easypass-no-such-system-root\powershell.exe',
        ),
        isFalse,
      );
    });
  });

  test('写入后能从系统剪贴板读回同样的文本（含中文）', () async {
    const text = 'easypass-clipboard-测试-42';
    expect(await SystemClipboard.writeText(text), isTrue);
    expect(await readClipboard(), text);
  }, skip: realClipboardSkip);

  test('第二次写入会覆盖第一次', () async {
    expect(await SystemClipboard.writeText('first'), isTrue);
    expect(await SystemClipboard.writeText('second'), isTrue);
    expect(await readClipboard(), 'second');
  }, skip: realClipboardSkip);

  test('包含引号与换行的文本也能原样写入', () async {
    const text = 'line1\nline2 "quoted" \\backslash';
    expect(await SystemClipboard.writeText(text), isTrue);
    // Get-Clipboard -Raw 会保留内部换行；末端换行由 PowerShell 追加，忽略。
    expect((await readClipboard()).replaceAll(RegExp(r'\r?\n$'), ''),
        text.replaceAll('\r\n', '\n'));
  }, skip: realClipboardSkip);

  test('isSupported 在 Windows 上为 true', () {
    expect(SystemClipboard.isSupported, isTrue);
  }, skip: skipReason);
}
