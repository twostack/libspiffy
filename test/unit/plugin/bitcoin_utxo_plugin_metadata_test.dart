import 'package:test/test.dart';
import 'package:libspiffy/libspiffy.dart';

void main() {
  group('BitcoinUtxo.pluginMetadata', () {
    BitcoinUtxo createTestUtxo({Map<String, dynamic>? pluginMetadata}) {
      return BitcoinUtxo.create(
        txid: 'a' * 64,
        vout: 0,
        satoshis: BigInt.from(1000),
        scriptPubKey: '76a914' + '00' * 20 + '88ac',
        address: 'mfWxJ45yp2SFn7UciZyNpvDKrzbiYg37EM',
        pluginMetadata: pluginMetadata,
      );
    }

    test('create with null pluginMetadata', () {
      final utxo = createTestUtxo();
      expect(utxo.pluginMetadata, isNull);
    });

    test('create with pluginMetadata', () {
      final meta = {
        'pluginId': 'tstoken',
        'scriptType': 'pp1_nft',
        'tokenId': 'abc123',
      };
      final utxo = createTestUtxo(pluginMetadata: meta);

      expect(utxo.pluginMetadata, isNotNull);
      expect(utxo.pluginMetadata!['pluginId'], equals('tstoken'));
      expect(utxo.pluginMetadata!['tokenId'], equals('abc123'));
    });

    test('copyWith preserves pluginMetadata', () {
      final utxo = createTestUtxo(
        pluginMetadata: {'pluginId': 'test', 'data': 42},
      );

      final copied = utxo.copyWith(status: UTXOStatus.reserved);
      expect(copied.status, equals(UTXOStatus.reserved));
      expect(copied.pluginMetadata, equals(utxo.pluginMetadata));
    });

    test('copyWith can update pluginMetadata', () {
      final utxo = createTestUtxo(
        pluginMetadata: {'pluginId': 'old'},
      );

      final updated = utxo.copyWith(
        pluginMetadata: {'pluginId': 'new', 'extra': true},
      );
      expect(updated.pluginMetadata!['pluginId'], equals('new'));
      expect(updated.pluginMetadata!['extra'], isTrue);
    });

    test('copyWith can set pluginMetadata to null', () {
      final utxo = createTestUtxo(
        pluginMetadata: {'pluginId': 'test'},
      );

      final cleared = utxo.copyWith(pluginMetadata: null);
      expect(cleared.pluginMetadata, isNull);
    });

    test('toMap includes pluginMetadata when present', () {
      final utxo = createTestUtxo(
        pluginMetadata: {
          'pluginId': 'tstoken',
          'scriptType': 'pp1_ft',
          'amount': '5000',
        },
      );

      final map = utxo.toMap();
      expect(map.containsKey('pluginMetadata'), isTrue);
      expect(map['pluginMetadata']['pluginId'], equals('tstoken'));
      expect(map['pluginMetadata']['amount'], equals('5000'));
    });

    test('toMap omits pluginMetadata when null', () {
      final utxo = createTestUtxo();
      final map = utxo.toMap();
      expect(map.containsKey('pluginMetadata'), isFalse);
    });

    test('fromMap restores pluginMetadata', () {
      final utxo = createTestUtxo(
        pluginMetadata: {
          'pluginId': 'tstoken',
          'scriptType': 'pp1_nft',
          'tokenId': 'roundtrip_test',
        },
      );

      final restored = BitcoinUtxo.fromMap(utxo.toMap());
      expect(restored.pluginMetadata, isNotNull);
      expect(restored.pluginMetadata!['tokenId'], equals('roundtrip_test'));
    });

    test('fromMap handles missing pluginMetadata', () {
      final utxo = createTestUtxo();
      final restored = BitcoinUtxo.fromMap(utxo.toMap());
      expect(restored.pluginMetadata, isNull);
    });
  });
}
