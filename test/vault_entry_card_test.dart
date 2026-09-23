import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/features/vault/widgets/entry_card.dart';
import 'package:easypass/features/vault/widgets/entry_type_bits.dart';
import 'package:easypass/l10n/app_localizations.dart';

/// `EntryCard` 的类型化渲染（2.3.0 契约 §4"列表"）：
/// - 每类一个图标 + 强调色（映射统一来自 `EntryTypeBits`，不在这里另写一套）；
/// - 类型徽章显示该类型的本地化名字；
/// - 副标题统一用 `item.subtitle`；
/// - 收藏星标保留；
/// - **"复制密码"按钮只在登录条目出现**（`item.isAutofillable`），
///   其它类型即使调用方传了回调也不渲染。
void main() {
  VaultItem itemOf(EntryType type, {bool favorite = false, String name = '条目'}) {
    switch (type) {
      case EntryType.login:
        return VaultItem(
          id: 'login-1',
          type: type,
          name: name,
          isFavorite: favorite,
          login: const LoginData(
            url: 'https://github.com',
            username: 'alice',
            password: 'pw',
          ),
          createdAt: 0,
          updatedAt: 0,
        );
      case EntryType.secureNote:
        return VaultItem(
          id: 'note-1',
          type: type,
          name: name,
          isFavorite: favorite,
          notes: '家里路由器的密码',
          createdAt: 0,
          updatedAt: 0,
        );
      case EntryType.identity:
        return VaultItem(
          id: 'id-1',
          type: type,
          name: name,
          isFavorite: favorite,
          identity: const IdentityData(firstName: 'San', lastName: 'Zhang'),
          createdAt: 0,
          updatedAt: 0,
        );
      case EntryType.sshKey:
        return VaultItem(
          id: 'ssh-1',
          type: type,
          name: name,
          isFavorite: favorite,
          sshKey: const SshKeyData(
            publicKey: 'ssh-ed25519 AAAA',
            fingerprint: 'SHA256:abcdef',
          ),
          createdAt: 0,
          updatedAt: 0,
        );
    }
  }

  Future<AppLocalizations> pumpCard(
    WidgetTester tester,
    VaultItem item, {
    VoidCallback? onTap,
    VoidCallback? onCopyPassword,
    double? width,
  }) async {
    Widget card = EntryCard(
      item: item,
      onTap: onTap ?? () {},
      onCopyPassword: onCopyPassword,
    );
    if (width != null) {
      card = SizedBox(width: width, child: card);
    }
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: card)),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(EntryCard)));
  }

  testWidgets('登录卡片：地球图标 + Login 徽章 + 用户名副标题 + 复制密码 + 收藏星标',
      (tester) async {
    var copies = 0;
    final item = itemOf(EntryType.login, favorite: true, name: 'GitHub');
    final l10n = await pumpCard(tester, item, onCopyPassword: () => copies++);

    // 图标画两处：leading 的圆头像 + 徽章里的小图标。
    expect(find.byIcon(EntryTypeBits.icon(EntryType.login)), findsNWidgets(2));
    expect(find.text(l10n.entryTypeLogin), findsOneWidget, reason: '类型徽章');
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget, reason: '副标题 = item.subtitle（用户名）');
    expect(find.byIcon(Icons.star), findsOneWidget, reason: '收藏星标保留');

    expect(find.byTooltip(l10n.copyPasswordTooltip), findsOneWidget);
    await tester.tap(find.byTooltip(l10n.copyPasswordTooltip));
    await tester.pumpAndSettle();
    expect(copies, 1, reason: '登录条目点复制会回调出去（真正的解密/剪贴板在调用方）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('非登录类型：各自的图标 / 徽章 / 副标题，且没有复制密码按钮', (tester) async {
    var copies = 0;

    for (final type in const [
      EntryType.secureNote,
      EntryType.identity,
      EntryType.sshKey,
    ]) {
      final item = itemOf(type, name: 'X');
      final l10n = await pumpCard(tester, item, onCopyPassword: () => copies++);

      expect(find.byIcon(EntryTypeBits.icon(type)), findsNWidgets(2),
          reason: '${type.wireName}: leading 头像 + 徽章图标');
      expect(find.text(EntryTypeBits.label(l10n, type)), findsOneWidget,
          reason: '${type.wireName} 的徽章文案必须本地化');
      expect(find.text(item.subtitle), findsOneWidget,
          reason: '${type.wireName} 的副标题来自 item.subtitle');
      expect(find.byTooltip(l10n.copyPasswordTooltip), findsNothing,
          reason: '${type.wireName} 没有密码可复制（只有登录条目 isAutofillable）');
    }

    expect(copies, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('副标题按类型取字段：笔记给正文、SSH 给指纹、身份给全名', (tester) async {
    await pumpCard(tester, itemOf(EntryType.secureNote));
    expect(find.text('家里路由器的密码'), findsOneWidget);

    await pumpCard(tester, itemOf(EntryType.sshKey));
    expect(find.text('SHA256:abcdef'), findsOneWidget);

    await pumpCard(tester, itemOf(EntryType.identity));
    expect(find.text('San Zhang'), findsOneWidget);
  });

  testWidgets('超长名字 / 副标题不溢出：最小窗口下卡片只有 619px 也安全', (tester) async {
    final item = VaultItem(
      id: 'long',
      type: EntryType.login,
      name: '这是一个特别特别长的登录条目名称' * 8,
      isFavorite: true,
      login: LoginData(
        url: 'https://example.com/${'path/' * 30}',
        username: 'very-long-username@example.com',
        password: 'pw',
      ),
      createdAt: 0,
      updatedAt: 0,
    );

    // 619 = 900（原生最小窗口）− 248（侧边栏）− 1（分隔线）− 32（卡片左右外边距），
    // 也就是这个 app 里卡片能拿到的最小宽度；名字必须走 ellipsis 而不是把
    // Row 顶爆（§10.6 的黄黑条纹就是这么来的）。
    await pumpCard(tester, item, width: 619, onCopyPassword: () {});

    expect(find.byType(EntryCard), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'Row 里的 Text 必须 Expanded/Flexible，否则窄卡片会溢出（§10.6）');
  });

  testWidgets('点整张卡片触发 onTap', (tester) async {
    var taps = 0;
    await pumpCard(tester, itemOf(EntryType.secureNote), onTap: () => taps++);

    await tester.tap(find.byType(EntryCard));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });
}
