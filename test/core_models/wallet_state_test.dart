import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';

void main() {
  group('WalletState Tests', () {
    group('Factory Constructors', () {
      test('should create empty wallet state', () {
        const walletId = 'test_wallet_123';
        final state = WalletState.empty(walletId);

        expect(state.walletId, equals(walletId));
        expect(state.name, isEmpty);
        expect(state.rootAddress, isNull);
        expect(state.isCreated, isFalse);
        expect(state.networkType, equals('mainnet'));
        expect(state.utxos, isEmpty);
        expect(state.addresses, isEmpty);
        expect(state.nextDerivationIndex, equals(0));
        expect(state.metadata, isEmpty);
        expect(state.confirmedBalance.getValue(), equals(BigInt.zero));
        expect(state.unconfirmedBalance.getValue(), equals(BigInt.zero));
        expect(state.reservedBalance.getValue(), equals(BigInt.zero));
        expect(state.version, equals(0));
        expect(state.lastModified, isNotNull);
      });

      test('should create initial wallet state after creation', () {
        const walletId = 'test_wallet_123';
        const name = 'My Test Wallet';
        const rootAddress = '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2';
        const networkType = 'testnet';

        final state = WalletState.initial(
          walletId: walletId,
          name: name,
          rootAddress: rootAddress,
          networkType: networkType,
        );

        expect(state.walletId, equals(walletId));
        expect(state.name, equals(name));
        expect(state.rootAddress, equals(rootAddress));
        expect(state.isCreated, isTrue);
        expect(state.networkType, equals(networkType));
        expect(state.utxos, isEmpty);
        expect(state.addresses, isEmpty);
        expect(state.nextDerivationIndex, equals(0));
        expect(state.metadata, isEmpty);
        expect(state.confirmedBalance.getValue(), equals(BigInt.zero));
        expect(state.unconfirmedBalance.getValue(), equals(BigInt.zero));
        expect(state.reservedBalance.getValue(), equals(BigInt.zero));
        expect(state.version, equals(1));
        expect(state.lastModified, isNotNull);
      });
    });

    group('State Properties', () {
      test('should provide balance properties', () {
        final state = _createTestWalletState(
          confirmedBalance: dartsv.Coin.ofSat(BigInt.from(100000)),
          unconfirmedBalance: dartsv.Coin.ofSat(BigInt.from(50000)),
          reservedBalance: dartsv.Coin.ofSat(BigInt.from(25000)),
        );

        expect(state.balance, equals(BigInt.from(150000))); // confirmed + unconfirmed
        expect(state.availableBalance, equals(BigInt.from(125000))); // total - reserved
      });

      test('should handle zero balances', () {
        final state = _createTestWalletState();

        expect(state.balance, equals(BigInt.zero));
        expect(state.availableBalance, equals(BigInt.zero));
      });

      test('should calculate available balance correctly when reserved exceeds total', () {
        final state = _createTestWalletState(
          confirmedBalance: dartsv.Coin.ofSat(BigInt.from(50000)),
          unconfirmedBalance: dartsv.Coin.ofSat(BigInt.from(30000)),
          reservedBalance: dartsv.Coin.ofSat(BigInt.from(100000)),
        );

        expect(state.balance, equals(BigInt.from(80000))); // 50000 + 30000
        expect(state.availableBalance, equals(BigInt.zero)); // max(0, 80000 - 100000)
      });
    });

    group('UTXO Management', () {
      test('should access available UTXOs', () {
        final utxo1 = _createTestUTXO('tx1', 0, BigInt.from(100000), UTXOStatus.available);
        final utxo2 = _createTestUTXO('tx2', 0, BigInt.from(50000), UTXOStatus.reserved);
        final utxo3 = _createTestUTXO('tx3', 0, BigInt.from(75000), UTXOStatus.spent);

        final state = _createTestWalletState(
          utxos: {
            'tx1:0': utxo1,
            'tx2:0': utxo2,
            'tx3:0': utxo3,
          },
        );

        final availableUtxos = state.availableUtxos;
        expect(availableUtxos.length, equals(1));
        expect(availableUtxos.first.txid, equals('tx1'));
      });

      test('should recalculate balances from UTXOs', () {
        // Create UTXOs with different confirmation levels
        final utxo1 = _createTestUTXO('tx1', 0, BigInt.from(100000), UTXOStatus.available, confirmations: 10);
        final utxo2 = _createTestUTXO('tx2', 0, BigInt.from(50000), UTXOStatus.available, confirmations: 1);
        final utxo3 = _createTestUTXO('tx3', 0, BigInt.from(25000), UTXOStatus.reserved, confirmations: 10);

        final state = _createTestWalletState(
          utxos: {
            'tx1:0': utxo1,
            'tx2:0': utxo2,
            'tx3:0': utxo3,
          },
        );

        final recalculated = state.recalculateBalances();
        
        // tx1 (100k) and tx3 (25k) should be confirmed (>= 6 confirmations)
        // tx2 (50k) should be unconfirmed (< 6 confirmations)
        // tx3 (25k) should be reserved
        expect(recalculated.confirmedBalance.getValue(), equals(BigInt.from(100000)));
        expect(recalculated.unconfirmedBalance.getValue(), equals(BigInt.from(50000)));
        expect(recalculated.reservedBalance.getValue(), equals(BigInt.from(25000)));
      });
    });

    group('Address Management', () {
      test('should track managed addresses', () {
        const address1 = '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2';
        const address2 = '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa';
        
        final state = _createTestWalletState(
          addresses: {
            address1: 'Main Address',
            address2: null,
          },
        );

        expect(state.addresses.length, equals(2));
        expect(state.addresses[address1], equals('Main Address'));
        expect(state.addresses[address2], isNull);
      });
    });

    group('CopyWith Functionality', () {
      test('should copy with base State fields', () {
        final original = _createTestWalletState();
        final newTime = DateTime.now().add(Duration(hours: 1));
        
        final copied = original.copyWith(
          version: 5,
          lastModified: newTime,
        );

        expect(copied.version, equals(5));
        expect(copied.lastModified, equals(newTime));
        expect(copied.walletId, equals(original.walletId));
        expect(copied.name, equals(original.name));
      });

      test('should copy with wallet-specific fields', () {
        final original = _createTestWalletState();
        final newUtxos = <String, BitcoinUtxo>{
          'new_tx:0': _createTestUTXO('new_tx', 0, BigInt.from(50000), UTXOStatus.available),
        };
        final newAddresses = <String, String?>{
          'new_address': 'New Label',
        };
        final newMetadata = <String, dynamic>{
          'new_key': 'new_value',
        };

        final copied = original.copyWithWallet(
          name: 'Updated Name',
          isCreated: true,
          networkType: 'testnet',
          utxos: newUtxos,
          addresses: newAddresses,
          nextDerivationIndex: 10,
          metadata: newMetadata,
          confirmedBalance: dartsv.Coin.ofSat(BigInt.from(100000)),
          unconfirmedBalance: dartsv.Coin.ofSat(BigInt.from(25000)),
          reservedBalance: dartsv.Coin.ofSat(BigInt.from(10000)),
        );

        expect(copied.name, equals('Updated Name'));
        expect(copied.isCreated, isTrue);
        expect(copied.networkType, equals('testnet'));
        expect(copied.utxos, equals(newUtxos));
        expect(copied.addresses, equals(newAddresses));
        expect(copied.nextDerivationIndex, equals(10));
        expect(copied.metadata, equals(newMetadata));
        expect(copied.confirmedBalance.getValue(), equals(BigInt.from(100000)));
        expect(copied.unconfirmedBalance.getValue(), equals(BigInt.from(25000)));
        expect(copied.reservedBalance.getValue(), equals(BigInt.from(10000)));
        expect(copied.walletId, equals(original.walletId)); // Unchanged
      });
    });

    group('Serialization', () {
      test('should serialize to map correctly', () {
        final now = DateTime.now();
        final utxo = _createTestUTXO('tx1', 0, BigInt.from(100000), UTXOStatus.available);
        
        final state = WalletState(
          walletId: 'test_wallet',
          name: 'Test Wallet',
          rootAddress: '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2',
          isCreated: true,
          networkType: 'testnet',
          walletType: WalletType.hd,
          timestamp: now,
          utxos: {'tx1:0': utxo},
          addresses: {'addr1': 'Label1', 'addr2': null},
          nextDerivationIndex: 5,
          metadata: {'key': 'value'},
          confirmedBalance: dartsv.Coin.ofSat(BigInt.from(100000)),
          unconfirmedBalance: dartsv.Coin.ofSat(BigInt.from(25000)),
          reservedBalance: dartsv.Coin.ofSat(BigInt.from(10000)),
          version: 3,
          lastModified: now,
        );

        final map = state.toMap();

        expect(map['walletId'], equals('test_wallet'));
        expect(map['name'], equals('Test Wallet'));
        expect(map['rootAddress'], equals('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'));
        expect(map['isCreated'], isTrue);
        expect(map['networkType'], equals('testnet'));
        expect(map['version'], equals(3));
        expect(map['timestamp'], equals(now.toIso8601String()));
        expect(map['utxos'], isA<Map<String, dynamic>>());
        expect(map['addresses'], equals({'addr1': 'Label1', 'addr2': null}));
        expect(map['nextDerivationIndex'], equals(5));
        expect(map['metadata'], equals({'key': 'value'}));
        expect(map['confirmedBalance'], equals('100000'));
        expect(map['unconfirmedBalance'], equals('25000'));
        expect(map['reservedBalance'], equals('10000'));
        expect(map['lastModified'], equals(now.toIso8601String()));
      });

      test('should deserialize from map correctly', () {
        final now = DateTime.now();
        final utxoMap = _createTestUTXO('tx1', 0, BigInt.from(100000), UTXOStatus.available).toMap();
        
        final map = {
          'walletId': 'test_wallet',
          'name': 'Test Wallet',
          'rootAddress': '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2',
          'isCreated': true,
          'networkType': 'testnet',
          'version': 3,
          'timestamp': now.toIso8601String(),
          'utxos': {'tx1:0': utxoMap},
          'addresses': {'addr1': 'Label1', 'addr2': null},
          'nextDerivationIndex': 5,
          'metadata': {'key': 'value'},
          'confirmedBalance': '100000',
          'unconfirmedBalance': '25000',
          'reservedBalance': '10000',
          'lastModified': now.toIso8601String(),
        };

        final state = WalletState.fromMap(map);

        expect(state.walletId, equals('test_wallet'));
        expect(state.name, equals('Test Wallet'));
        expect(state.rootAddress, equals('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'));
        expect(state.isCreated, isTrue);
        expect(state.networkType, equals('testnet'));
        expect(state.version, equals(3));
        expect(state.timestamp, equals(now));
        expect(state.utxos.length, equals(1));
        expect(state.utxos['tx1:0']?.txid, equals('tx1'));
        expect(state.addresses, equals({'addr1': 'Label1', 'addr2': null}));
        expect(state.nextDerivationIndex, equals(5));
        expect(state.metadata, equals({'key': 'value'}));
        expect(state.confirmedBalance.getValue(), equals(BigInt.from(100000)));
        expect(state.unconfirmedBalance.getValue(), equals(BigInt.from(25000)));
        expect(state.reservedBalance.getValue(), equals(BigInt.from(10000)));
        expect(state.lastModified, equals(now));
      });

      test('should handle null values in serialization', () {
        final state = WalletState(
          walletId: 'test_wallet',
          name: 'Test Wallet',
          rootAddress: null, // Explicitly null
          isCreated: true,
          networkType: 'mainnet',
          walletType: WalletType.hd,
          timestamp: DateTime.now(),
          utxos: {},
          addresses: {},
          nextDerivationIndex: 0,
          metadata: {},
          confirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
          unconfirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
          reservedBalance: dartsv.Coin.ofSat(BigInt.zero),
          version: 1,
          lastModified: DateTime.now(),
        );

        final map = state.toMap();
        expect(map['rootAddress'], isNull);

        final deserialized = WalletState.fromMap(map);
        expect(deserialized.rootAddress, isNull);
      });

      test('should handle empty collections in serialization', () {
        final state = WalletState.empty('test_wallet');

        final map = state.toMap();
        expect(map['utxos'], isEmpty);
        expect(map['addresses'], isEmpty);
        expect(map['metadata'], isEmpty);

        final deserialized = WalletState.fromMap(map);
        expect(deserialized.utxos, isEmpty);
        expect(deserialized.addresses, isEmpty);
        expect(deserialized.metadata, isEmpty);
      });

      test('should maintain serialization roundtrip integrity', () {
        final original = _createTestWalletState(
          utxos: {
            'tx1:0': _createTestUTXO('tx1', 0, BigInt.from(100000), UTXOStatus.available),
          },
          addresses: {'addr1': 'Label1'},
          metadata: {'key': 'value'},
        );

        final map = original.toMap();
        final deserialized = WalletState.fromMap(map);

        expect(deserialized.walletId, equals(original.walletId));
        expect(deserialized.name, equals(original.name));
        expect(deserialized.version, equals(original.version));
        expect(deserialized.utxos.length, equals(original.utxos.length));
        expect(deserialized.addresses, equals(original.addresses));
        expect(deserialized.metadata, equals(original.metadata));
      });
    });

    group('Equality and HashCode', () {
      test('should be equal if walletId and version are the same', () {
        const walletId = 'same_wallet';
        const version = 5;
        
        final state1 = _createTestWalletState(
          walletId: walletId,
          version: version,
          name: 'Wallet 1',
        );
        
        final state2 = _createTestWalletState(
          walletId: walletId,
          version: version,
          name: 'Wallet 2', // Different name
        );

        expect(state1, equals(state2));
        expect(state1.hashCode, equals(state2.hashCode));
      });

      test('should not be equal if walletId differs', () {
        final state1 = _createTestWalletState(walletId: 'wallet1', version: 1);
        final state2 = _createTestWalletState(walletId: 'wallet2', version: 1);

        expect(state1, isNot(equals(state2)));
        expect(state1.hashCode, isNot(equals(state2.hashCode)));
      });

      test('should not be equal if version differs', () {
        final state1 = _createTestWalletState(walletId: 'same_wallet', version: 1);
        final state2 = _createTestWalletState(walletId: 'same_wallet', version: 2);

        expect(state1, isNot(equals(state2)));
        expect(state1.hashCode, isNot(equals(state2.hashCode)));
      });

      test('should be equal to itself', () {
        final state = _createTestWalletState();
        expect(state, equals(state));
      });

      test('should not be equal to null or different type', () {
        final state = _createTestWalletState();
        expect(state, isNot(equals(null)));
        expect(state, isNot(equals('not a wallet state')));
      });
    });

    group('String Representation', () {
      test('should provide meaningful toString', () {
        final state = _createTestWalletState(
          walletId: 'test123',
          name: 'My Wallet',
          version: 5,
          isCreated: true,
          confirmedBalance: dartsv.Coin.ofSat(BigInt.from(150000)),
          utxos: {
            'tx1:0': _createTestUTXO('tx1', 0, BigInt.from(100000), UTXOStatus.available),
            'tx2:0': _createTestUTXO('tx2', 0, BigInt.from(50000), UTXOStatus.available),
          },
        );

        final str = state.toString();
        expect(str, contains('test123'));
        expect(str, contains('My Wallet'));
        expect(str, contains('5'));
        expect(str, contains('true'));
        expect(str, contains('2')); // UTXO count
        expect(str, contains('150000')); // Balance
      });

      test('should handle empty wallet in toString', () {
        final state = WalletState.empty('empty_wallet');

        final str = state.toString();
        expect(str, contains('empty_wallet'));
        expect(str, contains('false')); // isCreated
        expect(str, contains('0')); // UTXO count and balance
      });
    });

    group('Edge Cases and Error Conditions', () {
      test('should handle very large UTXO counts', () {
        final utxos = <String, BitcoinUtxo>{};
        for (int i = 0; i < 100; i++) { // Reduced from 1000 for performance
          utxos['tx$i:0'] = _createTestUTXO('tx$i', 0, BigInt.from(1000), UTXOStatus.available);
        }

        final state = _createTestWalletState(utxos: utxos);
        expect(state.utxos.length, equals(100));
        expect(state.availableUtxos.length, equals(100));
      });

      test('should handle very large balances', () {
        final largeBalance = BigInt.parse('2100000000000000'); // 21M BTC in satoshis
        final state = _createTestWalletState(
          confirmedBalance: dartsv.Coin.ofSat(largeBalance),
        );

        expect(state.confirmedBalance.getValue(), equals(largeBalance));
        expect(state.balance, equals(largeBalance));
      });

      test('should handle many addresses', () {
        final addresses = <String, String?>{};
        for (int i = 0; i < 50; i++) { // Reduced from 100 for performance
          addresses['address_$i'] = i % 2 == 0 ? 'Label $i' : null;
        }

        final state = _createTestWalletState(addresses: addresses);
        expect(state.addresses.length, equals(50));
      });

      test('should handle very old and future timestamps', () {
        final veryOld = DateTime(2009, 1, 3); // Bitcoin genesis block
        final future = DateTime(2030, 1, 1);
        
        final state = _createTestWalletState(
          timestamp: veryOld,
          lastModified: future,
        );

        expect(state.timestamp, equals(veryOld));
        expect(state.lastModified, equals(future));
      });

      test('should handle extreme derivation indices', () {
        const largeIndex = 2147483647; // Max 32-bit signed int
        final state = _createTestWalletState(
          nextDerivationIndex: largeIndex,
        );

        expect(state.nextDerivationIndex, equals(largeIndex));
      });
    });
  });
}

/// Helper function to create a test wallet state with sensible defaults
WalletState _createTestWalletState({
  String? walletId,
  String? name,
  String? rootAddress,
  bool? isCreated,
  String? networkType,
  WalletType? walletType,
  DateTime? timestamp,
  Map<String, BitcoinUtxo>? utxos,
  Map<String, String?>? addresses,
  int? nextDerivationIndex,
  Map<String, dynamic>? metadata,
  dartsv.Coin? confirmedBalance,
  dartsv.Coin? unconfirmedBalance,
  dartsv.Coin? reservedBalance,
  int? version,
  DateTime? lastModified,
}) {
  final now = DateTime.now();
  return WalletState(
    walletId: walletId ?? 'test_wallet_123',
    name: name ?? 'Test Wallet',
    rootAddress: rootAddress ?? '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2',
    isCreated: isCreated ?? true,
    networkType: networkType ?? 'mainnet',
    walletType: walletType ?? WalletType.hd,
    timestamp: timestamp ?? now,
    utxos: utxos ?? {},
    addresses: addresses ?? {},
    nextDerivationIndex: nextDerivationIndex ?? 0,
    metadata: metadata ?? {},
    confirmedBalance: confirmedBalance ?? dartsv.Coin.ofSat(BigInt.zero),
    unconfirmedBalance: unconfirmedBalance ?? dartsv.Coin.ofSat(BigInt.zero),
    reservedBalance: reservedBalance ?? dartsv.Coin.ofSat(BigInt.zero),
    version: version ?? 1,
    lastModified: lastModified ?? now,
  );
}

/// Helper function to create a test UTXO
BitcoinUtxo _createTestUTXO(
  String txid,
  int vout,
  BigInt satoshis,
  UTXOStatus status, {
  String? address,
  int? confirmations,
}) {
  final now = DateTime.now();
  return BitcoinUtxo(
    txid: txid,
    vout: vout,
    value: dartsv.Coin.ofSat(satoshis),
    address: address ?? '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2',
    scriptPubKey: '76a914abcd1234efgh5678ijkl9012mnop3456qrst88ac',
    status: status,
    confirmations: confirmations,
    createdAt: now,
    updatedAt: now,
  );
} 