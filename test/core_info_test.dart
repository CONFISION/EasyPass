import 'dart:convert';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/core_service/core_info.dart';
import 'package:easypass/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
