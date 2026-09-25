import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/constants/app_constants.dart';
import '../../l10n/app_localizations.dart';
import 'browser_host_installer.dart';

/// **首次启动提示**（方案 B：不做设置页 UI）。
///
/// Linux 上没有安装器，浏览器要能拉起 EasyPass 需要先登记一次 native
/// messaging host。这里只**提示**用户跑一条命令，不在 UI 里替他写盘。
/// 提示只出现一次（标记写进安全存储），且已在任何浏览器里登记过就不再提示。

/// 提示出现的条件（纯函数，便于单测）。
bool shouldShowBrowserHostPrompt({
  required bool isLinux,
  required bool alreadyRegistered,
  required bool alreadyPrompted,
}) =>
    isLinux && !alreadyRegistered && !alreadyPrompted;

/// 给用户复制的那条命令：AppImage 优先用 `$APPIMAGE`（持久路径），
/// 否则用当前可执行文件路径。
String browserHostInstallCommand({
  String? appImagePath,
  required String executablePath,
}) {
  final target =
      (appImagePath != null && appImagePath.isNotEmpty) ? appImagePath : executablePath;
  return '$target --install-browser-host';
}

/// 挂在 `MaterialApp.router` 的 `builder` 上：首帧之后检查一次并弹提示。
class BrowserHostPromptHost extends ConsumerStatefulWidget {
  final Widget child;

  /// 测试注入点：跳过真实探测（`null` = 走真实逻辑）。
  final bool? forceShouldShow;

  /// 测试注入点：命令内容。
  final String? commandOverride;

  /// 测试注入点：是否写入"已提示"标记（默认写）。
  final bool persistFlag;

  const BrowserHostPromptHost({
    super.key,
    required this.child,
    this.forceShouldShow,
    this.commandOverride,
    this.persistFlag = true,
  });

  @override
  ConsumerState<BrowserHostPromptHost> createState() =>
      _BrowserHostPromptHostState();
}

class _BrowserHostPromptHostState extends ConsumerState<BrowserHostPromptHost> {
  static const _storage = FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  Future<void> _maybeShow() async {
    try {
      if (!mounted) return;
      final show = widget.forceShouldShow ?? await _shouldShow();
      if (!show || !mounted) return;

      final command = widget.commandOverride ??
          browserHostInstallCommand(
            appImagePath: Platform.environment['APPIMAGE'],
            executablePath: Platform.resolvedExecutable,
          );
      final l10n = AppLocalizations.of(context);
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.browserBridgePromptTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.browserBridgePromptBody),
              const SizedBox(height: 12),
              SelectableText(
                command,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: command));
                if (!ctx.mounted) return;
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(l10n.browserBridgePromptCopied)),
                );
              },
              child: Text(l10n.browserBridgePromptCopy),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10n.browserBridgePromptOk),
            ),
          ],
        ),
      );
      if (widget.persistFlag) {
        await _storage.write(
          key: AppConstants.browserHostPromptKey,
          value: 'true',
        );
      }
    } catch (_) {
      // 提示失败绝不能影响启动。
    }
  }

  Future<bool> _shouldShow() async {
    if (!Platform.isLinux) return false;
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return false;
    final prompted =
        await _storage.read(key: AppConstants.browserHostPromptKey) == 'true';
    final status = await BrowserHostInstaller().status(homeDir: home);
    final registered = status.checked &&
        (status.isFullyInstalled ||
            status.isPartiallyInstalled ||
            status.resolutionChainBroken);
    return shouldShowBrowserHostPrompt(
      isLinux: true,
      alreadyRegistered: registered,
      alreadyPrompted: prompted,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
