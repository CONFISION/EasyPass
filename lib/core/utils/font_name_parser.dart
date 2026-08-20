import 'dart:convert';
import 'dart:typed_data';

/// Extracts the font family name from a TTF/OTF file's `name` table without
/// depending on platform APIs. Used to discover fonts stored as app assets.
class FontNameParser {
  FontNameParser._();

  /// Returns the family name (preferring the typographic family name, nameID
  /// 16, falling back to the family name, nameID 1), or null when the bytes
  /// are not a parseable font.
  static String? familyName(Uint8List data) {
    if (data.length < 12) return null;

    // TrueType collections ('ttcf') wrap several fonts; parse the first one.
    if (utf8.decode(data.sublist(0, 4), allowMalformed: true) == 'ttcf') {
      if (data.length < 16) return null;
      final firstOffset = _u32(data, 12);
      if (firstOffset < 0 || firstOffset + 12 > data.length) return null;
      data = data.sublist(firstOffset);
      if (data.length < 12) return null;
    }

    final numTables = _u16(data, 4);
    // The table directory starts at offset 12; each record is 16 bytes:
    // tag(4) checksum(4) offset(4) length(4)
    final dirEnd = 12 + numTables * 16;
    if (data.length < dirEnd) return null;

    int? nameOffset;
    int? nameLength;
    for (var i = 0; i < numTables; i++) {
      final record = 12 + i * 16;
      if (data.length < record + 16) break;
      final tag = utf8.decode(data.sublist(record, record + 4), allowMalformed: true);
      if (tag == 'name') {
        nameOffset = _u32(data, record + 8);
        nameLength = _u32(data, record + 12);
        break;
      }
    }
    if (nameOffset == null || nameLength == null) return null;
    if (nameOffset < 0 || nameOffset + nameLength > data.length) return null;

    final name = data.sublist(nameOffset, nameOffset + nameLength);
    return _parseNameTable(name);
  }

  static String? _parseNameTable(Uint8List name) {
    if (name.length < 6) return null;
    final count = _u16(name, 2);
    final stringOffset = _u16(name, 4);

    // Records follow the header; each is 12 bytes:
    // platformID(2) encodingID(2) languageID(2) nameID(2) length(2) offset(2)
    String? typographicFamily;
    String? family;

    for (var i = 0; i < count; i++) {
      final record = 6 + i * 12;
      if (record + 12 > name.length) break;
      final platformID = _u16(name, record);
      final nameID = _u16(name, record + 6);
      final strLength = _u16(name, record + 8);
      final strOffset = _u16(name, record + 10);
      final start = stringOffset + strOffset;
      final end = start + strLength;
      if (start < 0 || end > name.length) continue;

      // Windows (3) and Unicode (0) platforms store UTF-16BE strings.
      String? value;
      if (platformID == 0 || platformID == 3) {
        value = _decodeUtf16BE(name, start, end);
      } else if (platformID == 1 && nameID == 1) {
        // Macintosh platform, Latin-1 — rarely needed, but harmless.
        value = latin1.decode(name.sublist(start, end), allowInvalid: true);
      }
      if (value == null || value.isEmpty) continue;

      if (nameID == 16) {
        typographicFamily ??= value;
      } else if (nameID == 1) {
        family ??= value;
      }
    }

    return typographicFamily ?? family;
  }

  static String _decodeUtf16BE(Uint8List data, int start, int end) {
    if ((end - start) % 2 != 0) return '';
    final buffer = StringBuffer();
    for (var i = start; i < end; i += 2) {
      final codeUnit = (data[i] << 8) | data[i + 1];
      buffer.writeCharCode(codeUnit);
    }
    return buffer.toString();
  }

  static int _u16(Uint8List data, int offset) {
    return (data[offset] << 8) | data[offset + 1];
  }

  static int _u32(Uint8List data, int offset) {
    return (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
  }
}
