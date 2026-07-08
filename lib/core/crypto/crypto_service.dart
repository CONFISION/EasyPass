import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants/app_constants.dart';

class CryptoService {
  final FlutterSecureStorage _secureStorage;

  CryptoService({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  /// Generate a random salt for PBKDF2
  String generateSalt() {
    final random = Random.secure();
    final saltBytes = List<int>.generate(
      AppConstants.pbkdf2SaltLength,
      (_) => random.nextInt(256),
    );
    return base64Encode(saltBytes);
  }

  /// Manual PBKDF2-HMAC-SHA256 implementation
  /// Derives a key of [keyLength] bytes from [password] using [salt]
  Uint8List _pbkdf2(String password, List<int> salt, int iterations, int keyLength) {
    final hLen = 32; // SHA-256 output length (bytes)
    final passwordBytes = utf8.encode(password);

    // Number of blocks needed
    final blockCount = (keyLength + hLen - 1) ~/ hLen;
    final result = Uint8List(blockCount * hLen);

    for (var blockIndex = 1; blockIndex <= blockCount; blockIndex++) {
      // U_1 = PRF(Password, Salt || INT_32_BE(i))
      final saltWithBlock = Uint8List(salt.length + 4);
      saltWithBlock.setAll(0, salt);
      // Write block index as big-endian 32-bit integer
      saltWithBlock[salt.length] = (blockIndex >> 24) & 0xff;
      saltWithBlock[salt.length + 1] = (blockIndex >> 16) & 0xff;
      saltWithBlock[salt.length + 2] = (blockIndex >> 8) & 0xff;
      saltWithBlock[salt.length + 3] = blockIndex & 0xff;

      var u = _hmacSha256(passwordBytes, saltWithBlock);
      var t = u;

      for (var iteration = 2; iteration <= iterations; iteration++) {
        u = _hmacSha256(passwordBytes, u);
        // T = T XOR U
        for (var j = 0; j < hLen; j++) {
          t[j] ^= u[j];
        }
      }

      // Copy T into result
      final offset = (blockIndex - 1) * hLen;
      result.setRange(offset, offset + hLen, t);
    }

    return Uint8List.sublistView(result, 0, keyLength);
  }

  /// Compute HMAC-SHA256
  Uint8List _hmacSha256(List<int> key, List<int> data) {
    final hmac = Hmac(sha256, key);
    final digest = hmac.convert(data);
    return Uint8List.fromList(digest.bytes);
  }

  /// Derive an AES key from the master password using PBKDF2-HMAC-SHA256
  Uint8List deriveKey(String masterPassword, String salt) {
    final saltBytes = base64Decode(salt);
    return _pbkdf2(
      masterPassword,
      saltBytes,
      AppConstants.pbkdf2Iterations,
      AppConstants.pbkdf2KeyLength,
    );
  }

  /// Compute a hash of the master password for verification
  String hashMasterPassword(String masterPassword, String salt) {
    final key = deriveKey(masterPassword, salt);
    final hash = sha256.convert(key);
    return base64Encode(hash.bytes);
  }

  /// Generate a random IV for AES encryption
  encrypt.IV generateIV() {
    return encrypt.IV.fromSecureRandom(AppConstants.aesIvLength);
  }

  /// Encrypt plaintext using AES-256-CBC
  String encryptData(String plaintext, Uint8List key) {
    final iv = generateIV();
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(key), mode: encrypt.AESMode.cbc),
    );

    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    // Combine IV + ciphertext, then base64 encode
    final combined = Uint8List.fromList(iv.bytes + encrypted.bytes);
    return base64Encode(combined);
  }

  /// Decrypt ciphertext using AES-256-CBC
  String decryptData(String encryptedBase64, Uint8List key) {
    final combined = base64Decode(encryptedBase64);
    final ivBytes = combined.sublist(0, AppConstants.aesIvLength);
    final cipherBytes = combined.sublist(AppConstants.aesIvLength);

    final iv = encrypt.IV(ivBytes);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(key), mode: encrypt.AESMode.cbc),
    );

    return encrypter.decrypt(
      encrypt.Encrypted(cipherBytes),
      iv: iv,
    );
  }

  /// Store the encryption key material securely
  Future<void> storeKeyMaterial(String salt, String passwordHash) async {
    await _secureStorage.write(
      key: '${AppConstants.secureStorageKey}_salt',
      value: salt,
    );
    await _secureStorage.write(
      key: AppConstants.masterPasswordHashKey,
      value: passwordHash,
    );
  }

  /// Retrieve the stored salt
  Future<String?> getStoredSalt() async {
    return await _secureStorage.read(
      key: '${AppConstants.secureStorageKey}_salt',
    );
  }

  /// Retrieve the stored password hash
  Future<String?> getStoredPasswordHash() async {
    return await _secureStorage.read(
      key: AppConstants.masterPasswordHashKey,
    );
  }

  /// Check if this is the first run (no master password set)
  Future<bool> isFirstRun() async {
    final hash = await _secureStorage.read(
      key: AppConstants.masterPasswordHashKey,
    );
    return hash == null;
  }

  /// Clear all stored key material
  Future<void> clearKeyMaterial() async {
    await _secureStorage.delete(
      key: '${AppConstants.secureStorageKey}_salt',
    );
    await _secureStorage.delete(
      key: AppConstants.masterPasswordHashKey,
    );
  }
}