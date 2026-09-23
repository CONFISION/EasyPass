import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/ssh_key_service.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/features/vault/screens/add_edit_entry_screen.dart';

import 'add_edit_entry_harness.dart';

/// 四种条目类型的字段分区、校验与持久化（契约 `docs/entry-types.md` §2/§4）。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late EntryFormHarness harness;

  setUp(() => harness = EntryFormHarness());
  tearDown(() => harness.dispose());

  String readField(WidgetTester tester, Key key) {
    final field = tester.widget<TextFormField>(find.byKey(key));
    return field.controller?.text ?? '';
  }

  // ─── 安全笔记 ─────────────────────────────────────────

  testWidgets('保存安全笔记：type=secureNote、正文进 notes、密码列是空串',
      (tester) async {
    await harness.pumpAdd(tester);
    await tester.enterText(find.byKey(EntryFormKeys.name), '家里 Wi-Fi');
    await harness.selectType(tester, EntryType.secureNote);
    await tester.enterText(
      find.byKey(EntryFormKeys.notes),
      'ssid: home\npassword: correct horse',
    );
    await harness.tapSave(tester);

    expect(find.text(enL10n.entrySaved), findsWidgets);
    await harness.flushSnackBar(tester);

    final items = await harness.repo.getItems(type: EntryType.secureNote);
    expect(items, hasLength(1));
    expect(items.single.type, EntryType.secureNote);
    expect(items.single.name, '家里 Wi-Fi');
    expect(items.single.notes, 'ssid: home\npassword: correct horse');

    final row = await harness.db.getEntryById(items.single.id);
    expect(row, isNotNull);
    expect(row!.type, 'secure_note');
    // 非登录类型：登录列一律空串，绝不留 null 或明文。
    expect(row.passwordEncrypted, '');
    expect(row.url, '');
    expect(row.username, '');
    expect(row.totpSecretEncrypted, '');
    expect(row.notesEncrypted, isNotEmpty);
    expect(row.notesEncrypted, isNot(contains('correct horse')));
  });

  // ─── 身份信息 ─────────────────────────────────────────

  testWidgets('保存身份信息：字段块进 data_encrypted，密码列为空串', (tester) async {
    await harness.pumpAdd(tester);
    await harness.selectType(tester, EntryType.identity);
    await tester.enterText(find.byKey(EntryFormKeys.name), '本人证件');
    await tester.enterText(
        find.byKey(EntryFormKeys.identity('first_name')), '三');
    await tester.enterText(
        find.byKey(EntryFormKeys.identity('last_name')), '张');
    await tester.enterText(
        find.byKey(EntryFormKeys.identity('id_number')), '110101199001011234');
    await tester.enterText(
        find.byKey(EntryFormKeys.identity('email')), 'san@example.com');
    await tester.enterText(
        find.byKey(EntryFormKeys.identity('city')), '北京');
    await tester.enterText(find.byKey(EntryFormKeys.notes), '证件照片在保险箱');
    await harness.tapSave(tester);

    expect(find.text(enL10n.entrySaved), findsWidgets);
    await harness.flushSnackBar(tester);

    final items = await harness.repo.getItems(type: EntryType.identity);
    expect(items, hasLength(1));
    final identity = items.single.identityOrEmpty;
    expect(identity.firstName, '三');
    expect(identity.lastName, '张');
    expect(identity.idNumber, '110101199001011234');
    expect(identity.email, 'san@example.com');
    expect(identity.city, '北京');
    expect(items.single.notes, '证件照片在保险箱');
    // 身份条目不该带上别的类型的块。
    expect(items.single.login, isNull);
    expect(items.single.sshKey, isNull);

    final row = await harness.db.getEntryById(items.single.id);
    expect(row!.type, 'identity');
    expect(row.passwordEncrypted, '');
    expect(row.url, '');
    expect(row.username, '');
    expect(row.dataEncrypted, isNotEmpty);
    // 证件号是密文，不是明文。
    expect(row.dataEncrypted, isNot(contains('110101199001011234')));
  });

  // ─── SSH 密钥 ─────────────────────────────────────────

  testWidgets('保存 SSH 密钥：指纹/类型/位数/注释由公钥自动推导', (tester) async {
    final publicKey = fakeEd25519PublicKey();
    final expectedFingerprint = SshKeyService.fingerprintOf(publicKey);
    expect(expectedFingerprint, startsWith('SHA256:'));

    await harness.pumpAdd(tester);
    await harness.selectType(tester, EntryType.sshKey);
    await tester.enterText(find.byKey(EntryFormKeys.name), 'laptop key');
    await tester.enterText(
        find.byKey(EntryFormKeys.ssh('public_key')), publicKey);
    await tester.pump();

    // 输入公钥的当下就推导出来了（不用等保存）。
    expect(
        readField(tester, EntryFormKeys.ssh('fingerprint')),
        expectedFingerprint);
    expect(readField(tester, EntryFormKeys.ssh('key_type')), 'ssh-ed25519');
    expect(readField(tester, EntryFormKeys.ssh('bits')), '256');
    expect(readField(tester, EntryFormKeys.ssh('comment')), 'alice@laptop');

    await tester.enterText(
      find.byKey(EntryFormKeys.ssh('private_key')),
      '-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-real-key\n'
          '-----END OPENSSH PRIVATE KEY-----',
    );
    await tester.enterText(
        find.byKey(EntryFormKeys.ssh('passphrase')), 'p@ss word ');
    await harness.tapSave(tester);

    expect(find.text(enL10n.entrySaved), findsWidgets);
    await harness.flushSnackBar(tester);

    final items = await harness.repo.getItems(type: EntryType.sshKey);
    expect(items, hasLength(1));
    final ssh = items.single.sshKeyOrEmpty;
    expect(ssh.publicKey, publicKey);
    expect(ssh.fingerprint, expectedFingerprint);
    expect(ssh.keyType, 'ssh-ed25519');
    expect(ssh.bits, 256);
    expect(ssh.comment, 'alice@laptop');
    expect(ssh.privateKey, contains('BEGIN OPENSSH PRIVATE KEY'));
    // 口令不做 trim：前后空格也是口令的一部分。
    expect(ssh.passphrase, 'p@ss word ');

    final row = await harness.db.getEntryById(items.single.id);
    expect(row!.type, 'ssh_key');
    expect(row.passwordEncrypted, '');
    expect(row.url, '');
    // 私钥与口令只以密文形态落库。
    expect(row.dataEncrypted, isNotEmpty);
    expect(row.dataEncrypted, isNot(contains('not-a-real-key')));
    expect(row.dataEncrypted, isNot(contains('p@ss word')));
  });

  testWidgets('手改过的推导字段不会被公钥覆盖', (tester) async {
    await harness.pumpAdd(tester);
    await harness.selectType(tester, EntryType.sshKey);
    await tester.enterText(
        find.byKey(EntryFormKeys.ssh('fingerprint')), 'MD5:aa:bb:cc');
    await tester.enterText(
        find.byKey(EntryFormKeys.ssh('comment')), '手动注释');

    await tester.enterText(
        find.byKey(EntryFormKeys.ssh('public_key')), fakeEd25519PublicKey());
    await tester.pump();

    expect(readField(tester, EntryFormKeys.ssh('fingerprint')), 'MD5:aa:bb:cc');
    expect(readField(tester, EntryFormKeys.ssh('comment')), '手动注释');
    // 没被手改过的字段照常推导。
    expect(readField(tester, EntryFormKeys.ssh('key_type')), 'ssh-ed25519');
    expect(readField(tester, EntryFormKeys.ssh('bits')), '256');
  });

  testWidgets('SSH 公钥与私钥都为空：内联报错 + 不落库', (tester) async {
    await harness.pumpAdd(tester);
    await harness.selectType(tester, EntryType.sshKey);
    await tester.enterText(find.byKey(EntryFormKeys.name), 'empty ssh');
    await harness.tapSave(tester);

    // 空密钥用的是"至少填一个"的专用文案（sshKeyRequired），
    // 与"公钥解析失败"（sshPublicKeyInvalid）区分开。
    expect(find.text(enL10n.sshKeyRequired), findsWidgets);
    expect(await harness.repo.countItems(), 0);
    await harness.flushSnackBar(tester);
  });

  testWidgets('公钥是垃圾文本：只警告，不阻止保存', (tester) async {
    await harness.pumpAdd(tester);
    await harness.selectType(tester, EntryType.sshKey);
    await tester.enterText(find.byKey(EntryFormKeys.name), 'broken public key');
    await tester.enterText(
        find.byKey(EntryFormKeys.ssh('public_key')), 'not-a-key!!!');
    await tester.pump();
    expect(find.text(enL10n.sshPublicKeyInvalid), findsOneWidget);

    await tester.enterText(
        find.byKey(EntryFormKeys.ssh('private_key')), 'PRIVATE-KEY-BODY');
    await harness.tapSave(tester);
    expect(find.text(enL10n.entrySaved), findsWidgets);
    await harness.flushSnackBar(tester);

    final items = await harness.repo.getItems(type: EntryType.sshKey);
    expect(items, hasLength(1));
    expect(items.single.sshKeyOrEmpty.publicKey, 'not-a-key!!!');
    expect(items.single.sshKeyOrEmpty.privateKey, 'PRIVATE-KEY-BODY');
  });

  testWidgets('只有私钥也能保存', (tester) async {
    await harness.pumpAdd(tester);
    await harness.selectType(tester, EntryType.sshKey);
    await tester.enterText(find.byKey(EntryFormKeys.name), 'private only');
    await tester.enterText(
        find.byKey(EntryFormKeys.ssh('private_key')), 'PRIVATE-KEY-BODY');
    await harness.tapSave(tester);
    await harness.flushSnackBar(tester);

    final items = await harness.repo.getItems(type: EntryType.sshKey);
    expect(items, hasLength(1));
    expect(items.single.sshKeyOrEmpty.hasPrivateKey, isTrue);
  });

  // ─── 类型切换（编辑既有条目）────────────────────────────

  testWidgets('编辑时切换类型：先确认，确认后丢掉旧类型的字段块', (tester) async {
    await harness.repo.saveItem(harness.loginItem(notes: 'keep me'));
    await harness.pumpEdit(tester, 'seed-login');
    expect(readField(tester, EntryFormKeys.url), 'https://github.com');

    await harness.selectType(tester, EntryType.secureNote);
    expect(find.text(enL10n.entryTypeSwitchTitle), findsOneWidget);
    expect(
      find.text(enL10n.entryTypeSwitchMessage(enL10n.entryTypeLogin)),
      findsOneWidget,
    );
    // 还没确认：表单原样不动。
    expect(readField(tester, EntryFormKeys.url), 'https://github.com');

    await tester.tap(find.text(enL10n.entryTypeSwitchConfirm));
    await tester.pumpAndSettle();

    // 旧类型的字段整块消失。
    expect(find.byKey(EntryFormKeys.url), findsNothing);
    expect(find.byKey(EntryFormKeys.password), findsNothing);
    // 名称 / 备注这类共用字段保留。
    expect(readField(tester, EntryFormKeys.name), 'GitHub');
    expect(readField(tester, EntryFormKeys.notes), 'keep me');

    await tester.enterText(
        find.byKey(EntryFormKeys.notes), 'body after switch');
    await harness.tapSave(tester);
    expect(find.text(enL10n.entryUpdated), findsWidgets);
    await harness.flushSnackBar(tester);

    expect(await harness.repo.getItems(type: EntryType.login), isEmpty);
    final items = await harness.repo.getItems();
    expect(items, hasLength(1));
    expect(items.single.id, 'seed-login');
    expect(items.single.type, EntryType.secureNote);
    expect(items.single.notes, 'body after switch');

    final row = await harness.db.getEntryById('seed-login');
    expect(row!.type, 'secure_note');
    expect(row.passwordEncrypted, '');
    expect(row.url, '');
    expect(row.username, '');
    expect(row.totpSecretEncrypted, '');
  });

  testWidgets('切换类型时取消：条目类型与字段都不变', (tester) async {
    await harness.repo.saveItem(harness.loginItem());
    await harness.pumpEdit(tester, 'seed-login');

    await harness.selectType(tester, EntryType.identity);
    await tester.tap(find.text(enL10n.cancel));
    await tester.pumpAndSettle();

    expect(find.byKey(EntryFormKeys.url), findsOneWidget);
    expect(readField(tester, EntryFormKeys.password), 'pw-seed');
    expect(find.byKey(EntryFormKeys.identity('first_name')), findsNothing);

    await harness.tapSave(tester);
    await harness.flushSnackBar(tester);

    final items = await harness.repo.getItems();
    expect(items, hasLength(1));
    expect(items.single.type, EntryType.login);
    expect(items.single.loginOrEmpty.password, 'pw-seed');
  });

  testWidgets('切换类型后可以再切回来（新建态不会丢输入）', (tester) async {
    await harness.pumpAdd(tester);
    await tester.enterText(find.byKey(EntryFormKeys.name), 'multi');
    await tester.enterText(find.byKey(EntryFormKeys.url), 'https://a.example');
    await tester.enterText(find.byKey(EntryFormKeys.password), 'pw-1');

    await harness.selectType(tester, EntryType.sshKey);
    expect(readField(tester, EntryFormKeys.name), 'multi');
    await harness.selectType(tester, EntryType.login);

    expect(readField(tester, EntryFormKeys.url), 'https://a.example');
    expect(readField(tester, EntryFormKeys.password), 'pw-1');
  });

  // ─── 自定义字段（所有类型通用）──────────────────────────

  testWidgets('自定义字段随安全笔记一起保存', (tester) async {
    await harness.pumpAdd(tester);
    await harness.selectType(tester, EntryType.secureNote);
    await tester.enterText(find.byKey(EntryFormKeys.name), 'note + field');
    await tester.enterText(find.byKey(EntryFormKeys.notes), 'body');

    await harness.tapVisible(tester, find.text(enL10n.customFieldAdd));
    await tester.pumpAndSettle();

    final labelField =
        find.widgetWithText(TextFormField, enL10n.customFieldLabelHint);
    final valueField =
        find.widgetWithText(TextFormField, enL10n.customFieldValueHint);
    expect(labelField, findsOneWidget);
    expect(valueField, findsOneWidget);
    await tester.enterText(labelField.first, 'PIN');
    await tester.enterText(valueField.first, '1234');

    await harness.tapSave(tester);
    expect(find.text(enL10n.entrySaved), findsWidgets);
    await harness.flushSnackBar(tester);

    final items = await harness.repo.getItems(type: EntryType.secureNote);
    expect(items, hasLength(1));
    expect(items.single.customFields, hasLength(1));
    expect(items.single.customFields.single.label, 'PIN');
    expect(items.single.customFields.single.value, '1234');
  });
}
