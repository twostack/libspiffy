import 'package:test/test.dart';
import 'package:libspiffy/libspiffy.dart';

void main() {
  group('PluginOutputSpec', () {
    test('construction and field access', () {
      final spec = PluginOutputSpec(
        pluginId: 'tstoken',
        pluginScriptType: 'pp1_nft',
        params: {'tokenId': 'abc123', 'ownerPKH': 'def456'},
        amount: BigInt.from(546),
        label: 'NFT transfer',
      );

      expect(spec.pluginId, equals('tstoken'));
      expect(spec.pluginScriptType, equals('pp1_nft'));
      expect(spec.params['tokenId'], equals('abc123'));
      expect(spec.amount, equals(BigInt.from(546)));
      expect(spec.label, equals('NFT transfer'));
      expect(spec.scriptType, equals(BitcoinScriptType.custom));
    });

    test('toMap serialization', () {
      final spec = PluginOutputSpec(
        pluginId: 'tstoken',
        pluginScriptType: 'pp1_ft',
        params: {'tokenId': 'tok1', 'amount': '1000'},
        amount: BigInt.from(1000),
      );

      final map = spec.toMap();
      expect(map['type'], equals('plugin'));
      expect(map['pluginId'], equals('tstoken'));
      expect(map['pluginScriptType'], equals('pp1_ft'));
      expect(map['params'], isA<Map>());
      expect(map['amount'], equals('1000'));
      expect(map.containsKey('label'), isFalse);
    });

    test('toMap includes label when present', () {
      final spec = PluginOutputSpec(
        pluginId: 'test',
        pluginScriptType: 'type',
        params: {},
        amount: BigInt.one,
        label: 'my label',
      );

      expect(spec.toMap()['label'], equals('my label'));
    });

    test('fromMap deserialization', () {
      final map = {
        'type': 'plugin',
        'pluginId': 'tstoken',
        'pluginScriptType': 'pp1_nft',
        'params': {'tokenId': 'abc'},
        'amount': '546',
        'label': 'test',
      };

      final spec = PluginOutputSpec.fromMap(map);
      expect(spec.pluginId, equals('tstoken'));
      expect(spec.pluginScriptType, equals('pp1_nft'));
      expect(spec.params['tokenId'], equals('abc'));
      expect(spec.amount, equals(BigInt.from(546)));
      expect(spec.label, equals('test'));
    });

    test('round-trip serialization', () {
      final original = PluginOutputSpec(
        pluginId: 'mytoken',
        pluginScriptType: 'transfer',
        params: {'recipient': 'addr1', 'tokenId': 'tok1'},
        amount: BigInt.from(100000),
        label: 'payment',
      );

      final restored = PluginOutputSpec.fromMap(original.toMap());
      expect(restored, equals(original));
    });

    test('InvoiceOutputSpec.fromMap dispatches to PluginOutputSpec', () {
      final map = {
        'type': 'plugin',
        'pluginId': 'test',
        'pluginScriptType': 'custom',
        'params': <String, dynamic>{},
        'amount': '0',
      };

      final spec = InvoiceOutputSpec.fromMap(map);
      expect(spec, isA<PluginOutputSpec>());
      expect((spec as PluginOutputSpec).pluginId, equals('test'));
    });

    test('equality', () {
      final a = PluginOutputSpec(
        pluginId: 'p',
        pluginScriptType: 't',
        params: {'k': 'v'},
        amount: BigInt.from(100),
      );
      final b = PluginOutputSpec(
        pluginId: 'p',
        pluginScriptType: 't',
        params: {'k': 'v'},
        amount: BigInt.from(100),
      );
      final c = PluginOutputSpec(
        pluginId: 'p',
        pluginScriptType: 'different',
        params: {'k': 'v'},
        amount: BigInt.from(100),
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
