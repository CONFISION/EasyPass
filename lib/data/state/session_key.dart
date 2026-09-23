import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前会话的 AES 派生密钥；锁定 / 未解锁时为 null。
///
/// 为什么放在 `data/state/` 而不是 `features/auth/`：
/// [VaultRepository]（data 层）需要读密钥才能解密条目载荷，而分层约定是
/// **core / data 不得 import features**。所以这里定义、`auth_provider.dart`
/// 再 re-export：老的 `import '.../auth_provider.dart'` 调用点一行都不用改，
/// 写入方仍然是 `AuthNotifier`（解锁时写、锁定时置 null）。
///
/// 安全纪律：只以引用传递，不复制、不打印、不落盘；锁定时由
/// [AuthNotifier] 负责清空（见 `auth_provider.dart` 的 `lock()`）。
final encryptionKeyProvider = StateProvider<Uint8List?>((ref) => null);
