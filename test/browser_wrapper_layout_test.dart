import 'package:easypass/features/browser_bridge/browser_host_installer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Linux 原生消息 wrapper 的**路径探测顺序**回归。
///
/// 为什么单独一个跨平台文件：`browser_host_installer_test.dart` 是 Linux-only
/// （在 Windows 上不注册用例），而这段逻辑是纯字符串生成，两边都能测 ——
/// 而它一旦错了，Linux 扩展会 `exit 127` 完全不可用，值得在 Windows 上也守住。
void main() {
  group('wrapper 的核心探测候选', () {
    String body() => BrowserHostInstaller.renderWrapperScript(
          extraCandidates: const ['/opt/EasyPass/easypass'],
        );

    test('三处候选都必须覆盖生产布局的 core/ 子目录（3.0.0 回归）', () {
      // 生产布局（tool/build_core.sh、AppImage 的 usr/bin/core/）把核心放在
      // core/ 下；早期 wrapper 只找同目录的 easypass_core，真实安装上 exit 127。
      final script = body();
      expect(script, contains(r'"${APPDIR}/usr/bin/core/easypass_core"'));
      expect(script, contains(r'"${_d}/core/easypass_core"'));
      expect(script, contains(r'"${HERE}/core/easypass_core"'));
    });

    test('扁平布局仍然兼容（开发态 / 旧安装）', () {
      final script = body();
      expect(script, contains(r'"${APPDIR}/usr/bin/easypass_core"'));
      expect(script, contains(r'"${_d}/easypass_core"'));
      expect(script, contains(r'"${HERE}/easypass_core"'));
    });

    test('core/ 优先于同目录（先生产、后回退）', () {
      final script = body();
      expect(
        script.indexOf('/usr/bin/core/easypass_core'),
        lessThan(script.indexOf('/usr/bin/easypass_core')),
        reason: 'AppImage 的真实布局必须排在扁平布局之前',
      );
      expect(
        script.indexOf(r'${_d}/core/easypass_core'),
        lessThan(script.indexOf(r'${_d}/easypass_core')),
        reason: '烘焙候选取其目录下的 core/ 优先',
      );
    });

    test('不再依赖已退役的 --native-host 形态', () {
      final script = body();
      expect(script, contains('--bridge'));
      expect(script, isNot(contains('--native-host')));
    });
  });
}
