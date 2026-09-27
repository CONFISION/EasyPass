// 非 Linux/Windows 桌面平台的单实例 no-op 桩。

import 'desktop_single_instance.dart';

Future<SingleInstanceDecision> acquireOtherSingleInstance() async {
  return const SingleInstanceDecision(role: SingleInstanceRole.notApplicable);
}