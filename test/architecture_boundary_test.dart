import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 架构边界守卫。
///
/// 3.0.0 起 **UI 只是核心服务的客户端**：`lib/features/**` 不得再直接触碰
/// 数据库 / 仓储 / 会话密钥 —— 那正是"双核心、双 SQLite 句柄"的来源。
/// 这条不是靠人记着，而是靠这个测试。
///
/// 允许的例外（都有明确理由）：
/// - `protocol/`（线格式、动作名）与 `data/models/**`（纯数据模型）：UI 需要它们；
/// - **UI 偏好**（主题 / 字体 / 首次提示标志）仍然存在系统钥匙串里：
///   它们不是保险库密钥材料，存哪都不影响"密钥只在核心"这条不变量。
///   因此 `flutter_secure_storage` 只在**保险库相关目录**里被禁。
void main() {
  /// 无论在哪都禁止的 import 片段（数据库与仓储）。
  const forbiddenEverywhere = <String, String>{
    'package:drift/': '数据库访问必须留在核心里',
    'package:sqlite3': '数据库访问必须留在核心里',
    'data/database/': 'UI 不得直接打开 AppDatabase',
    'data/repositories/': 'UI 必须经 VaultApi，不得直接用 VaultRepository',
    'data/state/session_key.dart': 'UI 不再持有会话密钥（密钥只在核心）',
  };

  /// 只在保险库相关目录里禁止：这些代码一旦伸手要钥匙串，就是绕过了核心。
  const forbiddenInVaultCode = <String, String>{
    'package:flutter_secure_storage': '保险库密钥材料归核心；UI 只在迁移期经 SecretStore 读旧值',
  };

  /// 保险库相关目录（相对 `lib/features/`）。
  const vaultCodeDirs = ['vault', 'auth', 'health', 'generator'];

  List<File> dartFilesIn(Directory dir) => [
        for (final entity in dir.listSync(recursive: true))
          if (entity is File && entity.path.endsWith('.dart')) entity,
      ];

  test('lib/features/** 不得直接访问数据库 / 仓储 / 会话密钥', () {
    final featuresDir = Directory('lib/features');
    expect(featuresDir.existsSync(), isTrue,
        reason: '工作目录应是仓库根（flutter test 从根运行）');

    final violations = <String>[];
    for (final file in dartFilesIn(featuresDir)) {
      final normalized = file.path.replaceAll('\\', '/');
      final isVaultCode =
          vaultCodeDirs.any((dir) => normalized.startsWith('lib/features/$dir/'));

      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (!line.startsWith('import ') && !line.startsWith('export ')) continue;

        final rules = {
          ...forbiddenEverywhere,
          if (isVaultCode) ...forbiddenInVaultCode,
        };
        for (final entry in rules.entries) {
          if (line.contains(entry.key)) {
            violations.add('${file.path}:${i + 1}  ${entry.value}\n    $line');
          }
        }
      }
    }

    expect(violations, isEmpty,
        reason: 'UI 层的越界 import：\n${violations.join('\n')}');
  });

  test('lib/client/** 只能经协议说话，不得碰数据库或仓储', () {
    final clientDir = Directory('lib/client');
    final violations = <String>[];
    for (final file in dartFilesIn(clientDir)) {
      for (final line in file.readAsLinesSync()) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('import ')) continue;
        if (trimmed.contains('data/database/') ||
            trimmed.contains('data/repositories/')) {
          violations.add('${file.path}: $trimmed');
        }
      }
    }
    expect(violations, isEmpty, reason: 'lib/client 越界：\n${violations.join('\n')}');
  });

  test('lib/core_service/** 不得 import Flutter：核心是无 Flutter 的 AOT 程序', () {
    // 这条守住"核心服务能脱离 Flutter 编译"这个前提：一旦有人图省事引入
    // flutter/foundation，`dart build cli` 会立刻失败（dart:ui 不存在）。
    final coreDir = Directory('lib/core_service');
    final violations = <String>[];
    for (final file in dartFilesIn(coreDir)) {
      for (final line in file.readAsLinesSync()) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('import ')) continue;
        if (trimmed.contains('package:flutter/') ||
            trimmed.contains('package:flutter_riverpod/') ||
            trimmed.contains('package:flutter_secure_storage/')) {
          violations.add('${file.path}: $trimmed');
        }
      }
    }
    expect(violations, isEmpty,
        reason: '核心不得依赖 Flutter：\n${violations.join('\n')}');
  });
}
