import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/totp_service.dart';

void main() {
  // RFC 6238 Appendix B test vectors (SHA-1). The RFC publishes 8-digit
  // codes; EasyPass emits 6 digits, i.e. the low 6 digits of each vector.
  // base32 of "12345678901234567890"
  const secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
  const vectors = <int, String>{
    59: '287082',
    1111111109: '081804',
    1111111111: '050471',
    1234567890: '005924',
    2000000000: '279037',
    20000000000: '353130',
  };

  vectors.forEach((seconds, expected) {
    test('TOTP at t=$seconds matches RFC 6238 vector', () {
      final service = TotpService(
        clock: () => DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
      );
      expect(service.generateTotp(secret), expected);
    });
  });

  test('getRemainingSeconds stays within the period', () {
    final service = TotpService(
      clock: () => DateTime.fromMillisecondsSinceEpoch(59 * 1000),
    );
    final remaining = service.getRemainingSeconds();
    expect(remaining, inInclusiveRange(1, 30));
  });

  test('validateTotp accepts the current code', () {
    final service = TotpService(
      clock: () => DateTime.fromMillisecondsSinceEpoch(59 * 1000),
    );
    expect(service.validateTotp(secret, '287082'), isTrue);
  });

  test('validateTotp rejects a wrong code', () {
    final service = TotpService(
      clock: () => DateTime.fromMillisecondsSinceEpoch(59 * 1000),
    );
    expect(service.validateTotp(secret, '000000'), isFalse);
  });

  test('validateTotp accepts a code one period in the past with drift', () {
    // Now = 89s, so the code from t=59 is one period old.
    final service = TotpService(
      clock: () => DateTime.fromMillisecondsSinceEpoch(89 * 1000),
    );
    expect(service.validateTotp(secret, '287082', allowedDrift: 1), isTrue);
    expect(service.validateTotp(secret, '287082', allowedDrift: 0), isFalse);
  });
}
