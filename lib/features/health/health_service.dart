/// 密码健康报告 —— 核心分析逻辑（纯 Dart，可单测）。
///
/// 安全纪律：本模块输入的是**解密后**的条目（由 provider 在内存中装配），
/// 输出 [HealthReport] 只保留条目 id/name 与统计数字，**绝不保留明文密码**。
/// 重复密码检测只记录"有多少条目共用"，不输出密码本身。
/// 明文密码仅存在于 [analyze] 的临时局部变量中，函数返回后即不可达。
library;

/// 解密后的条目（供健康分析使用，不持久化、不打印）。
class HealthEntry {
  final String id;
  final String name;
  final String password;
  final String url;

  /// TOTP 密钥明文；为空表示未启用两步验证。
  final String? totpSecret;

  const HealthEntry({
    required this.id,
    required this.name,
    required this.password,
    this.url = '',
    this.totpSecret,
  });
}

/// 弱密码的具体原因（机器可读，UI 层负责本地化展示）。
enum WeakPasswordReason {
  /// 长度不足 12 位
  tooShort,

  /// 仅包含单一字符类型（纯数字 / 纯字母 / 纯小写等）
  singleCharType,

  /// 命中常见弱密码列表
  commonPassword,
}

/// 健康等级：良好 / 一般 / 危险。
enum HealthLevel { good, fair, poor }

class WeakPasswordIssue {
  final String entryId;
  final String entryName;
  final WeakPasswordReason reason;

  const WeakPasswordIssue({
    required this.entryId,
    required this.entryName,
    required this.reason,
  });
}

class ReusedPasswordIssue {
  final String entryId;
  final String entryName;

  /// 与该条目共用同一明文密码的条目总数（含当前条目）。
  final int sharedCount;

  const ReusedPasswordIssue({
    required this.entryId,
    required this.entryName,
    required this.sharedCount,
  });
}

class NoTotpIssue {
  final String entryId;
  final String entryName;

  const NoTotpIssue({required this.entryId, required this.entryName});
}

class NoUrlIssue {
  final String entryId;
  final String entryName;

  const NoUrlIssue({required this.entryId, required this.entryName});
}

/// 密码健康报告。
///
/// 评分算法（0-100，注释说明）：
/// 初始 100 分，按问题类别扣分，各类上限封顶以免大保险库被过度扣分：
/// - 弱密码：每个条目 -10，最多扣 40
/// - 重复密码：每组（同一个明文密码被 ≥2 个条目使用） -15，最多扣 30
/// - 无 TOTP：每个条目 -2，最多扣 20
/// - 无 URL：每个条目 -2，最多扣 20
/// 分数下限为 0。全部健康 = 100。
///
/// 健康等级：score >= 80 → [HealthLevel.good]；score >= 50 →
/// [HealthLevel.fair]；否则 [HealthLevel.poor]。
class HealthReport {
  final int totalEntries;

  final List<WeakPasswordIssue> weakPasswords;
  final List<ReusedPasswordIssue> reusedPasswords;

  /// 被 ≥2 个条目共用的**不同**明文密码组数（去重统计）。
  final int reusedGroupCount;

  final List<NoTotpIssue> noTotpEntries;
  final List<NoUrlIssue> noUrlEntries;

  /// 0-100 的健康总分。
  final int score;

  const HealthReport({
    required this.totalEntries,
    required this.weakPasswords,
    required this.reusedPasswords,
    required this.reusedGroupCount,
    required this.noTotpEntries,
    required this.noUrlEntries,
    required this.score,
  });

  int get weakPasswordCount => weakPasswords.length;

  /// 涉及重复密码的条目总数（即 [reusedPasswords].length）。
  int get reusedEntryCount => reusedPasswords.length;

  int get noTotpCount => noTotpEntries.length;

  int get noUrlCount => noUrlEntries.length;

  bool get isHealthy => score >= 100;

  HealthLevel get level {
    if (score >= 80) return HealthLevel.good;
    if (score >= 50) return HealthLevel.fair;
    return HealthLevel.poor;
  }
}

/// 纯函数分析器：输入解密后的条目列表，输出健康报告。
class HealthService {
  /// 弱密码最小长度。
  static const int weakPasswordMinLength = 12;

  /// 常见弱密码列表（命中即视为弱密码）。
  static const Set<String> commonPasswords = {
    '123456',
    'password',
    '123456789',
    'qwerty',
    '111111',
    'abc123',
    'password123',
    '12345678',
    '1234567',
    'admin',
    'letmein',
    'welcome',
    'monkey',
    '123123',
    'iloveyou',
    'dragon',
    'football',
    'master',
    'sunshine',
    '1234567890',
    'qwerty123',
    'password1',
    '654321',
    '123321',
    '000000',
    '666666',
    '88888888',
    'zxcvbnm',
    'admin123',
    'passw0rd',
    'letmein123',
    'abc123456',
    '1q2w3e4r',
    'qwertyuiop',
  };

  static HealthReport analyze(List<HealthEntry> entries) {
    final weakPasswords = <WeakPasswordIssue>[];
    final noTotpEntries = <NoTotpIssue>[];
    final noUrlEntries = <NoUrlIssue>[];

    // 按明文密码分组的临时统计：明文只存在于这个局部变量中，
    // 分析结束后即被回收，不会进入 HealthReport。
    final passwordGroups = <String, List<HealthEntry>>{};

    for (final entry in entries) {
      final reason = _weakPasswordReason(entry.password);
      if (reason != null) {
        weakPasswords.add(WeakPasswordIssue(
          entryId: entry.id,
          entryName: entry.name,
          reason: reason,
        ));
      }

      passwordGroups.putIfAbsent(entry.password, () => []).add(entry);

      final totp = entry.totpSecret;
      if (totp == null || totp.trim().isEmpty) {
        noTotpEntries.add(NoTotpIssue(entryId: entry.id, entryName: entry.name));
      }

      if (entry.url.trim().isEmpty) {
        noUrlEntries.add(NoUrlIssue(entryId: entry.id, entryName: entry.name));
      }
    }

    // 重复密码：同一明文被 ≥2 个条目使用即为一组（去重统计）。
    final reusedPasswords = <ReusedPasswordIssue>[];
    var reusedGroupCount = 0;
    for (final group in passwordGroups.values) {
      if (group.length >= 2) {
        reusedGroupCount++;
        for (final entry in group) {
          reusedPasswords.add(ReusedPasswordIssue(
            entryId: entry.id,
            entryName: entry.name,
            sharedCount: group.length,
          ));
        }
      }
    }

    final score = _computeScore(
      weakPasswords.length,
      reusedGroupCount,
      noTotpEntries.length,
      noUrlEntries.length,
    );

    return HealthReport(
      totalEntries: entries.length,
      weakPasswords: weakPasswords,
      reusedPasswords: reusedPasswords,
      reusedGroupCount: reusedGroupCount,
      noTotpEntries: noTotpEntries,
      noUrlEntries: noUrlEntries,
      score: score,
    );
  }

  /// 判断密码是否弱：命中常见弱密码 > 长度不足 > 单一字符类型。
  static WeakPasswordReason? _weakPasswordReason(String password) {
    if (commonPasswords.contains(password.toLowerCase())) {
      return WeakPasswordReason.commonPassword;
    }
    if (password.length < weakPasswordMinLength) {
      return WeakPasswordReason.tooShort;
    }
    final hasLower = RegExp('[a-z]').hasMatch(password);
    final hasUpper = RegExp('[A-Z]').hasMatch(password);
    final hasDigit = RegExp(r'[0-9]').hasMatch(password);
    final hasSymbol = RegExp(r'[^A-Za-z0-9]').hasMatch(password);
    final typesUsed = [hasLower, hasUpper, hasDigit, hasSymbol].where((b) => b).length;
    if (typesUsed <= 1) {
      return WeakPasswordReason.singleCharType;
    }
    return null;
  }

  static int _computeScore(
    int weakCount,
    int reusedGroups,
    int noTotpCount,
    int noUrlCount,
  ) {
    var score = 100;
    score -= _cap(weakCount * 10, 40);
    score -= _cap(reusedGroups * 15, 30);
    score -= _cap(noTotpCount * 2, 20);
    score -= _cap(noUrlCount * 2, 20);
    return score < 0 ? 0 : score;
  }

  static int _cap(int value, int max) => value > max ? max : value;
}
