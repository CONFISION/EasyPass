import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/utils/font_name_parser.dart';

void main() {
  test('parses the bundled Maple Mono NF CN family name', () async {
    final file = File('assets/fonts/MapleMono-NF-CN-Regular.ttf');
    if (!await file.exists()) {
      // Fonts are a build-time software asset; skip when not present.
      return;
    }
    final bytes = await file.readAsBytes();
    expect(FontNameParser.familyName(bytes), 'Maple Mono NF CN');
  });

  test('returns null for non-font bytes', () {
    final garbage = Uint8List.fromList(List<int>.generate(64, (i) => i));
    expect(FontNameParser.familyName(garbage), isNull);
    expect(FontNameParser.familyName(Uint8List(4)), isNull);
  });

  test('resolves the family name from a name-table slice', () {
    // A minimal synthetic font header: sfnt + a name table with one
    // Windows-platform family-name record (nameID 1).
    final bytes = Uint8List(12 + 16 + 34);
    final header = ByteData.sublistView(bytes, 0, 12);
    header.setUint16(4, 1, Endian.big); // one table
    header.setUint32(8, 0xFFFFFFFF, Endian.big); // offset marker

    // 'name' tag record at offset 12.
    bytes.setAll(12, 'name'.codeUnits);
    final record = ByteData.sublistView(bytes, 12);
    record.setUint32(8, 12 + 16, Endian.big); // name table offset
    record.setUint32(12, 34, Endian.big); // name table length

    // Name table: format=0, count=1, stringOffset=6+12=18
    final table = ByteData.sublistView(bytes, 12 + 16);
    table.setUint16(0, 0, Endian.big);
    table.setUint16(2, 1, Endian.big);
    table.setUint16(4, 18, Endian.big);
    // Record: platformID=3(Windows), encodingID=1, languageID=0x409,
    // nameID=1(family), length=6, offset=0
    table.setUint16(6, 3, Endian.big);
    table.setUint16(8, 1, Endian.big);
    table.setUint16(10, 0x0409, Endian.big);
    table.setUint16(12, 1, Endian.big);
    table.setUint16(14, 6, Endian.big);
    table.setUint16(16, 0, Endian.big);
    // String "MapleM" as UTF-16BE at offset 18 (6 bytes = 3 code units)
    bytes.setAll(12 + 16 + 18, [0x00, 0x4D, 0x00, 0x61, 0x00, 0x70]); // M a p

    expect(FontNameParser.familyName(bytes), 'Map');
  });
}
