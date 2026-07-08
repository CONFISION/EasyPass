import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// TOTP (Time-based One-Time Password) generator based on RFC 6238
class TotpService {
  /// Generate a TOTP code from a base32-encoded secret
  /// [secret] is the base32 TOTP secret
  /// [period] defaults to 30 seconds
  /// [digits] defaults to 6
  /// [algorithm] defaults to SHA-1
  String generateTotp(
    String secret, {
    int period = 30,
    int digits = 6,
    String algorithm = 'SHA1',
  }) {
    final key = _base32Decode(secret.toUpperCase().replaceAll(' ', ''));
    var counter = _getCurrentCounter(period);

    final counterBytes = Uint8List(8);
    for (var i = 7; i >= 0; i--) {
      counterBytes[i] = counter & 0xff;
      counter >>= 8;
    }

    final hmac = Hmac(sha1, key);
    final digest = hmac.convert(counterBytes).bytes;

    final offset = digest[19] & 0x0f;
    final binary = ((digest[offset] & 0x7f) << 24) |
        ((digest[offset + 1] & 0xff) << 16) |
        ((digest[offset + 2] & 0xff) << 8) |
        (digest[offset + 3] & 0xff);

    final otp = binary % pow(10, digits).toInt();
    return otp.toString().padLeft(digits, '0');
  }

  /// Get remaining seconds in the current TOTP period
  int getRemainingSeconds({int period = 30}) {
    return period - (DateTime.now().millisecondsSinceEpoch ~/ 1000) % period;
  }

  /// Validate a TOTP code
  bool validateTotp(
    String secret,
    String code, {
    int period = 30,
    int digits = 6,
    int allowedDrift = 1,
  }) {
    for (var drift = -allowedDrift; drift <= allowedDrift; drift++) {
      final counter = _getCurrentCounter(period) + drift;
      // Re-implement inline to avoid refactoring the whole method
      final key = _base32Decode(secret.toUpperCase().replaceAll(' ', ''));
      final counterBytes = Uint8List(8);
      var c = counter;
      for (var i = 7; i >= 0; i--) {
        counterBytes[i] = c & 0xff;
        c >>= 8;
      }
      final hmac = Hmac(sha1, key);
      final digest = hmac.convert(counterBytes).bytes;
      final offset = digest[19] & 0x0f;
      final binary = ((digest[offset] & 0x7f) << 24) |
          ((digest[offset + 1] & 0xff) << 16) |
          ((digest[offset + 2] & 0xff) << 8) |
          (digest[offset + 3] & 0xff);
      final otp = binary % pow(10, digits).toInt();
      if (otp.toString().padLeft(digits, '0') == code) {
        return true;
      }
    }
    return false;
  }

  int _getCurrentCounter(int period) {
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ period;
  }

  /// Decode a base32 string to bytes
  List<int> _base32Decode(String base32) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final result = <int>[];
    var bits = 0;
    var value = 0;

    for (var i = 0; i < base32.length; i++) {
      final c = base32[i];
      if (c == '=') break; // Padding
      final idx = alphabet.indexOf(c);
      if (idx == -1) continue;

      value = (value << 5) | idx;
      bits += 5;

      if (bits >= 8) {
        bits -= 8;
        result.add((value >> bits) & 0xff);
      }
    }

    return result;
  }
}