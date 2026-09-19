import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:easypass/features/browser_bridge/native_messaging_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// IO-level tests for the native messaging frame codec. These drive the
/// static [NativeMessagingService.readMessage] / [NativeMessagingService.encodeMessage]
/// directly with synthetic byte streams, covering the real-world chunking
/// behaviors of Chrome/Edge's native messaging pipe:
///
///   - the whole frame written in a single write (header + payload together),
///   - header and payload in separate writes,
///   - the header itself split across writes,
///   - the payload split across many small writes,
///   - EOF (browser closed the pipe) mid-frame.
///
/// The old implementation used `stdin.first` and assumed each read returned a
/// complete length header, which hung forever when the browser wrote the whole
/// frame at once. These tests pin the buffered, chunk-agnostic behavior.
void main() {
  /// Encode a JSON object as a native messaging frame, exactly as the
  /// browser would send it: 4-byte little-endian length + UTF-8 JSON bytes.
  Uint8List frameOf(Map<String, dynamic> message) {
    final json = utf8.encode(jsonEncode(message));
    final frame = Uint8List(4 + json.length);
    frame.buffer.asByteData().setUint32(0, json.length, Endian.little);
    frame.setAll(4, json);
    return frame;
  }

  /// Feed [chunks] as a finished stream and read one message.
  Future<Map<String, dynamic>?> readWith(List<List<int>> chunks) {
    return NativeMessagingService.readMessage(
        StreamIterator(Stream.fromIterable(chunks)));
  }

  const request = {'requestId': 'req-1', 'action': 'getStatus'};

  group('readMessage', () {
    test('parses a frame written in a single chunk (header + payload)',
        () async {
      final frame = frameOf(request);
      final message = await readWith([frame]);
      expect(message, request);
    });

    test('parses header and payload written as separate chunks', () async {
      final frame = frameOf(request);
      final message = await readWith([frame.sublist(0, 4), frame.sublist(4)]);
      expect(message, request);
    });

    test('parses a header that is itself split across writes', () async {
      final frame = frameOf(request);
      final message = await readWith([
        frame.sublist(0, 1),
        frame.sublist(1, 3),
        frame.sublist(3),
      ]);
      expect(message, request);
    });

    test('parses a payload split across many small writes', () async {
      final frame = frameOf(request);
      final chunks = <List<int>>[
        frame.sublist(0, 4),
        ...List.generate(frame.length - 4, (i) => [frame[4 + i]]),
      ];
      final message = await readWith(chunks);
      expect(message, request);
    });

    test('reads two consecutive frames from the same iterator', () async {
      final a = frameOf({'requestId': 'a', 'action': 'getStatus'});
      final b = frameOf({'requestId': 'b', 'action': 'lock'});
      // Interleave: header of a, body of a, whole b, to prove frame state
      // does not leak across messages.
      final it = StreamIterator(
          Stream.fromIterable([a.sublist(0, 4), a.sublist(4), b]));
      expect(await NativeMessagingService.readMessage(it),
          {'requestId': 'a', 'action': 'getStatus'});
      expect(await NativeMessagingService.readMessage(it),
          {'requestId': 'b', 'action': 'lock'});
      expect(await NativeMessagingService.readMessage(it), isNull);
    });

    test('reads two frames that arrive inside one chunk', () async {
      // 一个 chunk 里含两帧（bridge 把"握手帧 + 首个请求"一起写，或扩展连发
      // 两个请求被 loopback TCP 合并）：逐帧新建缓冲的读法会丢掉第二帧，
      // 对端于是永远等不到响应。这里钉住"残余字节必须留给下一次读取"。
      final a = frameOf({'requestId': 'a', 'action': 'getStatus'});
      final b = frameOf({'requestId': 'b', 'action': 'lock'});
      final it = StreamIterator(Stream.fromIterable([
        [...a, ...b]
      ]));
      expect(await NativeMessagingService.readMessage(it),
          {'requestId': 'a', 'action': 'getStatus'});
      expect(await NativeMessagingService.readMessage(it),
          {'requestId': 'b', 'action': 'lock'});
      expect(await NativeMessagingService.readMessage(it), isNull);
    });

    test('NativeMessageReader consumes coalesced frames in order', () async {
      final a = frameOf({'requestId': 'a', 'action': 'getStatus'});
      final b = frameOf({'requestId': 'b', 'action': 'lock'});
      final c = frameOf({'requestId': 'c', 'action': 'getStatus'});
      final reader = NativeMessageReader(StreamIterator(Stream.fromIterable([
        [...a, ...b.sublist(0, 3)],
        b.sublist(3),
        c,
      ])));
      expect(await reader.read(), {'requestId': 'a', 'action': 'getStatus'});
      expect(await reader.read(), {'requestId': 'b', 'action': 'lock'});
      expect(await reader.read(), {'requestId': 'c', 'action': 'getStatus'});
      expect(await reader.read(), isNull);
    });

    test('returns null on EOF before any byte', () async {
      final message = await readWith([]);
      expect(message, isNull);
    });

    test('returns null on EOF mid-frame (header only, payload never arrives)',
        () async {
      final frame = frameOf(request);
      final message = await readWith([frame.sublist(0, 4)]);
      expect(message, isNull);
    });

    test('handles UTF-8 multibyte payloads (Chinese text)', () async {
      final payload = {
        'requestId': 'req-1',
        'data': {'name': '密码管理器', 'note': '测试 ✓'},
      };
      final frame = frameOf(payload);
      final message = await readWith([frame]);
      expect(message, payload);
    });
  });

  group('encodeMessage', () {
    test('prepends a correct little-endian length prefix', () {
      final frame = NativeMessagingService.encodeMessage(request);
      final json = utf8.encode(jsonEncode(request));
      expect(frame.length, 4 + json.length);
      expect(frame.buffer.asByteData().getUint32(0, Endian.little), json.length);
      expect(frame.sublist(4), json);
    });

    test('round-trips through readMessage', () async {
      final frame = NativeMessagingService.encodeMessage(request);
      final message = await readWith([frame]);
      expect(message, request);
    });
  });
}
