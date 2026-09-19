import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/data/database/database.dart';
import 'package:easypass/features/browser_bridge/url_matcher.dart';

/// [UrlMatcher] 单测：契约 2.4 的 hostOf 规范化规则、三条匹配规则、
/// 排序优先级，以及空/不可解析 URL 的处理。
void main() {
  /// 造一个只关心 url/name 的条目（其余字段与匹配无关）。
  PasswordEntry entry(String id, String name, String url) => PasswordEntry(
        id: id,
        name: name,
        url: url,
        username: 'alice',
        passwordEncrypted: 'enc',
        isFavorite: false,
        createdAt: 0,
        updatedAt: 0,
      );

  group('hostOf - 规范化', () {
    test('解析出 host（去路径）', () {
      expect(UrlMatcher.hostOf('https://github.com/login'), 'github.com');
    });

    test('小写化', () {
      expect(UrlMatcher.hostOf('HTTPS://GitHub.COM/Login'), 'github.com');
    });

    test('去掉端口', () {
      expect(UrlMatcher.hostOf('https://example.com:8443/login'), 'example.com');
    });

    test('去掉 userinfo', () {
      expect(
        UrlMatcher.hostOf('https://alice:pw@example.com/private'),
        'example.com',
      );
    });

    test('去掉开头的 www.', () {
      expect(UrlMatcher.hostOf('https://www.example.com/login'), 'example.com');
      expect(UrlMatcher.hostOf('www.example.com'), 'example.com');
    });

    test('无 scheme 的输入按 https:// 补全', () {
      expect(UrlMatcher.hostOf('example.com/login'), 'example.com');
      expect(UrlMatcher.hostOf('login.example.com'), 'login.example.com');
    });

    test('多级子域与 IP/端口', () {
      expect(
        UrlMatcher.hostOf('https://sub.login.example.co.uk/a/b?c=d#e'),
        'sub.login.example.co.uk',
      );
      expect(UrlMatcher.hostOf('http://localhost:3000/login'), 'localhost');
      expect(UrlMatcher.hostOf('localhost:8080'), 'localhost');
      expect(UrlMatcher.hostOf('http://127.0.0.1:8080/x'), '127.0.0.1');
    });

    test('非 http scheme 也能解析 host', () {
      expect(UrlMatcher.hostOf('ftp://example.com/pub'), 'example.com');
      expect(
        UrlMatcher.hostOf('chrome-extension://abcdefghijklmnop/popup.html'),
        'abcdefghijklmnop',
      );
    });

    test('中文域名还原为原文（Dart 会做百分号编码）', () {
      expect(UrlMatcher.hostOf('https://例子.中国/login'), '例子.中国');
    });

    test('空 / 不可解析返回 null', () {
      expect(UrlMatcher.hostOf(''), isNull);
      expect(UrlMatcher.hostOf('   '), isNull);
      expect(UrlMatcher.hostOf('https://'), isNull);
      expect(UrlMatcher.hostOf('not a url'), isNull);
      expect(UrlMatcher.hostOf('about:blank'), isNull);
      expect(UrlMatcher.hostOf('www.'), isNull);
    });
  });

  group('match - 三条命中规则', () {
    test('规则 1：host 完全相等', () {
      final entries = [
        entry('1', 'GitHub', 'https://github.com/login'),
        entry('2', 'Other', 'https://gitlab.com/login'),
      ];
      final matched = UrlMatcher.match(entries, 'https://github.com/session');
      expect(matched.map((e) => e.id), ['1']);
    });

    test('规则 1：端口 / www. / scheme 差异不影响相等判定', () {
      final entries = [
        entry('1', 'Port', 'https://example.com:8443/a'),
        entry('2', 'Www', 'https://www.example.com'),
        entry('3', 'Scheme', 'http://example.com/b'),
      ];
      final matched = UrlMatcher.match(entries, 'https://example.com/login');
      // 三条都是规则 1，同级按 name 升序：Port < Scheme < Www
      expect(matched.map((e) => e.id), ['1', '3', '2']);
    });

    test('规则 2：页面 host 是条目 host 的子域', () {
      final entries = [entry('1', 'Example', 'https://example.com')];
      final matched =
          UrlMatcher.match(entries, 'https://login.example.com/signin');
      expect(matched.map((e) => e.id), ['1']);
    });

    test('规则 3：条目 host 是页面 host 的子域', () {
      final entries = [entry('1', 'Login', 'https://login.example.com')];
      final matched = UrlMatcher.match(entries, 'https://example.com/');
      expect(matched.map((e) => e.id), ['1']);
    });

    test('不同域名不匹配', () {
      final entries = [entry('1', 'GitHub', 'https://github.com')];
      expect(UrlMatcher.match(entries, 'https://gitlab.com'), isEmpty);
    });

    test('子域必须命中 . 边界（notexample.com 不等于 example.com 的子域）', () {
      final entries = [entry('1', 'Example', 'https://example.com')];
      expect(UrlMatcher.match(entries, 'https://notexample.com'), isEmpty);

      final suffix = [entry('2', 'NotExample', 'https://notexample.com')];
      expect(UrlMatcher.match(suffix, 'https://example.com'), isEmpty);
    });
  });

  group('match - 排序', () {
    test('规则 1 全部在前，其次规则 2，再次规则 3', () {
      // 页面 a.example.com 下：
      //   rank0 = 完全相等 a.example.com
      //   rank1 = 页面是条目的子域（条目 example.com）
      //   rank2 = 条目是页面的子域（条目 login.a.example.com）
      final entries = [
        entry('rule3', 'Zulu Child', 'https://login.a.example.com'), // rank 2
        entry('rule1-b', 'Beta', 'https://a.example.com'), // rank 0
        entry('rule1-a', 'Alpha', 'https://a.example.com'), // rank 0
        entry('rule2', 'Zulu Parent', 'https://example.com'), // rank 1
      ];

      final matched = UrlMatcher.match(entries, 'https://a.example.com/x');

      expect(matched.map((e) => e.id).toList(), [
        'rule1-a', // 规则 1，name 升序
        'rule1-b',
        'rule2', // 规则 2
        'rule3', // 规则 3
      ]);
    });

    test('同级按 name 升序（大小写不敏感，且有确定性兜底）', () {
      final entries = [
        entry('3', 'banana', 'https://a.example.com'),
        entry('1', 'Apple', 'https://b.example.com'),
        entry('2', 'apple', 'https://c.example.com'),
      ];
      final matched = UrlMatcher.match(entries, 'https://example.com');
      expect(matched.map((e) => e.name).toList(), ['Apple', 'apple', 'banana']);
      // 同名（仅大小写不同）时用 id 兜底，与输入顺序无关。
      expect(matched.map((e) => e.id).toList(), ['1', '2', '3']);
    });

    test('输入顺序不影响结果', () {
      final a = [
        entry('1', 'A', 'https://example.com'),
        entry('2', 'B', 'https://login.example.com'),
      ];
      final b = a.reversed.toList();
      expect(
        UrlMatcher.match(a, 'https://example.com').map((e) => e.id),
        UrlMatcher.match(b, 'https://example.com').map((e) => e.id),
      );
    });
  });

  group('match - 边界情况', () {
    test('entry.url 为空或不可解析 → 不参与匹配', () {
      final entries = [
        entry('empty', 'Empty', ''),
        entry('blank', 'Blank', '   '),
        entry('bad', 'Bad', 'about:blank'),
        entry('ok', 'Ok', 'https://example.com'),
      ];
      final matched = UrlMatcher.match(entries, 'https://example.com');
      expect(matched.map((e) => e.id), ['ok']);
    });

    test('pageUrl 为空 / 不可解析 → 空结果', () {
      final entries = [entry('1', 'Example', 'https://example.com')];
      expect(UrlMatcher.match(entries, ''), isEmpty);
      expect(UrlMatcher.match(entries, 'about:blank'), isEmpty);
    });

    test('空条目列表 → 空结果', () {
      expect(UrlMatcher.match(const [], 'https://example.com'), isEmpty);
    });

    test('无 scheme 的 entry.url 与 pageUrl 都能匹配', () {
      final entries = [entry('1', 'Example', 'example.com/login')];
      final matched = UrlMatcher.match(entries, 'www.example.com/signin');
      expect(matched.map((e) => e.id), ['1']);
    });
  });
}
