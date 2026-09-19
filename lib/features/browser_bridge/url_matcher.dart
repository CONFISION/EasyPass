import '../../data/database/database.dart';

/// URL ↔ 条目匹配（契约 2.4，纯函数、可单测）。
///
/// 用于扩展的自动填充：给定当前页面 URL，挑出这个站点该用哪些条目。
/// 刻意**不做** TLD/公共后缀推断（没有 PSL 数据），只按域名层级比较，
/// 规则简单、结果可预测：
///
/// 1. host 完全相等（同域）；
/// 2. 页面 host 是条目 host 的子域（页面 `login.example.com` ↔ 条目 `example.com`）；
/// 3. 条目 host 是页面 host 的子域（条目 `login.example.com` ↔ 页面 `example.com`）。
///
/// 排序：规则 1 全部在前，其次规则 2，再次规则 3；同级按 `name` 升序
/// （大小写不敏感，再以原始 name / id 兜底，保证顺序稳定可测）。
class UrlMatcher {
  const UrlMatcher._();

  /// 只认 `scheme://` 形式的 scheme；其它输入一律按无 scheme 处理并补
  /// `https://`（契约要求 `example.com/login` 能解析）。
  static final RegExp _schemePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

  /// 解析 URL 的 host：小写、去端口、去 userinfo、去开头 `www.`。
  ///
  /// - 无 scheme 的输入按 `https://` 补全（`example.com/login` → `example.com`）；
  /// - 无法解析（空串、只有 scheme、含空白等）→ null。
  static String? hostOf(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;

    final candidate = _schemePattern.hasMatch(trimmed)
        ? trimmed
        : 'https://$trimmed';

    final Uri uri;
    try {
      uri = Uri.parse(candidate);
    } on FormatException {
      // 例如 `about:blank` —— 不是可用的 http(s) URL。
      return null;
    }

    // Uri.host 已经做过小写化，并且去掉了 userinfo 与端口。
    var host = uri.host;
    if (host.isEmpty) return null;

    // Dart 会把非 ASCII 的 host 百分号编码（中文域名 → `%E4%BE%8B...`），
    // 解码回原样才能与库里存的中文域名条目比较。
    if (host.contains('%')) {
      try {
        host = Uri.decodeComponent(host);
      } on FormatException {
        // 不是合法百分号编码：保留原样，不视为致命错误。
      }
    }

    // `not a url` 之类含空白的输入会被 Uri.parse 编码成 `not%20a%20url`，
    // 解码后仍是空白 → 判定为无法解析。
    if (host.contains(' ') || host.contains('\t')) return null;

    if (host.startsWith('www.')) {
      host = host.substring(4);
    }
    return host.isEmpty ? null : host;
  }

  /// 从 [entries] 中挑出与 [pageUrl] 匹配的条目，按契约 2.4 排序。
  ///
  /// `entry.url` 为空或不可解析的条目不参与 URL 匹配（但仍会出现在
  /// `getAllCredentials` / `searchCredentials` 的结果里）。
  static List<PasswordEntry> match(
      List<PasswordEntry> entries, String pageUrl) {
    final pageHost = hostOf(pageUrl);
    if (pageHost == null) return const [];

    final ranked = <_RankedEntry>[];
    for (final entry in entries) {
      final entryHost = hostOf(entry.url);
      if (entryHost == null) continue;

      final int rank;
      if (entryHost == pageHost) {
        rank = 0; // 规则 1：完全相等
      } else if (_isSubdomainOf(pageHost, entryHost)) {
        rank = 1; // 规则 2：页面是条目的子域
      } else if (_isSubdomainOf(entryHost, pageHost)) {
        rank = 2; // 规则 3：条目是页面的子域
      } else {
        continue; // 不匹配
      }
      ranked.add(_RankedEntry(rank, entry));
    }

    // List.sort 不保证稳定，所以把 name 不区分大小写、原始 name、id 全部
    // 纳入比较，得到与输入顺序无关的确定性排序。
    ranked.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      if (byRank != 0) return byRank;
      final byName =
          a.entry.name.toLowerCase().compareTo(b.entry.name.toLowerCase());
      if (byName != 0) return byName;
      final byRawName = a.entry.name.compareTo(b.entry.name);
      if (byRawName != 0) return byRawName;
      return a.entry.id.compareTo(b.entry.id);
    });

    return [for (final r in ranked) r.entry];
  }

  /// [child] 是否为 [parent] 的真子域（要求 `.` 边界，避免
  /// `notexample.com` 被误判为 `example.com` 的子域）。
  static bool _isSubdomainOf(String child, String parent) {
    if (child.length <= parent.length) return false;
    if (!child.endsWith(parent)) return false;
    return child[child.length - parent.length - 1] == '.';
  }
}

/// 匹配结果 + 命中规则序号，仅用于排序。
class _RankedEntry {
  final int rank;
  final PasswordEntry entry;

  const _RankedEntry(this.rank, this.entry);
}
