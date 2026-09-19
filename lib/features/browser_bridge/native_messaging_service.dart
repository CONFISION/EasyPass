import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/constants/app_constants.dart';
import '../../core/crypto/crypto_service.dart';
import '../../core/crypto/totp_service.dart';
import '../../data/database/database.dart';
import '../health/health_service.dart';
import 'url_matcher.dart';
import 'vault_session.dart';

/// Handles Native Messaging communication with the browser extension
/// via stdin/stdout JSON protocol.
///
/// The host runs inside the desktop app process (`easypass.exe --native-host`,
/// see [main.dart]), sharing the same database file and secure storage. The
/// vault stays locked until the user sends an `unlock` action with the master
/// password; the derived key lives in a [VaultSession] (C 方案) so it can be
/// shared across connections when the daemon injects one.
class NativeMessagingService {
  final AppDatabase _db;
  final CryptoService _cryptoService;
  final TotpService _totpService;

  /// 会话（解锁态 + 密钥）。daemon 会注入一个跨连接共享的实例；
  /// 未注入时自建一个（单进程 `--native-host` 模式与既有测试行为不变）。
  final VaultSession _session;
  final bool _ownsSession;

  bool _running = false;

  /// TOTP 周期（秒），随 `getTotp` 一起下发，扩展据此画倒计时。
  static const int totpPeriodSeconds = 30;

  /// 每处理完一个请求回调一次；daemon 用它刷新"最后活动时间"，
  /// 供 `--service` 模式的空闲自退判断（见 [EasypassDaemon]）。
  /// 只报"发生了活动"，不传任何内容（不泄漏动作名/凭据）。
  final void Function()? onActivity;

  NativeMessagingService(this._db, this._cryptoService, this._totpService,
      {VaultSession? session, this.onActivity})
      : _session = session ?? VaultSession(),
        _ownsSession = session == null;

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
    // 注意（C 方案，契约 2.5）：**不**在这里清除解锁态。连接断开不是锁定
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
  /// 帧编解码是桥接协议的一部分，除本服务外也被 [EasypassDaemon.probe]（发
  /// 握手帧 + getStatus）和测试直接使用，所以**不是** testing-only API。
  static Uint8List encodeMessage(Map<String, dynamic> message) {
    final json = jsonEncode(message);
    final bytes = utf8.encode(json);
    final length = bytes.length;

    final header = Uint8List(4);
    header[0] = length & 0xff;
    header[1] = (length >> 8) & 0xff;
    header[2] = (length >> 16) & 0xff;
    header[3] = (length >> 24) & 0xff;

    return Uint8List.fromList([...header, ...bytes]);
  }

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

  /// 按域名匹配（契约 2.4）：不再用 `searchEntries(完整 URL)` 的 LIKE 模糊匹配，
  /// 否则 `https://github.com/login` 会因为 URL 里多了路径而漏掉条目。
  Future<List<Map<String, dynamic>>> _getCredentials(String? url) async {
    final key = _requireUnlocked();
    // url 缺失或不可解析 → 回退为全部条目（保持旧行为）。
    if (url == null || url.isEmpty || UrlMatcher.hostOf(url) == null) {
      return await _getAllCredentials();
    }

    final entries = await _db.getAllEntries();
    final matched = UrlMatcher.match(entries, url);
    _session.touch();
    return matched.map((e) => _entryToJson(e, key)).toList();
  }

  Future<List<Map<String, dynamic>>> _getAllCredentials() async {
    final key = _requireUnlocked();
    final entries = await _db.getAllEntries();
    _session.touch();
    return entries.map((e) => _entryToJson(e, key)).toList();
  }

  Future<List<Map<String, dynamic>>> _searchCredentials(String query) async {
    final key = _requireUnlocked();
    if (query.isEmpty) return await _getAllCredentials();
    final entries = await _db.searchEntries(query);
    _session.touch();
    return entries.map((e) => _entryToJson(e, key)).toList();
  }

  Future<Map<String, dynamic>> _getStatus() async {
    final count = await _db.getEntryCount();
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
    final storedSalt = await _cryptoService.getStoredSalt();
    final storedHash = await _cryptoService.getStoredPasswordHash();

    if (storedSalt == null || storedHash == null) {
      throw Exception('No master password configured');
    }

    final computedHash =
        _cryptoService.hashMasterPassword(password, storedSalt);
    if (computedHash == storedHash) {
      // Derive and keep the session key so credential fields can be
      // decrypted. The key lives in memory only until lock / idle timeout.
      _session.unlock(_cryptoService.deriveKey(password, storedSalt));
      return {'success': true};
    }
    throw Exception('Incorrect master password');
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

  Future<Map<String, dynamic>> _getTotp(String entryId) async {
    final key = _requireUnlocked();
    final entry = await _db.getEntryById(entryId);
    if (entry == null || (entry.totpSecretEncrypted ?? '').isEmpty) {
      throw Exception('No TOTP secret configured for this entry');
    }
    final secret = _decrypt(entry.totpSecretEncrypted, key);
    _session.touch();
    final totp = _totpService.generateTotp(secret);
    final remaining = _totpService.getRemainingSeconds();
    return {
      'totp': totp,
      'remaining': remaining,
      'period': totpPeriodSeconds,
    };
  }

  /// 健康报告（契约 2.3）：在**服务端**解密并分析，只回传统计数字与
  /// 条目 id/name，**绝不下发明文密码**（也不下发 TOTP 密钥）。
  Future<Map<String, dynamic>> _getHealthReport() async {
    final key = _requireUnlocked();
    final entries = await _db.getAllEntries();
    _session.touch();

    // 明文密码只存在于这个局部列表里，analyze 返回后即不可达
    // （报告本身只保留 id/name + 统计，见 health_service.dart）。
    final decrypted = <HealthEntry>[
      for (final entry in entries)
        HealthEntry(
          id: entry.id,
          name: entry.name,
          url: entry.url,
          password: _decryptLenient(entry.passwordEncrypted, key),
          totpSecret: (entry.totpSecretEncrypted ?? '').isEmpty
              ? null
              : _decryptLenient(entry.totpSecretEncrypted, key),
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
  Uint8List _requireUnlocked() {
    final key = _session.key;
    if (key == null) {
      throw Exception('Vault is locked');
    }
    return key;
  }

  /// Decrypt a stored field with the session key. Empty/null stays empty.
  String _decrypt(String? encrypted, Uint8List key) {
    if (encrypted == null || encrypted.isEmpty) return '';
    return _cryptoService.decryptData(encrypted, key);
  }

  /// 容错解密：单条失败返回空串而不是让整个操作失败（健康报告等批量场景），
  /// 与 health_provider.dart 的 `_decrypt` 风格一致。不抛异常、不打印明文。
  String _decryptLenient(String? encrypted, Uint8List key) {
    try {
      return _decrypt(encrypted, key);
    } catch (_) {
      return '';
    }
  }

  Map<String, dynamic> _entryToJson(PasswordEntry entry, Uint8List key) {
    return {
      'id': entry.id,
      'name': entry.name,
      'url': entry.url,
      'username': entry.username,
      'password': _decrypt(entry.passwordEncrypted, key),
      'notes': _decrypt(entry.notesEncrypted, key),
      // 安全改进：不再把 TOTP 明文密钥下发给浏览器，只告诉它"有没有配置"。
      // 取验证码一律走 getTotp（由本进程计算，密钥不出进程）。
      'hasTotp': (entry.totpSecretEncrypted ?? '').isNotEmpty,
      'isFavorite': entry.isFavorite,
    };
  }
}

/// 有状态的 native messaging 帧读取器：在同一个字节流上**连续**读取多帧，
/// 跨调用保留尚未消费的字节。
///
/// 为什么需要它：socket / pipe 的**一个 chunk 里完全可能同时到达两帧** ——
/// bridge 会把"握手帧 + 首个请求"写在一起，扩展连发的 `getStatus` +
/// `getAllCredentials` 也会被 loopback TCP 合并。早先的读法每帧都新建缓冲并把
/// `iterator.current` 整个 chunk 塞进去，多出来的第二帧字节在切出第一帧后被
/// 直接丢弃 → 对端永远等不到响应、只能超时（扩展"偶发卡死"的根因）。
///
/// 服务端必须全程共用同一个 reader：daemon 的握手帧由它读，随后把**同一个实例**
/// 交给 [NativeMessagingService.serve] 继续读请求。
class NativeMessageReader {
  final StreamIterator<List<int>> _iterator;

  /// 已从流中取出但尚未消费的字节（可能含下一帧的全部或部分）。
  final List<int> _pending = <int>[];

  NativeMessageReader(this._iterator);

  /// 读取下一帧；对端关闭（EOF）返回 null。
  Future<Map<String, dynamic>?> read() async {
    // 不足 4 字节长度头就继续读。
    while (_pending.length < 4) {
      if (!await _iterator.moveNext()) return null;
      _pending.addAll(_iterator.current);
    }

    final length = (_pending[0] & 0xff) |
        ((_pending[1] & 0xff) << 8) |
        ((_pending[2] & 0xff) << 16) |
        ((_pending[3] & 0xff) << 24);
    if (length <= 0) return null;

    // 不足整帧（4 + length）就继续读。
    while (_pending.length < 4 + length) {
      if (!await _iterator.moveNext()) return null;
      _pending.addAll(_iterator.current);
    }

    final payload = _pending.sublist(4, 4 + length);
    // 只消费这一帧，同一 chunk 里剩下的字节留给下一次 read()。
    _pending.removeRange(0, 4 + length);
    return jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
  }
}
