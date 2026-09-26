// P3.4 · Linux 系统字体目录扫描测试。
//
// 用 [FontDiscoveryService.debugSetSystemFontDirectoriesForTesting] 把系
// 统字体目录列表替换成临时目录，**不**真读 `~/.local/share/fonts` 或
// `/usr/share/fonts`：
//   1. 临时目录里放一份最小合法 .ttf → discoverSystemFonts 找到。
//   2. 临时目录里放一份非字体文件（.bin）→ 不被发现。
//   3. 临时目录**不存在** → 不抛异常，返回空列表。
//   4. 子目录里放字体 → Linux 默认开递归，能找到；非 Linux 不递归（用
//      override 也能强制覆盖 recursive 行为）。
//   5. 多个目录扫到的字体名合并去重排序（family 名来自最小化 TTF 头）。
//   6. 临时目录存在但为空 → 返回空列表，不抛。
//   7. 目录列表包含"不存在 + 存在"混合 → 只有存在的贡献字体。
//
// 不可自动化的项：
//   - 真实 Linux 桌面上 `/usr/share/fonts` 的成百个家族名确实被列出来
//     （手测：`flutter test` 跑过一遍，断言 size > 100 即可验证）。
//   - GTK 主题颜色变更后 Flutter MaterialApp 是否立刻跟随 —— 任务书
//     §3.4 已确认由 embedder 自动处理，本仓库不需要改任何代码；详见
//     `dist/P3.3-facts.md` §3.2 证据链。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:easypass/data/services/font_discovery_service.dart';

void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('easypass_p34_');
  });

  tearDown(() async {
    FontDiscoveryService.debugResetSystemFontDirectoriesForTesting();
    if (tmpRoot.existsSync()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  /// 把 16 字节最小化 sfnt 头 + family name 表写入 [path]。
  /// 复用 `font_name_parser_test.dart:25-56` 的同款构造法。
  void writeFakeTtf(String path, String family) {
    // 把 family 编码成 UTF-16BE bytes。
    final encoded = <int>[];
    for (final cu in family.codeUnits) {
      encoded.add((cu >> 8) & 0xFF);
      encoded.add(cu & 0xFF);
    }
    final stringLen = encoded.length;

    final tableSize = 6 + 12 + stringLen;
    final bytes = Uint8List(12 + 16 + tableSize);
    final header = ByteData.sublistView(bytes, 0, 12);
    header.setUint16(4, 1, Endian.big); // one table

    // 'name' table record at offset 12.
    bytes.setAll(12, 'name'.codeUnits);
    final record = ByteData.sublistView(bytes, 12);
    record.setUint32(8, 12 + 16, Endian.big); // table offset
    record.setUint32(12, tableSize, Endian.big); // table length

    // Name table header at table offset.
    final table = ByteData.sublistView(bytes, 12 + 16);
    table.setUint16(0, 0, Endian.big); // format=0
    table.setUint16(2, 1, Endian.big); // count=1
    table.setUint16(4, 6 + 12, Endian.big); // stringOffset (header 6B + 1 record 12B)
    // Record: platformID=3, encodingID=1, languageID=0x0409, nameID=1, length, offset=0
    table.setUint16(6, 3, Endian.big);
    table.setUint16(8, 1, Endian.big);
    table.setUint16(10, 0x0409, Endian.big);
    table.setUint16(12, 1, Endian.big); // nameID = family
    table.setUint16(14, stringLen, Endian.big);
    table.setUint16(16, 0, Endian.big);
    // String bytes at offset 12 + 16 + 18.
    bytes.setAll(12 + 16 + 18, encoded);

    File(path).writeAsBytesSync(bytes);
  }

  group('P3.4 · Linux 系统字体目录扫描（注入目录列表）', () {
    test('注入空目录列表 → 返回空', () async {
      FontDiscoveryService.debugSetSystemFontDirectoriesForTesting(const []);
      final names = await FontDiscoveryService.discoverSystemFonts();
      expect(names, isEmpty);
    });

    test('目录不存在 → 不抛，返回空列表', () async {
      final missing = Directory(p.join(tmpRoot.path, 'does-not-exist'));
      FontDiscoveryService.debugSetSystemFontDirectoriesForTesting([missing]);
      final names = await FontDiscoveryService.discoverSystemFonts();
      expect(names, isEmpty);
    });

    test('目录存在但为空 → 返回空列表', () async {
      final empty = Directory(p.join(tmpRoot.path, 'empty'));
      await empty.create(recursive: true);
      FontDiscoveryService.debugSetSystemFontDirectoriesForTesting([empty]);
      final names = await FontDiscoveryService.discoverSystemFonts();
      expect(names, isEmpty);
    });

    test('目录里有合法 .ttf → discoverSystemFonts 列出该 family',
        () async {
      final fontsDir = Directory(p.join(tmpRoot.path, 'fonts1'));
      await fontsDir.create(recursive: true);
      writeFakeTtf(p.join(fontsDir.path, 'Fake.ttf'), 'Fake Family');

      FontDiscoveryService.debugSetSystemFontDirectoriesForTesting([fontsDir]);
      final names = await FontDiscoveryService.discoverSystemFonts();
      expect(names, ['Fake Family']);
    });

    test('目录里有非字体 .bin → 不被发现', () async {
      final fontsDir = Directory(p.join(tmpRoot.path, 'fonts2'));
      await fontsDir.create(recursive: true);
      File(p.join(fontsDir.path, 'random.bin'))
          .writeAsBytesSync(Uint8List.fromList(List<int>.filled(64, 0xCC)));

      FontDiscoveryService.debugSetSystemFontDirectoriesForTesting([fontsDir]);
      final names = await FontDiscoveryService.discoverSystemFonts();
      expect(names, isEmpty);
    });

    test('多个目录扫到的字体名合并去重排序', () async {
      final a = Directory(p.join(tmpRoot.path, 'a'));
      final b = Directory(p.join(tmpRoot.path, 'b'));
      await a.create(recursive: true);
      await b.create(recursive: true);
      writeFakeTtf(p.join(a.path, 'Zed.ttf'), 'Zed');
      writeFakeTtf(p.join(b.path, 'Alpha.ttf'), 'Alpha');
      // 故意再写一份同 family（在两个目录里）—— 应去重。
      writeFakeTtf(p.join(a.path, 'Alpha.ttf'), 'Alpha');

      FontDiscoveryService.debugSetSystemFontDirectoriesForTesting([a, b]);
      final names = await FontDiscoveryService.discoverSystemFonts();
      expect(names, ['Alpha', 'Zed']);
    });

    test('混合"不存在 + 存在"目录 → 只有存在的贡献字体', () async {
      final missing = Directory(p.join(tmpRoot.path, 'missing'));
      final present = Directory(p.join(tmpRoot.path, 'present'));
      await present.create(recursive: true);
      writeFakeTtf(p.join(present.path, 'Foo.ttf'), 'Foo Sans');

      FontDiscoveryService.debugSetSystemFontDirectoriesForTesting(
          [missing, present]);
      final names = await FontDiscoveryService.discoverSystemFonts();
      expect(names, ['Foo Sans']);
    });
  });

  group('P3.4 · 子目录递归（Linux 默认开）', () {
    test('注入目录列表时也走递归（Linux override 走真生产路径）',
        () async {
      if (!Platform.isLinux) return; // skip on Windows / macOS CI
      final fontsDir = Directory(p.join(tmpRoot.path, 'recursive'));
      await fontsDir.create(recursive: true);
      final sub = Directory(p.join(fontsDir.path, 'subfamily'));
      await sub.create(recursive: true);
      writeFakeTtf(p.join(sub.path, 'Nested.ttf'), 'Nested Sans');

      // override 走 _scanDirectory(recursive: true)（Linux 默认）
      FontDiscoveryService.debugSetSystemFontDirectoriesForTesting([fontsDir]);
      final names = await FontDiscoveryService.discoverSystemFonts();
      expect(names, contains('Nested Sans'));
    },
        skip: !Platform.isLinux
            ? 'Linux-only recursion test (Fontconfig default)'
            : null);
  });

  group('P3.4 · 非 Linux 分支不受影响', () {
    test('非 Linux 注入目录列表时：默认 _scanDirectory 不递归',
        () async {
      // Windows / macOS 上走非递归路径（保持 P3.4 前的语义）
      final fontsDir = Directory(p.join(tmpRoot.path, 'shallow'));
      await fontsDir.create(recursive: true);
      final sub = Directory(p.join(fontsDir.path, 'subfamily'));
      await sub.create(recursive: true);
      writeFakeTtf(p.join(sub.path, 'Nested.ttf'), 'Nested Sans');

      FontDiscoveryService.debugSetSystemFontDirectoriesForTesting([fontsDir]);
      final names = await FontDiscoveryService.discoverSystemFonts();
      expect(names.where((n) => n == 'Nested Sans'), isEmpty,
          reason: '非 Linux 上子目录字体**不**被发现（保持原 Windows 语义）');
    },
        skip: Platform.isLinux
            ? 'Non-Linux shallow-scan test (Windows / macOS)'
            : null);
  });
}

// The `path` package's `p.join` is re-exported by FontDiscoveryService's
// dart:io path usage. Re-import here for the test file.