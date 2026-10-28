import 'dart:convert';
import 'dart:io';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/core_service/core_info.dart';
import 'package:easypass/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// `daemon.json`（发现文件）的解析与"陈旧核心"判定。
///
/// 这些断言盯着升级路径上最容易出错的一步：**旧版本核心的注册文件必须被识别为
/// 陈旧**，否则客户端会一路握手失败到超时，用户看到的是"应用连不上后台"。
void main() {
  CoreInfo sample({int protocol = coreProtocolVersion}) => CoreInfo(
        port: 47820,
        token: 'a' * 64,
        pid: 4242,
        protocolVersion: protocol,
        coreVersion: '3.0.0',
        exe: r'C:\app\core\easypass_core.exe',
      );

  group('CoreInfo.isStale（陈旧核心判定）', () {
    test('当前协议 ⇒ 不陈旧', () {
      expect(sample().isStale, isFalse);
    });

    test('协议 4（2.4.x 的 --service daemon）⇒ 陈旧', () {
      // 这是真实的升级场景：旧 daemon 写 protocolVersion=4 的文件，它不认识
      // 协议 5 的加密握手。
      expect(sample(protocol: 4).isStale, isTrue);
    });

    test('协议 0（没有版本号的 2.0 daemon）⇒ 陈旧', () {
      expect(sample(protocol: 0).isStale, isTrue);
    });

    test('协议高于当前（未来版本核心）⇒ 不算陈旧', () {
      // 让更高版本的核心自己服务；我们不该把它踢掉。
      expect(sample(protocol: coreProtocolVersion + 1).isStale, isFalse);
    });
  });

  group('CoreInfo.tryParse（宽容解析）', () {
    test('完整文件：四个字段都读出来', () {
      final parsed = CoreInfo.tryParse(jsonEncode(sample().toJson()));
      expect(parsed, isNotNull);
      expect(parsed!.port, 47820);
      expect(parsed.pid, 4242);
      expect(parsed.protocolVersion, coreProtocolVersion);
      expect(parsed.coreVersion, '3.0.0');
      expect(parsed.exe, contains('easypass_core.exe'));
    });

    test('2.4.x 的旧文件（没有 coreVersion / exe）⇒ coreVersion 为空但仍可解析', () {
      final legacy = jsonEncode({
        AppConstants.daemonInfoPortKey: 5000,
        AppConstants.daemonInfoTokenKey: 'b' * 64,
        AppConstants.daemonInfoProtocolVersionKey: 4,
        AppConstants.daemonInfoPidKey: 777,
      });
      final parsed = CoreInfo.tryParse(legacy);
      expect(parsed, isNotNull);
      expect(parsed!.coreVersion, isEmpty);
      expect(parsed.exe, isEmpty);
      expect(parsed.isStale, isTrue, reason: '旧版本核心必须被判为陈旧');
    });

    test('缺 port / token / pid ⇒ null（按陈旧残留处理）', () {
      expect(CoreInfo.tryParse('{}'), isNull);
      expect(
        CoreInfo.tryParse(jsonEncode({
          AppConstants.daemonInfoPortKey: 1,
          AppConstants.daemonInfoTokenKey: 'x',
          // 缺 pid
        })),
        isNull,
      );
    });

    test('损坏的 JSON / 非对象 ⇒ null，不抛异常', () {
      expect(CoreInfo.tryParse('{not json'), isNull);
      expect(CoreInfo.tryParse('[]'), isNull);
      expect(CoreInfo.tryParse('null'), isNull);
    });
  });

  group('CoreDiscovery（daemon.json 原子读写 / fail closed）', () {
    late Directory tempDir;
    late File infoFile;

    CoreInfo withPort(int port, {int? mcpPort}) => CoreInfo(
          port: port,
          token: 'a' * 64,
          pid: 4242,
          coreVersion: '3.1.0',
          exe: r'C:\app\core\easypass_core.exe',
          mcpPort: mcpPort,
        );

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('easypass_daemon_info_');
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

    test('文件不存在 ⇒ 返回 null（可以安全拉起核心）', () async {
      expect(await CoreDiscovery.read(), isNull);
    });

    test('写入后能原样读回，且不残留 .tmp 临时文件', () async {
      await CoreDiscovery.write(withPort(47820, mcpPort: 47821));

      final readBack = await CoreDiscovery.read();
      expect(readBack, isNotNull);
      expect(readBack!.port, 47820);
      expect(readBack.token, 'a' * 64);
      expect(readBack.pid, 4242);
      expect(readBack.mcpPort, 47821);
      expect(File('${infoFile.path}.tmp').existsSync(), isFalse,
          reason: '原子写完成后不应留下临时文件');
    });

    test('再次写入会替换旧内容（覆盖已有目标文件）', () async {
      await CoreDiscovery.write(withPort(1));
      await CoreDiscovery.write(withPort(2));

      final readBack = await CoreDiscovery.read();
      expect(readBack!.port, 2);
      expect(File('${infoFile.path}.tmp').existsSync(), isFalse);
    });

    test('写出的内容是完整合法 JSON（可被 CoreInfo.tryParse 解析）', () async {
      await CoreDiscovery.write(withPort(7));
      expect(CoreInfo.tryParse(await infoFile.readAsString()), isNotNull);
    });

    test('文件被截断 / 不是合法 JSON ⇒ 抛 CoreDiscoveryException', () async {
      await infoFile.writeAsString('{"port": 47820, "token": "abc"');
      await expectLater(
        CoreDiscovery.read(),
        throwsA(isA<CoreDiscoveryException>()),
        reason: '文件存在但读不懂时不能当成"没有核心"（否则 --lock 会 fail-open）',
      );
    });

    test('合法 JSON 但缺必需字段 ⇒ 抛 CoreDiscoveryException', () async {
      await infoFile.writeAsString('{}');
      await expectLater(
        CoreDiscovery.read(),
        throwsA(isA<CoreDiscoveryException>()),
      );
    });

    test('内容不是合法 UTF-8 ⇒ 抛 CoreDiscoveryException', () async {
      await infoFile.writeAsBytes([0xff, 0xfe, 0x00, 0x01]);
      await expectLater(
        CoreDiscovery.read(),
        throwsA(isA<CoreDiscoveryException>()),
      );
    });

    test('异常带文件路径，便于用户定位要删哪个文件', () async {
      await infoFile.writeAsString('not json');
      try {
        await CoreDiscovery.read();
        fail('应当抛出 CoreDiscoveryException');
      } on CoreDiscoveryException catch (error) {
        expect(error.path, infoFile.path);
        expect(error.message, contains('daemon.json'));
      }
    });
  });
}
