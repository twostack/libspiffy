import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:libspiffy/src/utils/atomic_beef.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:test/test.dart';

/// [Brc95] against `test/data/brc100/beef_fixtures.json`: BEEFs of this
/// repository's tests that `@bsv/sdk` 2.8.11 re-encoded as V2 and as Atomic
/// BEEF (V1 and V2 inside), with the last transaction as the subject.
void main() {
  final fixtures = (jsonDecode(File('test/data/brc100/beef_fixtures.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  Uint8List bytes(Object? h) => Uint8List.fromList(hex.decode(h as String));

  for (final (i, f) in fixtures.indexed) {
    group('fixture $i', () {
      test('a V1 BEEF reads as itself, with no subject', () {
        final read = Brc95.read(bytes(f['v1']));
        expect(hex.encode(read.beef.serialize()), f['v1']);
        expect(read.subjectTxid, isNull);
      });

      test('a V2 BEEF reads as the same V1 BEEF', () {
        expect(hex.encode(Brc95.read(bytes(f['v2'])).beef.serialize()), f['v1']);
      });

      test('an Atomic BEEF, wrapping V1 or V2, reads as the V1 BEEF and its subject', () {
        for (final atomic in [f['atomicV1'], f['atomicV2']]) {
          final read = Brc95.read(bytes(atomic));
          expect(hex.encode(read.beef.serialize()), f['v1']);
          expect(read.subjectTxid, f['subject']);
        }
      });

      test('wrapping gives the bytes the reference SDK gives', () {
        expect(hex.encode(Brc95.wrap(BEEF.parse(bytes(f['v1'])), f['subject'] as String)), f['atomicV1']);
      });

      test('wrapping refuses a subject the other transactions do not lead to', () {
        final parent = (f['txids'] as List).first as String;
        expect(() => Brc95.wrap(BEEF.parse(bytes(f['v1'])), parent), throwsA(isA<BEEFException>()));
      });

      test('an Atomic BEEF whose subject is not inside is refused', () {
        final atomic = bytes(f['atomicV1']);
        atomic[4] ^= 0xff;
        expect(() => Brc95.read(atomic), throwsA(isA<BEEFException>()));
      });
    });
  }

  test('a V2 transaction given by txid only is refused', () {
    final v2 = Uint8List.fromList([0x02, 0x00, 0xbe, 0xef, 0x00, 0x01, 0x02, ...List.filled(32, 7)]);
    expect(() => Brc95.read(v2), throwsA(isA<BEEFException>().having((e) => e.message, 'message', contains('txid only'))));
  });

  test('trailing bytes after a V2 BEEF are refused', () {
    final v2 = bytes(fixtures.first['v2']);
    expect(() => Brc95.read([...v2, 0]), throwsA(isA<BEEFException>()));
  });

  test('garbage is a BEEFException, not a crash', () {
    expect(() => Brc95.read([0x02, 0x00, 0xbe, 0xef, 0x05]), throwsA(isA<BEEFException>()));
    expect(() => Brc95.read([0x01, 0x01, 0x01, 0x01, 0x00]), throwsA(isA<BEEFException>()));
  });
}
