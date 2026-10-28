import 'dart:io';

import 'package:easypass/core_service/core_client.dart';
import 'package:easypass/core_service/core_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// `daemon.json` 读失败时的 **fail-closed** 行为（M12）。
///
/// 修复前 `lockRunningCore` / `shutdownRunningCore` 把"发现文件读不出来"
/// 当成"没有核心在跑"→ 返回成功。托盘/CLI 于是对用户谎报"已锁定/已退出"，
/// 而核心可能还开着、库可能还解着。这里钉住两条相反语义：
/// - 文件**不存在** = 确实没有核心 ⇒ 无事可做，成功；
/// - 文件**存在但坏了** = 核心状态未知 ⇒ 失败（不得报成功）。
void main() {
  late Directory tempDir;
  late File infoFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('easypass_core_client_');
    infoFile = File(p.join(tempDir.path, 'daemon.json'));
    CoreDiscovery.debugSetInfoFileForTesting(infoFile);
  });

  tearDown(() {
    CoreDiscovery.debugSetInfoFileForTesting(null);
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // 清理尽力而为。
    }
  });

  group('lockRunningCore', () {
    test('发现文件不存在 ⇒ true（本来就没有核心，无事可做）', () async {
      expect(await lockRunningCore(), isTrue);
    });

    test('发现文件损坏 ⇒ false（不能对用户谎报"已锁定"）', () async {
      await infoFile.writeAsString('{not valid json');
      expect(await lockRunningCore(), isFalse);
    });
  });

  group('shutdownRunningCore', () {
    test('发现文件不存在 ⇒ true（本来就没有核心）', () async {
      expect(await shutdownRunningCore(), isTrue);
    });

    test('发现文件损坏 ⇒ false（不能对用户谎报"核心已退出"）', () async {
      await infoFile.writeAsString('');
      expect(await shutdownRunningCore(), isFalse);
    });
  });
}
