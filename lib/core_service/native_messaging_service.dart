import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:easypass/protocol/frames.dart' as frames;
import 'package:easypass/protocol/frames.dart' show NativeMessageReader;

import '../../core/constants/app_constants.dart';
import '../../core/crypto/crypto_service.dart';
import '../../core/crypto/totp_service.dart';
import '../../data/database/database.dart';
import '../../data/models/entry_type.dart';
import '../../data/models/vault_item.dart';
import '../../data/repositories/vault_repository.dart';
import '../../data/services/master_password_rotation.dart';
import 'package:easypass/features/health/health_service.dart';
import 'url_matcher.dart';
import 'vault_session.dart';

/// 帧读取器/编码器现在**只有一份实现**（`lib/protocol/frames.dart`）：
/// 核心服务与桥接共用，避免两套实现漂移。这里 re-export 是为了让既有调用方
/// （`easypass_daemon.dart`、测试）的 import 保持不变。
export 'package:easypass/protocol/frames.dart' show NativeMessageReader;

/// Handles Native Messaging communication with the browser extension
/// via stdin/stdout JSON protocol.
///
/// The host runs inside the desktop app process (`easypass.exe --native-host`,
/// see [main.dart]), sharing the same database file and secure storage. The
/// vault stays locked until the user sends an `unlock` action with the master
/// password; the derived key lives in a [VaultSession] (C 方案) so it can be
/// shared across connections when the daemon injects one.
///
/// 2.3.0 起条目有四种类型（登录 / 安全笔记 / 身份 / SSH 密钥），数据访问统一走
/// [VaultRepository]：它按"当前会话密钥"现读现解密，返回已经解密的 [VaultItem]，
/// 本服务不再自己碰 `*_encrypted` 列（列名 / 载荷格式由 `VaultItemMapper` 冻结）。
/// 自动填充（`getCredentials`）与健康报告只认**登录**条目；`getAllCredentials` /
/// `searchCredentials` 返回所有类型，供扩展的保险库列表展示与复制。
class NativeMessagingService {
  final AppDatabase _db;
  final CryptoService _cryptoService;
  final TotpService _totpService;

  /// 会话（解锁态 + 密钥）。daemon 会注入一个跨连接共享的实例；
  /// 未注入时自建一个（单进程 `--native-host` 模式与既有测试行为不变）。
  final VaultSession _session;
  final bool _ownsSession;

  /// 数据入口（解密后的 [VaultItem]）。密钥**每次现读** [_session]，
  /// 所以解锁 / 锁定 / 空闲过期都不需要重建它。
  late final VaultRepository _repository;

  bool _running = false;

  /// TOTP 周期（秒），随 `getTotp` 一起下发，扩展据此画倒计时。
  static const int totpPeriodSeconds = 30;

  /// 每处理完一个请求回调一次；daemon 用它刷新"最后活动时间"，
  /// 供 `--service` 模式的空闲自退判断（见 [EasypassDaemon]）。
  /// 只报"发生了活动"，不传任何内容（不泄漏动作名/凭据）。
  final void Function()? onActivity;

  /// [repository] 只在调用方想自己控制数据入口时传入（daemon 会传一个绑定
  /// 共享会话的实例）；不传就用 [_session] 自建一个。
  NativeMessagingService(this._db, this._cryptoService, this._totpService,
      {VaultSession? session, this.onActivity, VaultRepository? repository})
      : _session = session ?? VaultSession(),
        _ownsSession = session == null {
    _repository = repository ??
        VaultRepository(
          db: _db,
          cryptoService: _cryptoService,
          keyReader: () => _session.key,
        );
  }

  /// 当前会话是否已解锁（惰性过期：空闲超时会在这里就变成 false）。
  bool get isUnlocked => _session.isUnlocked;

  /// Start the native messaging host listening on stdin (browser-launched
  /// host mode).
  Future<void> start() =>
      serve(NativeMessageReader(StreamIterator(stdin)), stdout);

  /// Serve the native messaging protocol over [reader].
  ///
  /// Used by the browser-launched host (stdin/stdout) and by the 2.0 daemon
  /// (a TCP socket). [reader] must already be positioned after any handshake
  /// frame — daemon 的握手和这里共用同一个 reader，这样"握手帧 + 首个请求"
  /// 落在同一个 chunk 里也不会丢帧。Responses are written to [output] as
  /// length-prefixed JSON frames.
  Future<void> serve(NativeMessageReader reader, IOSink output) async {
    if (_running) return;
    _running = true;

    while (_running) {
      try {
        final message = await reader.read();
        if (message == null) {
          break; // peer closed the stream
        }
        final response = await handleRequest(message);
        onActivity?.call();
        await _writeFrame(output, response);
      } catch (e) {
        if (!_running) break;
        onActivity?.call();
        await _writeFrame(output, {'error': e.toString()});
      }
    }
  }

  Future<void> _writeFrame(IOSink output, Map<String, dynamic> response) async {
    output.add(encodeMessage(response));
    // The stream buffers; without an explicit flush the peer (browser or
    // daemon client) would never receive the response.
    await output.flush();
  }

  void stop() {
    _running = false;
    // 注意：**不**在这里清除解锁态。连接断开不是锁定
    // 信号，只有 `lock` 动作、空闲超时、进程退出才清除密钥。
    // 例外：自建会话（`--native-host` 单进程模式）随服务一起停止，
    // 保持旧行为；daemon 注入的共享会话不受影响。
    if (_ownsSession) {
      _session.lock();
    }
  }

  /// Encode a JSON message as a native-messaging frame: a 4-byte little-endian
  /// length prefix followed by the UTF-8 JSON bytes.
  ///
  /// 委托给协议层的**唯一实现**（`lib/protocol/frames.dart`）：核心服务、
  /// 桥接、探针共用同一份，不再各写一套。
  static Uint8List encodeMessage(Map<String, dynamic> message) =>
      frames.encodeMessage(message);

  /// 每个 [StreamIterator] 对应一个有状态读取器：同一个 iterator 上连续调用
  /// 本方法时，上一帧所在 chunk 里多出来的字节会保留下来（见 [NativeMessageReader]）。
  /// Expando 以 iterator 为弱引用键，iterator 回收后条目自动消失，不会泄漏。
  static final Expando<NativeMessageReader> _readers =
      Expando<NativeMessageReader>('easypassNativeMessageReaders');

  /// Read one native-messaging frame from [iterator]: a 4-byte little-endian
  /// length prefix followed by that many UTF-8 JSON bytes.
  ///
  /// The browser may write the header and the payload in a single write or
  /// split them across arbitrary chunk boundaries (e.g. header in one write
  /// and payload in another, or even the header itself split), so bytes are
  /// accumulated until both the header and the full payload are available.
  ///
  /// Returns the decoded message, or null on EOF (peer closed the pipe).
  ///
  /// 一个 chunk 里**可能同时到达多帧**（bridge 把"握手帧 + 首个请求"一起写，
  /// 或扩展连发两个请求后被 TCP 合并）：因此同一个 [iterator] 上连续调用本方法
  /// 时会接着上次的缓冲继续读，不会丢掉第二帧。需要显式控制缓冲生命周期的场景
  /// （daemon 的握手 + serve 循环）请直接用 [NativeMessageReader]。
  static Future<Map<String, dynamic>?> readMessage(
      StreamIterator<List<int>> iterator) {
    return (_readers[iterator] ??= NativeMessageReader(iterator)).read();
  }

  /// Handle a single incoming message from the browser extension.
  /// Public so the protocol can be unit-tested without a real stdin/stdout.
  Future<Map<String, dynamic>> handleRequest(Map<String, dynamic> message) async {
    final requestId = message['requestId'] as String?;
    final action = message['action'] as String?;
    final baseResponse = <String, dynamic>{'requestId': requestId};

    try {
      switch (action) {
        case 'getCredentials':
          return baseResponse
            ..['data'] = await _getCredentials(message['url'] as String?);

        case 'getAllCredentials':
          return baseResponse..['data'] = await _getAllCredentials();

        case 'searchCredentials':
          return baseResponse
            ..['data'] =
                await _searchCredentials(message['query'] as String? ?? '');

        case 'getStatus':
          return baseResponse..['data'] = await _getStatus();

        case 'unlock':
          return baseResponse
            ..['data'] = await _unlock(message['password'] as String? ?? '');

        case 'lock':
          _session.lock();
          return baseResponse..['data'] = {'success': true};

        case 'generatePassword':
          return baseResponse
            ..['data'] =
                _generatePassword(message['options'] as Map<String, dynamic>?);

        case 'getTotp':
          return baseResponse
            ..['data'] = await _getTotp(message['entryId'] as String? ?? '');

        case 'getHealthReport':
          return baseResponse..['data'] = await _getHealthReport();

        default:
          return baseResponse..['error'] = 'Unknown action: $action';
      }
    } catch (e) {
      return baseResponse..['error'] = e.toString();
    }
  }

  // ─── Action Handlers ────────────────────────────────────

  /// 按域名匹配：不再用 `searchEntries(完整 URL)` 的 LIKE 模糊匹配，
  /// 否则 `https://github.com/login` 会因为 URL 里多了路径而漏掉条目。
  ///
  /// **只返回登录条目**：安全笔记 / 身份 / SSH 密钥不参与自动填充；
  /// 匹配失败回退"全部条目"时同样只给登录条目，否则扩展的填充面板里会冒出笔记。
  Future<List<Map<String, dynamic>>> _getCredentials(String? url) async {
    _requireUnlocked();
    final items = await _repository.getItems(type: EntryType.login);
    // url 缺失或不可解析 → 回退为全部**登录**条目（保持旧行为）。
    if (url == null || url.isEmpty || UrlMatcher.hostOf(url) == null) {
      _session.touch();
      return items.map(_entryToJson).toList();
    }

    final matched = UrlMatcher.match(items, url);
    _session.touch();
    return matched.map(_entryToJson).toList();
  }

  /// popup 的保险库列表用：**所有**类型（含安全笔记 / 身份 / SSH 密钥）。
  Future<List<Map<String, dynamic>>> _getAllCredentials() async {
    _requireUnlocked();
    final items = await _repository.getItems();
    _session.touch();
    return items.map(_entryToJson).toList();
  }

  Future<List<Map<String, dynamic>>> _searchCredentials(String query) async {
    _requireUnlocked();
    if (query.isEmpty) return await _getAllCredentials();
    // searchItems 解密后匹配类型专属字段（证件号 / SSH 指纹 / 自定义字段），
    // 不只是 name/url/username 三列。
    final items = await _repository.searchItems(query);
    _session.touch();
    return items.map(_entryToJson).toList();
  }

  Future<Map<String, dynamic>> _getStatus() async {
    // entryCount 的语义是"保险库里一共有多少条目"（所有类型），不是登录条目数。
    final count = await _repository.countItems();
    // 注意：getStatus 是"看状态"，不算活跃操作，因此**不** touch()，
    // 否则扩展轮询状态就会让空闲计时器永远不过期。
    final remaining = _session.remaining;
    return {
      'connected': true,
      'locked': remaining == null,
      'entryCount': count,
      'idleTimeoutSeconds': _session.idleTimeout.inSeconds,
      'autoLockRemainingSeconds': remaining?.inSeconds,
      // 本构建的桥接协议版本：UI 启动时用它判定"跑的是不是旧 daemon"
      // （见 EasypassDaemon.probe），扩展侧也用它给"未知操作"类错误定性。
      'protocolVersion': AppConstants.bridgeProtocolVersion,
    };
  }

  Future<Map<String, dynamic>> _unlock(String password) async {
    // 校验走**唯一口径**（MasterPasswordVerifier）：它同时看轮换日志与钥匙串。
    // 曾经这里是自己拿 secure storage 的 salt/hash 现算现比 —— 那样在"轮换已提交、
    // 校验材料还没写进钥匙串"的窗口里，扩展会继续认旧密码、拒绝新密码，也就是
    // 用户看到的"App 里改了主密码，扩展那边旧密码还能用"。
    final verifier = MasterPasswordVerifier(
      db: _db,
      cryptoService: _cryptoService,
    );

    final check = await verifier.verify(password);
    if (check == null) {
      if (!await verifier.hasStoredCredential()) {
        throw Exception('No master password configured');
      }
      throw Exception('Incorrect master password');
    }

    // Derive and keep the session key so credential fields can be
    // decrypted. The key lives in memory only until lock / idle timeout.
    _session.unlock(check.key);
    return {'success': true};
  }

  Map<String, dynamic> _generatePassword(Map<String, dynamic>? options) {
    final length = options?['length'] as int? ?? 16;
    final useUpper = options?['useUpper'] as bool? ?? true;
    final useLower = options?['useLower'] as bool? ?? true;
    final useNumbers = options?['useNumbers'] as bool? ?? true;
    final useSymbols = options?['useSymbols'] as bool? ?? true;

    final random = Random.secure();
    final charSets = <String>[];

    if (useUpper) charSets.add('ABCDEFGHIJKLMNOPQRSTUVWXYZ');
    if (useLower) charSets.add('abcdefghijklmnopqrstuvwxyz');
    if (useNumbers) charSets.add('0123456789');
    if (useSymbols) charSets.add('!@#\$%^&*()-_=+[]{}|;:,.<>?');

    if (charSets.isEmpty) return {'password': ''};

    final allChars = charSets.join();
    final buffer = StringBuffer();
    for (final set in charSets) {
      buffer.write(set[random.nextInt(set.length)]);
    }
    while (buffer.length < length) {
      buffer.write(allChars[random.nextInt(allChars.length)]);
    }
    final chars = buffer.toString().split('')..shuffle(random);

    return {'password': chars.join()};
  }

  /// 取动态验证码：**只有登录条目**有意义。
  ///
  /// 非登录条目返回错误（沿用既有 `{'error': ...}` 风格），而不是回一个空验证码
  /// —— 空码会被扩展画成"000000 已过期"这种误导性状态。TOTP 密钥始终留在本
  /// 进程内，只把算出来的 6 位码下发。
  Future<Map<String, dynamic>> _getTotp(String entryId) async {
    _requireUnlocked();
    final item = await _repository.getItem(entryId);
    if (item == null) {
      throw Exception('No TOTP secret configured for this entry');
    }
    if (!item.isLogin) {
      throw Exception('Entry is not a login entry (${item.type.wireName})');
    }
    final secret = item.loginOrEmpty.totpSecret;
    if (secret.isEmpty) {
      throw Exception('No TOTP secret configured for this entry');
    }
    _session.touch();
    final totp = _totpService.generateTotp(secret);
    final remaining = _totpService.getRemainingSeconds();
    return {
      'totp': totp,
      'remaining': remaining,
      'period': totpPeriodSeconds,
    };
  }

  /// 健康报告：只分析**登录条目**，在服务端解密并统计，
  /// 只回传统计数字与条目 id/name，**绝不下发明文密码**（也不下发 TOTP 密钥）。
  ///
  /// 非登录条目没有"密码强弱 / 缺网址"这些概念：安全笔记本来就没有 URL，
  /// 混进来会白白变成 `noUrl` 问题并把分数拉低，所以在这里就按类型过滤掉，
  /// `totalEntries` 也只数被分析过的登录条目。
  Future<Map<String, dynamic>> _getHealthReport() async {
    _requireUnlocked();
    final items = await _repository.getItems(type: EntryType.login);
    _session.touch();

    // 明文密码只存在于这个局部列表里，analyze 返回后即不可达
    // （报告本身只保留 id/name + 统计，见 health_service.dart）。
    final decrypted = <HealthEntry>[
      for (final item in items)
        HealthEntry(
          id: item.id,
          name: item.name,
          url: item.loginOrEmpty.url,
          password: item.loginOrEmpty.password,
          totpSecret: item.loginOrEmpty.totpSecret.trim().isEmpty
              ? null
              : item.loginOrEmpty.totpSecret,
        ),
    ];

    final report = HealthService.analyze(decrypted);
    return {
      'score': report.score,
      'level': report.level.name, // good | fair | poor
      'totalEntries': report.totalEntries,
      'reusedGroupCount': report.reusedGroupCount,
      'weakPasswords': [
        for (final issue in report.weakPasswords)
          {
            'id': issue.entryId,
            'name': issue.entryName,
            // 枚举名：tooShort | singleCharType | commonPassword
            'reason': issue.reason.name,
          },
      ],
      'reusedPasswords': [
        for (final issue in report.reusedPasswords)
          {
            'id': issue.entryId,
            'name': issue.entryName,
            'sharedCount': issue.sharedCount,
          },
      ],
      'noTotp': [
        for (final issue in report.noTotpEntries)
          {'id': issue.entryId, 'name': issue.entryName},
      ],
      'noUrl': [
        for (final issue in report.noUrlEntries)
          {'id': issue.entryId, 'name': issue.entryName},
      ],
    };
  }

  // ─── Helpers ────────────────────────────────────────────

  /// 断言已解锁并返回当前会话密钥（惰性过期在 [VaultSession.key] 里生效）。
  /// 返回值由调用方在整个操作期间持有，避免读到一半被自动锁定。
  ///
  /// 数据读取本身走 [_repository]（它的 keyReader 同样现读 [_session]），
  /// 这里主要承担"锁定时立刻报错"的门禁职责。
  Uint8List _requireUnlocked() {
    final key = _session.key;
    if (key == null) {
      throw Exception('Vault is locked');
    }
    return key;
  }

  /// [VaultItem] → **协议 3** 的条目 JSON（键名与形状冻结）。
  ///
  /// - `url` / `username` / `password`：登录条目取登录字段；身份条目的
  ///   `username` 取 `identity.username`；其余类型一律空串（扩展侧不必判 null）；
  /// - `hasTotp`：只有登录条目可能为 true，且**绝不**下发 TOTP 密钥本身
  ///   （取验证码一律走 `getTotp`，密钥不出进程）；
  /// - `identity` / `sshKey`：直接复用 `IdentityData.toJson()` /
  ///   `SshKeyData.toJson()`（snake_case 键名），非本类型时为 null；
  /// - `customFields`：始终是数组（空时为 `[]`），元素来自 `CustomField.toJson()`。
  ///
  /// 解密失败的单条字段由 `VaultItemMapper` 的宽容模式按空串处理，
  /// 一条坏数据不会让整个列表请求失败（也不会有任何明文被写回）。
  Map<String, dynamic> _entryToJson(VaultItem item) {
    final login = item.loginOrEmpty;
    return {
      'id': item.id,
      'type': item.type.wireName,
      'name': item.name,
      'url': login.url,
      'username': item.type == EntryType.identity
          ? item.identityOrEmpty.username
          : login.username,
      'password': login.password,
      'notes': item.notes,
      'hasTotp': item.isLogin && login.hasTotp,
      'isFavorite': item.isFavorite,
      'identity': item.identity?.toJson(),
      'sshKey': item.sshKey?.toJson(),
      'customFields': [
        for (final field in item.customFields) field.toJson(),
      ],
    };
  }
}

