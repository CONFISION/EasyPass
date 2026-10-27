import 'package:easypass/protocol/actions.dart';
import 'package:flutter_test/flutter_test.dart';

/// 角色 → 动作白名单的边界（阶段 0 的回归网）。
///
/// 回归背景：`_dispatch` 曾经写成
/// `final allowed = role == 'ui' ? uiAllowed : bridgeAllowed;`
/// 于是**任何非 ui 角色**（包括文档里"预留"的 `agent`）都继承了 bridge 的
/// 全部权限 —— `unlock` / `getTotp` / `shutdownCore` 都在里面。
/// 也就是说"预留 agent 角色"当时只是个名字，**不是权限边界**。
///
/// 这里钉住三条不变量：
/// 1. 未知角色拿不到任何白名单（`null` ⇒ 调用方必须拒绝连接）；
/// 2. `agentAllowed` 与敏感动作**零交集**；
/// 3. `agentAllowed` 不是 `bridgeAllowed` 的子集 —— 智能体的动作必须**另起名字**
///    （例如 `agentList` 而不是复用 `getAllCredentials`），不能靠"继承 bridge
///    再减去几个"来实现最小权限。
void main() {
  group('allowedFor：单一来源的角色映射', () {
    test('ui / bridge / agent 各自映射到自己的白名单', () {
      expect(Actions.allowedFor('ui'), same(Actions.uiAllowed));
      expect(Actions.allowedFor('bridge'), same(Actions.bridgeAllowed));
      expect(Actions.allowedFor('agent'), same(Actions.agentAllowed));
    });

    test('未知角色返回 null（调用方必须拒绝连接）', () {
      for (final role in <String>['', 'Agent', 'AGENT', 'admin', 'service', 'root', 'ui ']) {
        expect(Actions.allowedFor(role), isNull,
            reason: '角色 "$role" 不该有白名单');
        expect(Actions.isKnownRole(role), isFalse);
      }
    });

    test('isKnownRole 与 allowedFor 一致（三个合法角色）', () {
      for (final role in <String>['ui', 'bridge', 'agent']) {
        expect(Actions.isKnownRole(role), isTrue);
      }
    });
  });

  group('agentAllowed：智能体域的权限边界', () {
    /// 智能体**永远**不能拿到的动作（含会话、凭据、写、导出、停机）。
    const forbidden = <String>[
      Actions.unlock,
      Actions.lock,
      Actions.setMasterPassword,
      Actions.changeMasterPassword,
      Actions.verifyMasterPassword,
      Actions.adoptLegacyKeyMaterial,
      Actions.shutdownCore,
      Actions.getTotp,
      Actions.getCredentials,
      Actions.getAllCredentials,
      Actions.searchCredentials,
      Actions.saveItem,
      Actions.deleteItem,
      Actions.deleteAllData,
      Actions.exportVault,
      Actions.importVault,
    ];

    test('阶段 0：空集合 = 默认全拒', () {
      expect(Actions.agentAllowed, isEmpty,
          reason: '阶段 0 不给 agent 任何核心动作；阶段 1 起再逐个填，'
              '且必须继续满足下面的不变量');
    });

    test('与敏感动作零交集', () {
      for (final action in forbidden) {
        expect(Actions.agentAllowed, isNot(contains(action)),
            reason: '智能体不该拿到 $action');
      }
    });

    test('不是 bridgeAllowed 的子集（智能体动作必须另起名字）', () {
      expect(
        Actions.agentAllowed.difference(Actions.bridgeAllowed),
        Actions.agentAllowed,
        reason: '如果 agent 的动作名出现在 bridge 白名单里，说明在靠"继承 bridge"'
            '实现智能体权限，那会让 unlock/getTotp 之类的能力一起漏过去',
      );
    });
  });

  group('角色不能互相顶替', () {
    test('bridge 拿不到 UI 专属动作', () {
      for (final action in <String>[
        Actions.listItems,
        Actions.getItem,
        Actions.saveItem,
        Actions.deleteItem,
        Actions.deleteAllData,
        Actions.exportVault,
        Actions.importVault,
        Actions.changeMasterPassword,
        Actions.verifyMasterPassword,
        Actions.touchActivity,
      ]) {
        expect(Actions.bridgeAllowed, isNot(contains(action)),
            reason: 'bridge 不该有 $action');
      }
    });

    test('bridge 白名单仍是冻结的 10 个（协议 v3 起的契约）', () {
      expect(
        Actions.bridgeAllowed,
        {
          Actions.getStatus,
          Actions.unlock,
          Actions.lock,
          Actions.getCredentials,
          Actions.getAllCredentials,
          Actions.searchCredentials,
          Actions.generatePassword,
          Actions.getTotp,
          Actions.getHealthReport,
          Actions.shutdownCore,
        },
        reason: '扩展与 C++ 桥依赖这 10 个动作的字段形状；增删都要同步改客户端',
      );
    });

    test('ui 含智能体管理相关动作的落点（阶段 1 会补）', () {
      // 阶段 1 新增的配对管理动作必须加进 uiAllowed，否则 UI 调不到。
      // 这里先钉住"UI 是唯一能改配对/授权的地方"这条边界用到的既有动作。
      expect(Actions.uiAllowed, contains(Actions.verifyMasterPassword));
      expect(Actions.uiAllowed, contains(Actions.getAuthState));
    });
  });
}
