// P3.3 · Linux 旧进程自愈（`_terminateIfOurs`）测试。
//
// 全部通过 `debugSetTerminateIfOursRunner` 注入替身 —— **不**真杀任何
// 进程、**不**真 `kill -0`：
//   1. 自身 pid（target == pid）→ 拒绝，**不**调 runner 任何方法。
//   2. `kill -0` 失败 → 保守保留（return false）→ 不发 SIGTERM / SIGKILL。
//   3. `kill -0` 成功 → SIGTERM → 2s 等待 → 二次 `kill -0` = false → 判
//      已结束。
//   4. SIGTERM 后二次 `kill -0` = true → 升级 SIGKILL → 1s 等待 → 第三次
//      `kill -0` = false → 仍判已结束（降级行为）。
//   5. SIGKILL 后三次 `kill -0` = true（极端）→ 判失败（return false）。
//   6. SIGTERM 投递失败（EPERM）→ 保守保留，**不**升级 SIGKILL。
//   7. 默认 runner 在 Linux 上**不**抛异常（用不存在的 pid）。
//   8. Windows 上注入的 Linux runner **不**被调用（保证 Linux-only 改动
//      不污染 Windows 路径）。
//   9. `probe()` 死 pid + `retire()` 清 `daemon.json` 的整条链路在 P3.3
//      改动后**不**退化。
//
// 不可自动化的项：
//   - 真实 2s 超时：测试替身把 wait() 替换成瞬时，节省 CI 时间（生产
//     默认走 `Future.delayed`；超时常量在源码里有注释说明）。
//   - 真实 fork 进程（pid 复用 race）：本轮不模拟，列入"手工未自动化"。

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/data/database/database.dart';
import 'package:easypass/features/browser_bridge/easypass_daemon.dart';

/// 把 `kill -0` / 发信号 / 等延迟 做成可替身；每一步记进 log。
///
/// **不**真发任何信号 / 真起任何进程。测试替身与 [_terminateIfOursLinux]
/// 走同一条调用链 —— 唯一不同是 [_DefaultTerminateIfOursRunner] 换成
/// 这个 in-memory 实现。
class _RecordingRunner implements TerminateIfOursRunner {
  final List<String> log = [];

  /// 每次 [pidAlive] 调用应返回的值（按顺序消费）。默认 = 一直 true。
  final List<bool> aliveResponses;

  /// 每次 [sendSignal] 调用应返回的值（按顺序消费）。默认 = 一直 true。
  final List<bool> signalResponses;

  _RecordingRunner({
    List<bool>? aliveResponses,
    List<bool>? signalResponses,
  })  : aliveResponses = aliveResponses == null
            ? <bool>[true]
            : List<bool>.from(aliveResponses),
        signalResponses = signalResponses == null
            ? <bool>[true]
            : List<bool>.from(signalResponses);

  int _aliveCallIdx = 0;
  int _signalCallIdx = 0;

  @override
  Future<bool> pidAlive(int pid) async {
    log.add('pidAlive($pid)');
    final r = _aliveCallIdx < aliveResponses.length
        ? aliveResponses[_aliveCallIdx]
        : aliveResponses.last;
    _aliveCallIdx++;
    return r;
  }

  @override
  Future<bool> sendSignal(int pid, ProcessSignal signal) async {
    log.add('sendSignal($pid, ${_signalName(signal)})');
    final r = _signalCallIdx < signalResponses.length
        ? signalResponses[_signalCallIdx]
        : signalResponses.last;
    _signalCallIdx++;
    return r;
  }

  @override
  Future<void> wait(Duration duration) async {
    log.add('wait(${duration.inMilliseconds}ms)');
    // 0ms —— 测试 CI 不真等 2s。生产默认走 Future.delayed。
  }
}

String _signalName(ProcessSignal signal) {
  if (signal == ProcessSignal.sigterm) return 'SIGTERM';
  if (signal == ProcessSignal.sigkill) return 'SIGKILL';
  return signal.toString();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EasypassDaemon.debugSetTerminateIfOursRunner(
      const DefaultTerminateIfOursRunner(),
    );
  });

  group('P3.3 · _terminateIfOurs Linux 路径（注入 runner）', () {
    test('自身 pid（target == pid）→ 拒绝，**不**调 runner 任何方法',
        () async {
      final stub = _RecordingRunner();
      EasypassDaemon.debugSetTerminateIfOursRunner(stub);

      final killed = await EasypassDaemon.debugTerminateIfOursForTesting(pid);
      expect(killed, isFalse);
      expect(stub.log, isEmpty,
          reason: '绝不能杀自己；runner 一个方法都不该被调到');
    });

    test('Linux：kill -0 → SIGTERM → 进程退出 → 二次确认 alive=false → 判结束',
        () async {
      final stub = _RecordingRunner(
        aliveResponses: [true, false], // 1=alive, 2=dead
        signalResponses: [true], // SIGTERM 投递成功
      );
      EasypassDaemon.debugSetTerminateIfOursRunner(stub);

      final killed =
          await EasypassDaemon.debugTerminateIfOursForTesting(pid + 1);
      expect(killed, isTrue);
      expect(stub.log, [
        'pidAlive(${pid + 1})',
        'sendSignal(${pid + 1}, SIGTERM)',
        'wait(2000ms)',
        'pidAlive(${pid + 1})',
      ], reason: 'kill -0 → SIGTERM → wait 2s → 二次 kill -0');
    });

    test('Linux：kill -0 失败（PID 不存在）→ 保守保留，不发任何信号',
        () async {
      final stub = _RecordingRunner(
        aliveResponses: [false],
        signalResponses: [false],
      );
      EasypassDaemon.debugSetTerminateIfOursRunner(stub);

      final killed =
          await EasypassDaemon.debugTerminateIfOursForTesting(pid + 1);
      expect(killed, isFalse);
      expect(stub.log, ['pidAlive(${pid + 1})'],
          reason: 'PID 不存在：一步到位，根本不发 SIGTERM');
    });

    test('Linux：SIGTERM 后进程仍存活 → SIGKILL 兜底', () async {
      final stub = _RecordingRunner(
        aliveResponses: [true, true, false], // 1=alive, 2=alive, 3=dead
        signalResponses: [true, true], // SIGTERM + SIGKILL 都成功
      );
      EasypassDaemon.debugSetTerminateIfOursRunner(stub);

      final killed =
          await EasypassDaemon.debugTerminateIfOursForTesting(pid + 1);
      expect(killed, isTrue);
      expect(stub.log, [
        'pidAlive(${pid + 1})',
        'sendSignal(${pid + 1}, SIGTERM)',
        'wait(2000ms)',
        'pidAlive(${pid + 1})', // 二次确认还活着
        'sendSignal(${pid + 1}, SIGKILL)',
        'wait(1000ms)',
        'pidAlive(${pid + 1})', // 最终确认
      ], reason: '升级到 SIGKILL 后再确认一次');
    });

    test('Linux：SIGKILL 后进程仍存活（极端）→ 保守保留', () async {
      final stub = _RecordingRunner(
        aliveResponses: [true, true, true], // 持续活着
        signalResponses: [true, true],
      );
      EasypassDaemon.debugSetTerminateIfOursRunner(stub);

      final killed =
          await EasypassDaemon.debugTerminateIfOursForTesting(pid + 1);
      expect(killed, isFalse,
          reason: 'SIGKILL 都杀不死 → 保守保留，由 retire() 的 clearStaleInfo 兜底');
      expect(stub.log.length, 7);
    });

    test('Linux：SIGTERM 投递失败（EPERM）→ 保守保留，不升级 SIGKILL',
        () async {
      final stub = _RecordingRunner(
        aliveResponses: [true], // 一直活着
        signalResponses: [false], // SIGTERM 失败；不应再发 SIGKILL
      );
      EasypassDaemon.debugSetTerminateIfOursRunner(stub);

      final killed =
          await EasypassDaemon.debugTerminateIfOursForTesting(pid + 1);
      expect(killed, isFalse);
      expect(stub.log, [
        'pidAlive(${pid + 1})',
        'sendSignal(${pid + 1}, SIGTERM)',
      ], reason: 'SIGTERM 失败：不再二次 pidAlive、不再升级 SIGKILL');
      expect(stub.log.where((e) => e.contains('SIGKILL')), isEmpty);
    });
  });

  group('P3.3 · Linux 默认 runner（真实 `kill` 命令）', () {
    test('不存在的 pid → 默认 runner 走 kill -0 → exitCode=1 → 保守保留',
        () async {
      EasypassDaemon.debugSetTerminateIfOursRunner(
        const DefaultTerminateIfOursRunner(),
      );
      // 用一个显然不存在的 pid（2^31-1）；生产代码在容器里没有 `kill`
      // 时会抛 ProcessException、被默认实现吞掉并返回 true（保守保留）。
      // **任何**情况下都不应抛到测试侧。
      final result =
          await EasypassDaemon.debugTerminateIfOursForTesting(0x7ffffffd);
      expect(result, isFalse,
          reason: '不存在的 pid：默认 kill -0 → exitCode != 0 → 返回 false');
    });
  });

  group('P3.3 · Windows 路径不污染', () {
    test('Windows 上注入的 Linux runner **不**被调用（保证改动只在 Linux 生效）',
        () async {
      if (!Platform.isWindows) {
        // 测试期望：Windows 走 Windows tasklist 路径，Linux runner 一
        // 个方法都不该被调到。Linux CI 上这个用例不适用 —— 跳过即可。
        return;
      }
      final stub = _RecordingRunner();
      EasypassDaemon.debugSetTerminateIfOursRunner(stub);

      // 用一个显然不存在的 pid 触发 Windows tasklist 路径（tasklist 会
      // 返回 "INFO: No tasks ..."，命中不到 easypass.exe → return false）。
      // 注入的 stub 永远不应该被 Windows 路径调到。
      final killed =
          await EasypassDaemon.debugTerminateIfOursForTesting(0x7ffffffd);
      expect(killed, isFalse);
      expect(stub.log, isEmpty,
          reason: 'Windows 路径只走 tasklist，Linux runner 是 Linux-only');
    });
  });

  group('P3.3 · probe 死 pid → 清 daemon.json（路径不退化）', () {
    late Directory tempDir;
    late File probeFile;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync(
          'easypass_p33_${DateTime.now().microsecondsSinceEpoch}');
      probeFile =
          File('${tempDir.path}${Platform.pathSeparator}daemon.json');
    });

    tearDown(() async {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('daemon.json 指向不存在的 pid → probe=unreachable + retire 清文件',
        () async {
      const impossiblePid = 0x7ffffffd;
      probeFile.writeAsStringSync(
          '{"port":1,"token":"x","protocolVersion":3,"pid":$impossiblePid}');

      final result = await EasypassDaemon.probe(infoFile: probeFile);
      expect(result.status, DaemonProbeStatus.unreachable);
      expect(result.needsCleanup, isTrue);

      final killed =
          await EasypassDaemon.retire(result, infoFile: probeFile);
      expect(killed, isFalse,
          reason: '目标已死 → _terminateIfOurs 不该尝试杀（pidAlive 返回 false）');
      expect(probeFile.existsSync(), isFalse,
          reason: '死 pid 必须清 daemon.json（避免桥接超时）');
    });
  });
}