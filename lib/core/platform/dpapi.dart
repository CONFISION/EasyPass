import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Windows DPAPI（用户作用域）封装 —— 用来把"智能体专属密钥"落到本机。
///
/// 为什么用它：核心是**无 Flutter** 的 AOT 程序，用不了 `flutter_secure_storage`；
/// 而零介入解锁要求密钥能存在本机。DPAPI 是 Windows 自带的用户态加密：
/// - 用当前登录用户的凭据派生密钥，**别的 Windows 用户解不开**；
/// - blob 绑定用户与机器，拷到别的机器/账户也解不开；
/// - 额外传 `pOptionalEntropy`，不认识这个 entropy 的通用工具也解不开。
///
/// **边界（必须诚实）**：它挡不住"以同一用户身份运行的恶意进程"，也挡不住运行期
/// 内存抓取。本项目 `SECURITY.md` 的既有口径就是"真正的边界是同一用户账户"。
///
/// 实现说明：不引入 `package:ffi`，直接用 `dart:ffi` + kernel32 的
/// `LocalAlloc`/`LocalFree`（与 DPAPI 的输出分配方式一致，少一个依赖）。
class DpapiException implements Exception {
  DpapiException(this.message);

  final String message;

  @override
  String toString() => 'DpapiException: $message';
}

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptProtectDataNative = Int32 Function(
  Pointer<_DataBlob> pDataIn,
  Pointer<Void> szDataDescr,
  Pointer<_DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<_DataBlob> pDataOut,
);
typedef _CryptProtectDataDart = int Function(
  Pointer<_DataBlob> pDataIn,
  Pointer<Void> szDataDescr,
  Pointer<_DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<_DataBlob> pDataOut,
);

typedef _CryptUnprotectDataNative = Int32 Function(
  Pointer<_DataBlob> pDataIn,
  Pointer<Void> ppszDataDescr,
  Pointer<_DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<_DataBlob> pDataOut,
);
typedef _CryptUnprotectDataDart = int Function(
  Pointer<_DataBlob> pDataIn,
  Pointer<Void> ppszDataDescr,
  Pointer<_DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<_DataBlob> pDataOut,
);

typedef _LocalAllocNative = Pointer<Void> Function(Uint32, IntPtr);
typedef _LocalAllocDart = Pointer<Void> Function(int, int);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

class Dpapi {
  Dpapi._();

  /// DPAPI 只在 Windows 上有。别的平台**明确不支持**：调用方必须 fail closed，
  /// 不允许"退回明文/弱存储"。
  static bool get isSupported => Platform.isWindows;

  /// 不弹任何 UI（核心是无窗口进程，弹窗会挂死）。
  static const int _cryptProtectUiForbidden = 0x1;

  /// `LPTR` = `LMEM_FIXED | LMEM_ZEROINIT`。
  static const int _lptr = 0x0040;

  static _CryptProtectDataDart? _protect;
  static _CryptUnprotectDataDart? _unprotect;
  static _LocalAllocDart? _localAlloc;
  static _LocalFreeDart? _localFree;
  static _GetLastErrorDart? _getLastError;

  static void _ensureLoaded() {
    if (!isSupported) {
      throw DpapiException('DPAPI 只在 Windows 可用');
    }
    if (_protect != null) return;
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _protect = crypt32.lookupFunction<_CryptProtectDataNative,
        _CryptProtectDataDart>('CryptProtectData');
    _unprotect = crypt32.lookupFunction<_CryptUnprotectDataNative,
        _CryptUnprotectDataDart>('CryptUnprotectData');
    _localAlloc =
        kernel32.lookupFunction<_LocalAllocNative, _LocalAllocDart>('LocalAlloc');
    _localFree =
        kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
    _getLastError =
        kernel32.lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
            'GetLastError');
  }

  /// 用当前用户的凭据加密 [plaintext]。
  ///
  /// [entropy] 是应用自选的"额外盐"：不同 entropy 之间互相解不开。
  static Uint8List protect(Uint8List plaintext, {Uint8List? entropy}) {
    _ensureLoaded();
    if (plaintext.isEmpty) {
      throw DpapiException('不接受空输入');
    }
    return _call(encrypt: true, input: plaintext, entropy: entropy);
  }

  /// 解密 [blob]；用户不对 / 机器不对 / entropy 不对 / 被篡改都会失败。
  static Uint8List unprotect(Uint8List blob, {Uint8List? entropy}) {
    _ensureLoaded();
    if (blob.isEmpty) {
      throw DpapiException('不接受空输入');
    }
    return _call(encrypt: false, input: blob, entropy: entropy);
  }

  // ─── 内部 ──────────────────────────────────────────────

  static Uint8List _call({
    required bool encrypt,
    required Uint8List input,
    required Uint8List? entropy,
  }) {
    final localAlloc = _localAlloc!;
    final localFree = _localFree!;
    final allocated = <Pointer<Void>>[];

    Pointer<Uint8> alloc(int bytes) {
      final p = localAlloc(_lptr, bytes);
      if (p == nullptr) {
        throw DpapiException('LocalAlloc 失败（$bytes 字节）');
      }
      allocated.add(p);
      return p.cast<Uint8>();
    }

    try {
      final inputBytes = alloc(input.length);
      inputBytes.asTypedList(input.length).setAll(0, input);

      final inBlob = alloc(sizeOf<_DataBlob>()).cast<_DataBlob>();
      inBlob.ref.cbData = input.length;
      inBlob.ref.pbData = inputBytes;

      Pointer<_DataBlob> entropyBlob = nullptr;
      if (entropy != null && entropy.isNotEmpty) {
        final entropyBytes = alloc(entropy.length);
        entropyBytes.asTypedList(entropy.length).setAll(0, entropy);
        entropyBlob = alloc(sizeOf<_DataBlob>()).cast<_DataBlob>();
        entropyBlob.ref.cbData = entropy.length;
        entropyBlob.ref.pbData = entropyBytes;
      }

      final outBlob = alloc(sizeOf<_DataBlob>()).cast<_DataBlob>();
      outBlob.ref.cbData = 0;
      outBlob.ref.pbData = nullptr;

      final int ok;
      if (encrypt) {
        ok = _protect!(
          inBlob,
          nullptr,
          entropyBlob,
          nullptr,
          nullptr,
          _cryptProtectUiForbidden,
          outBlob,
        );
      } else {
        ok = _unprotect!(
          inBlob,
          nullptr,
          entropyBlob,
          nullptr,
          nullptr,
          _cryptProtectUiForbidden,
          outBlob,
        );
      }

      if (ok == 0) {
        throw DpapiException(
          'DPAPI ${encrypt ? 'protect' : 'unprotect'} 失败'
          '（GetLastError=${_getLastError!()}）',
        );
      }

      try {
        final length = outBlob.ref.cbData;
        final data = outBlob.ref.pbData;
        if (length <= 0 || data == nullptr) {
          throw DpapiException('DPAPI 返回空结果');
        }
        return Uint8List.fromList(data.asTypedList(length));
      } finally {
        // DPAPI 的输出用 LocalFree 释放（与输入不同，不能混用）。
        final data = outBlob.ref.pbData;
        if (data != nullptr) {
          localFree(data.cast<Void>());
          outBlob.ref.pbData = nullptr;
        }
      }
    } finally {
      for (final p in allocated) {
        localFree(p);
      }
    }
  }
}
