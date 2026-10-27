/// 核心服务功能探针（不依赖 Flutter UI）。
///
/// 用法（在仓库根目录）：
/// ```
/// dart run tool/probe_core.dart --core build\qa\core\easypass_core.exe
/// dart run tool/probe_core.dart --keep     # 跑完不关机（留给 UI 手工接着测）
/// ```
///
/// 用 `--core` 指定核心可执行文件（不给就在"当前 dart 可执行文件旁边"找，
/// 那对 `dart run` 通常找不到 —— 所以显式给路径最省事）。
///
/// 它做的是"UI 会做的那一串事"：握手 → 首设主密码 → 解锁 → 建文件夹 →
/// 存条目 → 列表/搜索/单条 → 计数 → 健康报告 → 删条目 → 回收站（删/列/恢复/
/// 彻底删）→ 清库 →（默认）请求核心退出。
///
/// **安全纪律**：只在**空库**上跑。库里已有主密码时会拒绝执行任何写操作
/// —— 否则这个脚本就成了"一条命令清空用户保险库"。
library;

import 'dart:convert';
import 'dart:io';

import 'package:easypass/core_service/bridge_forwarder.dart';
import 'package:easypass/core_service/core_client.dart';
import 'package:easypass/core_service/core_info.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/protocol/protocol.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool ok, [Object? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  PASS  $name');
  } else {
    _failed++;
    stdout.writeln('  FAIL  $name${detail == null ? '' : ' -> $detail'}');
  }
}

Future<void> main(List<String> args) async {
  final keepRunning = args.contains('--keep');
  final coreIndex = args.indexOf('--core');
  final explicitCore =
      (coreIndex >= 0 && coreIndex + 1 < args.length) ? args[coreIndex + 1] : null;
  stdout.writeln('== EasyPass 核心探针 ==');

  var info = await CoreDiscovery.read();
  if (info == null) {
    stdout.writeln('没有发现运行中的核心，尝试拉起…');
    final path = explicitCore ?? coreExecutablePath();
    if (path == null || !File(path).existsSync()) {
      stderr.writeln('FAIL: 找不到 easypass_core 可执行文件'
          '${explicitCore == null ? '（可用 --core <路径> 指定）' : '：$explicitCore'}');
      exit(1);
    }
    await Process.start(
      path,
      const ['--serve'],
      mode: ProcessStartMode.detached,
      workingDirectory: File(path).parent.path,
    );
    info = await waitForCore();
    if (info == null) {
      stderr.writeln('FAIL: 等待核心就绪超时');
      exit(1);
    }
  }
  stdout.writeln('核心：$info');
  stdout.writeln('核心 exe：${info.exe}');

  final client = await CoreClient.connect(info, role: 'ui');
  try {
    final status = await client.request(Actions.getStatus);
    stdout.writeln('getStatus: ${jsonEncode(status)}');
    _check('协议版本 = $coreProtocolVersion',
        status['protocolVersion'] == coreProtocolVersion, status);
    _check('核心版本非空', (status['coreVersion'] as String?)?.isNotEmpty == true);

    final auth = await client.request(Actions.getAuthState);
    final hasAuth = auth['hasAuthMaterial'] == true;
    if (hasAuth) {
      stdout.writeln();
      stdout.writeln('库中已有主密码 —— 探针拒绝在非空库上执行写操作。');
      stdout.writeln('请在**空库**（例如 build\\qa\\easypass.db）上运行本探针。');
      exit(2);
    }

    stdout.writeln('\n-- 会话 --');
    await client.request(Actions.setMasterPassword,
        {'password': 'probe-master-pw', 'confirmPassword': 'probe-master-pw'});
    final unlocked = await client.request(Actions.getAuthState);
    _check('首设主密码后处于解锁态', unlocked['status'] == 'unlocked', unlocked);

    final verified =
        await client.request(Actions.verifyMasterPassword, {'password': 'wrong'});
    _check('错误主密码校验返回 ok=false', verified['ok'] == false, verified);
    final verifiedOk = await client
        .request(Actions.verifyMasterPassword, {'password': 'probe-master-pw'});
    _check('正确主密码校验返回 ok=true', verifiedOk['ok'] == true, verifiedOk);

    stdout.writeln('\n-- 文件夹 --');
    final folderId = (await client
            .request(Actions.addFolder, {'name': '探针文件夹', 'icon': 'folder'}))['id']
        as String;
    final folders = await client.request(Actions.listFolders);
    _check('文件夹已创建', (folders['folders'] as List).length == 1, folders);

    stdout.writeln('\n-- 条目 --');
    final now = DateTime.now().millisecondsSinceEpoch;
    final item = VaultItem(
      id: 'probe-entry-1',
      folderId: folderId,
      type: EntryType.login,
      name: '探针条目',
      notes: 'note',
      login: const LoginData(
        url: 'https://example.com',
        username: 'probe-user',
        password: 'probe-secret',
        totpSecret: 'JBSWY3DPEHPK3PXP',
      ),
      customFields: const [
        CustomField(label: '自定义', value: '值', type: CustomFieldType.text),
      ],
      createdAt: now,
      updatedAt: now,
    );
    await client.request(Actions.saveItem, {'item': item.toJson()});

    final listed = await client.request(Actions.listItems);
    final listedItems = (listed['items'] as List)
        .map((raw) => VaultItem.fromJson(Map<String, dynamic>.from(raw as Map)))
        .toList();
    _check('列表返回 1 条', listedItems.length == 1, listedItems.length);
    _check('密码解密正确',
        listedItems.single.loginOrEmpty.password == 'probe-secret');
    _check('自定义字段往返正确',
        listedItems.single.customFields.single.value == '值');

    final byId = await client.request(Actions.getItem, {'id': 'probe-entry-1'});
    _check('单条读取', (byId['item'] as Map)['name'] == '探针条目');

    final searched =
        await client.request(Actions.searchItems, {'query': 'probe-user'});
    _check('搜索命中', (searched['items'] as List).length == 1, searched);

    final counted = await client
        .request(Actions.countItemsInFolder, {'folderId': folderId});
    _check('文件夹计数 = 1', counted['count'] == 1, counted);

    final totp = await client
        .request(Actions.getTotp, {'entryId': 'probe-entry-1'});
    _check('TOTP 生成 6 位',
        (totp['code'] as String).length == 6, totp);

    final health = await client.request(Actions.getHealthReport);
    _check('健康报告 totalEntries = 1', health['totalEntries'] == 1, health);

    stdout.writeln('\n-- 锁定 / 解锁 --');
    await client.request(Actions.lock);
    final lockedState = await client.request(Actions.getAuthState);
    _check('锁定后 status=locked', lockedState['status'] == 'locked', lockedState);

    // 契约：锁定后数据动作**显式报错**（errorCode=locked），而不是静默回空列表
    // —— 由客户端决定"显示锁屏"还是"显示空列表"。
    var rejectedAsLocked = false;
    try {
      await client.request(Actions.listItems);
    } on CoreRequestException catch (error) {
      rejectedAsLocked = error.isLocked;
    }
    _check('锁定后读条目被拒（errorCode=locked）', rejectedAsLocked);

    await client.request(Actions.unlock, {'password': 'probe-master-pw'});
    final relisted = await client.request(Actions.listItems);
    _check('重新解锁后 1 条还在', (relisted['items'] as List).length == 1);

    stdout.writeln('\n-- 清理 / 回收站（schema 5）--');
    await client.request(Actions.deleteItem, {'id': 'probe-entry-1'});
    final afterDelete = await client.request(Actions.listItems);
    _check('删除条目（列表不再显示）', (afterDelete['items'] as List).isEmpty,
        afterDelete);

    final trash = await client.request(Actions.listTrash);
    _check('删除进回收站（listTrash = 1）', (trash['items'] as List).length == 1,
        trash);
    await client.request(Actions.restoreItem, {'id': 'probe-entry-1'});
    final restored = await client.request(Actions.listItems);
    _check('从回收站恢复（listItems = 1）',
        (restored['items'] as List).length == 1, restored);

    await client.request(Actions.deleteItem, {'id': 'probe-entry-1'});
    await client.request(Actions.permanentlyDeleteItem, {'id': 'probe-entry-1'});
    final purged = await client.request(Actions.listTrash);
    _check('彻底删除后回收站为空', (purged['items'] as List).isEmpty, purged);

    await client.request(Actions.removeFolder, {'id': folderId});
    final afterFolder = await client.request(Actions.listFolders);
    _check('删除文件夹', (afterFolder['folders'] as List).isEmpty, afterFolder);

    stdout.writeln('\n== 结果：$_passed 通过 / $_failed 失败 ==');
  } finally {
    client.close();
  }

  if (keepRunning) {
    stdout.writeln('保留核心运行（--keep）：$info');
  } else {
    final stopped = await shutdownRunningCore();
    stdout.writeln(stopped ? '核心已退出' : '核心未在超时内退出');
  }
  exit(_failed == 0 ? 0 : 1);
}
