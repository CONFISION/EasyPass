/// 桥接 / 核心服务的**帧编解码**：4 字节小端长度头 + 负载。
///
/// 协议 5 起负载分两种：
/// - **握手阶段**：明文 JSON（只有 nonce 与 HMAC 证明，令牌不上线）；
/// - **之后**：AES-256-CBC + HMAC-SHA256 的密文（见 `secure_channel.dart`）。
///
/// 分帧只负责"切出负载"，加解密由 [SecureChannel] 负责 —— 所以这里同时提供
/// [NativeMessageReader.readBytes]（原始负载）与 [read]（明文 JSON 快捷方式）。
///
/// 这段实现原来住在 `lib/features/browser_bridge/native_messaging_service.dart`，
/// 现在抽成协议层的唯一实现：核心服务、桥接、探针、测试都从这里取，避免两套实现漂移。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// 单帧最大字节数：防御性上限，避免损坏/恶意的长度前缀让我们无限等待。
const int maxFramePayloadBytes = 64 * 1024 * 1024;

/// 把一个 JSON 消息编码成帧（4 字节小端长度前缀 + UTF-8 JSON 负载）。
Uint8List encodeMessage(Map<String, dynamic> message) =>
    encodePayload(Uint8List.fromList(utf8.encode(jsonEncode(message))));

/// 把**已经编码好的负载**（协议 5 的密文）包成帧。
Uint8List encodePayload(Uint8List payload) {
  final length = payload.length;
  final header = Uint8List(4);
  header[0] = length & 0xff;
  header[1] = (length >> 8) & 0xff;
  header[2] = (length >> 16) & 0xff;
  header[3] = (length >> 24) & 0xff;
  return Uint8List.fromList([...header, ...payload]);
}

/// 有状态的帧读取器：在同一个字节流上**连续**读取多帧，跨调用保留未消费的字节。
///
/// 为什么必须有状态：socket / pipe 的**一个 chunk 里完全可能同时到达两帧** ——
/// 桥会把"握手帧 + 首个请求"写在一起，扩展连发的两个请求也会被回环 TCP 合并。
/// 每帧新建缓冲的读法会把同一 chunk 里的第二帧丢掉，对端只能等超时。
class NativeMessageReader {
  final StreamIterator<List<int>> _iterator;

  /// 已从流中取出但尚未消费的字节（可能含下一帧的全部或部分）。
  final List<int> _pending = <int>[];

  NativeMessageReader(this._iterator);

  /// 读取下一帧的**原始负载字节**（不含 4 字节长度头）；对端关闭返回 null。
  Future<Uint8List?> readBytes() async {
    while (_pending.length < 4) {
      if (!await _iterator.moveNext()) return null;
      _pending.addAll(_iterator.current);
    }

    final length = (_pending[0] & 0xff) |
        ((_pending[1] & 0xff) << 8) |
        ((_pending[2] & 0xff) << 16) |
        ((_pending[3] & 0xff) << 24);
    if (length <= 0 || length > maxFramePayloadBytes) return null;

    while (_pending.length < 4 + length) {
      if (!await _iterator.moveNext()) return null;
      _pending.addAll(_iterator.current);
    }

    final payload = Uint8List.fromList(_pending.sublist(4, 4 + length));
    // 只消费这一帧，同一 chunk 里剩下的字节留给下一次读取。
    _pending.removeRange(0, 4 + length);
    return payload;
  }

  /// 读取下一帧并解析成 JSON（**明文负载**：只有握手阶段用它）。
  Future<Map<String, dynamic>?> read() async {
    final payload = await readBytes();
    if (payload == null) return null;
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }
}
