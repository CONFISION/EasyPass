// `easypass_sqlite3` 与 `sqlite3_flutter_libs_plugin` 的
// `target_compile_definitions` 在 Linux 上必须一致 —— 否则会得到两套
// SQL 函数/特性宏不同的 SQLite 二进制，"用本地独立库"和"用 plugin"
// 给用户带来的就是两份不同的 SQLite 行为。
//
// 测试策略：
//   - 读取 `linux/CMakeLists.txt` 抓 `easypass_sqlite3` 的宏集合。
//   - 跑这条扫之前我们**根本不知道**对端插件的精确路径（Dart 测试不能依赖
//     `~/.pub-cache` 的具体位置），所以同时只断言以下两点：
//     1. 我们的 `easypass_sqlite3` 必须包含 `SQLITE_HAVE_LOCALTIME_R` 与
//        `SQLITE_HAVE_LOCALTIME_S` 两者（POSIX 与 MSVC 两条都声明，让 plugin
//        调用过同样的头时不会有歧义）。
//     2. easypass_sqlite3 的宏集合必须通过文本包含 `SQLITE_OMIT_SHARED_CACHE`
//        这种**双方都有的决定性特征**，并且不应漂移到任何 plugin 已经移除的
//        关键项 —— 反向校验。如果 plugin 改了它，CI 才会跑（新插件 pull 后
//        这条对比在重新构建后由 `flutter build` 验证；此测试只锁**我们的**
//        CMake 不漂移）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('easypass_sqlite3 macros stay in sync with the plugin', () {
    test('`easypass_sqlite3` defines BOTH localtime variants (R + S)', () {
      // 事实链：sqlite3.c 里同时使用 `SQLITE_HAVE_LOCALTIME_R` 和
      // `SQLITE_HAVE_LOCALTIME_S`（后者仅在 R 未定义时才走，详见
      // sqlite3.c:25777-25781）。与插件 CMake 一致地同时声明两个，就是这次
      // 对齐的结果。
      final macros = _readEasypassSqlite3Macros();
      expect(macros, contains('SQLITE_HAVE_LOCALTIME_R'),
          reason:
              'POSIX localtime_r must be declared (glibc / Linux server path).');
      expect(macros, contains('SQLITE_HAVE_LOCALTIME_S'),
          reason:
              'MSVC localtime_s must ALSO be declared so the two SQLite '
              'binaries get identical compile-time macros. Adding only `_S` '
              'was the audit flag — the dead-code branch is harmless when '
              '`_R` is also defined.');
    });

    test('`easypass_sqlite3` keeps the canonical OMIT/ENABLE set', () {
      // 双方都需要保留的"关键项"：出现差异时本测试立即失败。
      final macros = _readEasypassSqlite3Macros();
      for (final required in const [
        'SQLITE_ENABLE_DBSTAT_VTAB',
        'SQLITE_ENABLE_FTS5',
        'SQLITE_ENABLE_RTREE',
        'SQLITE_ENABLE_MATH_FUNCTIONS',
        'SQLITE_OMIT_AUTHORIZATION',
        'SQLITE_OMIT_SHARED_CACHE',
        'SQLITE_OMIT_TCL_VARIABLE',
        'SQLITE_OMIT_TRACE',
        'SQLITE_USE_ALLOCA',
        'SQLITE_ENABLE_SESSION',
        'SQLITE_UNTESTABLE',
        'SQLITE_HAVE_ISNAN',
        'SQLITE_HAVE_MALLOC_USABLE_SIZE',
        'SQLITE_HAVE_STRCHRNUL',
      ]) {
        expect(macros, contains(required),
            reason: 'Macro `$required` must remain in the macro set.');
      }
    });

    test('`easypass_sqlite3` does NOT define platform-incompatible macros '
        'that would break on glibc/Linux', () {
      // 例如：在 Linux 工具链上定义 `SQLITE_OS_WIN_OTHER` 显然会破坏行为。
      // 本测试断言：我们 CMake 块没有意外掺入 Windows/Apple 专属宏。
      final macros = _readEasypassSqlite3Macros();
      const forbidden = [
        'SQLITE_OS_WIN',
        'SQLITE_OS_WINNT',
        'SQLITE_OS_MAC',
        'SQLITE_OS_UNIX', // SQLite 自身在 Unix 上不通过此宏分派，外部定义会干扰。
      ];
      for (final f in forbidden) {
        expect(macros, isNot(contains(f)),
            reason:
                'Linux-only build must NOT define `$f`; it would interpose '
                'with sqlite3.c\'s own detection and break behavior.');
      }
    });
  });
}

Set<String> _readEasypassSqlite3Macros() {
  // Find the `target_compile_definitions(easypass_sqlite3 PRIVATE ... )` block.
  final repoRoot = Directory.current.path;
  final cmake = File(p.join(repoRoot, 'linux', 'CMakeLists.txt'));
  expect(cmake.existsSync(), isTrue,
      reason: 'linux/CMakeLists.txt must be readable from CWD.');

  final text = cmake.readAsStringSync();
  // Match a balanced PRIVATE block. Allow nested parens; here the macro list
  // is single-line tokens so simple line-scan is enough.
  final startIdx =
      text.indexOf('target_compile_definitions(easypass_sqlite3 PRIVATE');
  expect(startIdx, isNonNegative,
      reason:
          'CMakeLists.txt must still declare '
          '`target_compile_definitions(easypass_sqlite3 PRIVATE …)`.');

  // From the start, find the matching `)`.
  final after = text.substring(startIdx);
  final endIdx = after.indexOf(')');
  expect(endIdx, isNonNegative,
      reason: '`target_compile_definitions` block must terminate with `)`.');

  final block = after.substring(0, endIdx);
  final macros = <String>{};
  for (final raw in block.split(RegExp(r'\s+'))) {
    if (raw.isEmpty) continue;
    if (raw == 'target_compile_definitions(easypass_sqlite3') continue;
    if (raw == 'PRIVATE') continue;
    if (raw.startsWith('SQLITE_')) macros.add(raw);
  }
  return macros;
}
