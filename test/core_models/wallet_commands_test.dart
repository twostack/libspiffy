import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet_commands.dart';

void main() {
  group('Wallet Commands Tests', () {
    group('Base WalletCommand', () {
      test('should create command with all required fields', () {
        const walletId = 'test_wallet_123';
        const commandId = 'cmd_123';
        final timestamp = DateTime.now();
        final metadata = {'key': 'value'};

        final command = TestWalletCommand(
          walletId: walletId,
          commandId: commandId,
          timestamp: timestamp,
          metadata: metadata,
        );

        expect(command.walletId, equals(walletId));
        expect(command.commandId, equals(commandId));
        expect(command.timestamp, equals(timestamp));
        expect(command.metadata, equals(metadata));
        expect(command.commandType, equals('TestWalletCommand'));
      });

      test('should generate UUID for commandId if not provided', () {
        final command = TestWalletCommand(walletId: 'test_wallet');
        expect(command.commandId, isNotNull);
        expect(command.commandId.length, greaterThan(10)); // Should be some reasonable length
      });

      test('should use current time for timestamp if not provided', () {
        final before = DateTime.now();
        final command = TestWalletCommand(walletId: 'test_wallet');
        final after = DateTime.now();
        
        expect(command.timestamp, isNotNull);
        expect(command.timestamp.isAfter(before.subtract(Duration(seconds: 1))), isTrue);
        expect(command.timestamp.isBefore(after.add(Duration(seconds: 1))), isTrue);
      });

      test('should provide meaningful toString', () {
        final command = TestWalletCommand(
          walletId: 'wallet_123',
          commandId: 'cmd_123',
        );

        final str = command.toString();
        expect(str, contains('TestWalletCommand'));
        expect(str, contains('cmd_123'));
        expect(str, contains('wallet_123'));
      });
    });

    group('CreateWalletCommand', () {
      test('should create wallet command with all fields', () {
        const walletId = 'new_wallet_123';
        const walletName = 'My New Wallet';
        const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        const passphrase = 'optional_passphrase';
        final walletMetadata = {'network': 'mainnet', 'purpose': 'savings'};

        final command = CreateWalletCommand(
          walletId: walletId,
          walletName: walletName,
          mnemonic: mnemonic,
          passphrase: passphrase,
          walletMetadata: walletMetadata,
        );

        expect(command.walletId, equals(walletId));
        expect(command.walletName, equals(walletName));
        expect(command.mnemonic, equals(mnemonic));
        expect(command.passphrase, equals(passphrase));
        expect(command.walletMetadata, equals(walletMetadata));
        expect(command.commandType, equals('CreateWalletCommand'));
      });

      test('should handle optional fields', () {
        const walletId = 'new_wallet_123';
        const walletName = 'Simple Wallet';

        final command = CreateWalletCommand(
          walletId: walletId,
          walletName: walletName,
        );

        expect(command.walletId, equals(walletId));
        expect(command.walletName, equals(walletName));
        expect(command.mnemonic, isNull);
        expect(command.passphrase, isNull);
        expect(command.walletMetadata, isNull);
      });

      test('should handle empty wallet metadata', () {
        final command = CreateWalletCommand(
          walletId: 'wallet_123',
          walletName: 'Test Wallet',
          walletMetadata: {},
        );

        expect(command.walletMetadata, isEmpty);
      });
    });

    group('UpdateWalletConfigurationCommand', () {
      test('should create configuration update command', () {
        const walletId = 'wallet_123';
        const newName = 'Updated Wallet Name';
        final newMetadata = {'theme': 'dark', 'currency': 'USD'};

        final command = UpdateWalletConfigurationCommand(
          walletId: walletId,
          newName: newName,
          newMetadata: newMetadata,
        );

        expect(command.walletId, equals(walletId));
        expect(command.newName, equals(newName));
        expect(command.newMetadata, equals(newMetadata));
        expect(command.commandType, equals('UpdateWalletConfigurationCommand'));
      });

      test('should handle name-only update', () {
        final command = UpdateWalletConfigurationCommand(
          walletId: 'wallet_123',
          newName: 'New Name Only',
        );

        expect(command.newName, equals('New Name Only'));
        expect(command.newMetadata, isNull);
      });

      test('should handle metadata-only update', () {
        final command = UpdateWalletConfigurationCommand(
          walletId: 'wallet_123',
          newMetadata: {'setting': 'value'},
        );

        expect(command.newName, isNull);
        expect(command.newMetadata, equals({'setting': 'value'}));
      });

      test('should handle empty metadata update', () {
        final command = UpdateWalletConfigurationCommand(
          walletId: 'wallet_123',
          newMetadata: {},
        );

        expect(command.newMetadata, isEmpty);
      });
    });

    group('GenerateAddressCommand', () {
      test('should create address generation command', () {
        const walletId = 'wallet_123';
        const label = 'Receiving Address';
        const purpose = 'receive';

        final command = GenerateAddressCommand(
          walletId: walletId,
          label: label,
          purpose: purpose,
        );

        expect(command.walletId, equals(walletId));
        expect(command.label, equals(label));
        expect(command.purpose, equals(purpose));
        expect(command.commandType, equals('GenerateAddressCommand'));
      });

      test('should handle optional fields', () {
        const walletId = 'wallet_123';

        final command = GenerateAddressCommand(walletId: walletId);

        expect(command.walletId, equals(walletId));
        expect(command.label, isNull);
        expect(command.purpose, isNull);
      });

      test('should handle different address purposes', () {
        const walletId = 'wallet_123';

        final receiveCommand = GenerateAddressCommand(
          walletId: walletId,
          purpose: 'receive',
        );

        final changeCommand = GenerateAddressCommand(
          walletId: walletId,
          purpose: 'change',
        );

        expect(receiveCommand.purpose, equals('receive'));
        expect(changeCommand.purpose, equals('change'));
      });
    });

    group('UpdateAddressLabelCommand', () {
      test('should create address label update command', () {
        const walletId = 'wallet_123';
        const address = '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2';
        const newLabel = 'Updated Label';

        final command = UpdateAddressLabelCommand(
          walletId: walletId,
          address: address,
          newLabel: newLabel,
        );

        expect(command.walletId, equals(walletId));
        expect(command.address, equals(address));
        expect(command.newLabel, equals(newLabel));
        expect(command.commandType, equals('UpdateAddressLabelCommand'));
      });

      test('should handle null label (remove label)', () {
        const walletId = 'wallet_123';
        const address = '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2';

        final command = UpdateAddressLabelCommand(
          walletId: walletId,
          address: address,
          newLabel: null,
        );

        expect(command.address, equals(address));
        expect(command.newLabel, isNull);
      });

      test('should handle empty label', () {
        const walletId = 'wallet_123';
        const address = '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2';

        final command = UpdateAddressLabelCommand(
          walletId: walletId,
          address: address,
          newLabel: '',
        );

        expect(command.newLabel, isEmpty);
      });
    });

    group('CreateTransactionCommand', () {
      test('should create transaction command', () {
        const walletId = 'wallet_123';
        const transactionId = 'tx_123';
        final outputs = [
          TransactionOutput(address: '1Address1', satoshis: BigInt.from(100000)),
          TransactionOutput(address: '1Address2', satoshis: BigInt.from(50000)),
        ];
        final feeRate = BigInt.from(50); // sats per KB
        final transactionMetadata = {'note': 'Test transaction'};

        final command = CreateTransactionCommand(
          walletId: walletId,
          transactionId: transactionId,
          outputs: outputs,
          feeRate: feeRate,
          transactionMetadata: transactionMetadata,
        );

        expect(command.walletId, equals(walletId));
        expect(command.transactionId, equals(transactionId));
        expect(command.outputs, equals(outputs));
        expect(command.feeRate, equals(feeRate));
        expect(command.transactionMetadata, equals(transactionMetadata));
        expect(command.commandType, equals('CreateTransactionCommand'));
      });

      test('should handle optional fields', () {
        const walletId = 'wallet_123';
        const transactionId = 'tx_456';
        final outputs = [
          TransactionOutput(address: '1Address1', satoshis: BigInt.from(100000)),
        ];

        final command = CreateTransactionCommand(
          walletId: walletId,
          transactionId: transactionId,
          outputs: outputs,
        );

        expect(command.outputs, equals(outputs));
        expect(command.feeRate, isNull);
        expect(command.transactionMetadata, isNull);
        expect(command.changeAddress, isNull);
        expect(command.allowDust, equals(false));
      });

      test('should handle empty outputs list', () {
        const walletId = 'wallet_123';
        const transactionId = 'tx_789';
        final outputs = <TransactionOutput>[];

        final command = CreateTransactionCommand(
          walletId: walletId,
          transactionId: transactionId,
          outputs: outputs,
        );

        expect(command.outputs, isEmpty);
      });
    });

    group('SignTransactionCommand', () {
      test('should create sign transaction command', () {
        const walletId = 'wallet_123';
        const transactionId = 'transaction_123';
        const rawTransaction = '0100000001abc123...';
        final utxoKeys = ['tx1:0', 'tx2:1'];

        final command = SignTransactionCommand(
          walletId: walletId,
          transactionId: transactionId,
          rawTransaction: rawTransaction,
          utxoKeys: utxoKeys,
        );

        expect(command.walletId, equals(walletId));
        expect(command.transactionId, equals(transactionId));
        expect(command.rawTransaction, equals(rawTransaction));
        expect(command.utxoKeys, equals(utxoKeys));
        expect(command.commandType, equals('SignTransactionCommand'));
      });

      test('should handle empty transaction hex', () {
        const walletId = 'wallet_123';
        const transactionId = 'transaction_123';
        final utxoKeys = <String>[];

        final command = SignTransactionCommand(
          walletId: walletId,
          transactionId: transactionId,
          rawTransaction: '',
          utxoKeys: utxoKeys,
        );

        expect(command.rawTransaction, isEmpty);
        expect(command.utxoKeys, isEmpty);
      });
    });

    group('BroadcastTransactionCommand', () {
      test('should create broadcast transaction command', () {
        const walletId = 'wallet_123';
        const transactionId = 'transaction_123';
        const signedTransaction = '0100000001def456...';

        final command = BroadcastTransactionCommand(
          walletId: walletId,
          transactionId: transactionId,
          signedTransaction: signedTransaction,
        );

        expect(command.walletId, equals(walletId));
        expect(command.transactionId, equals(transactionId));
        expect(command.signedTransaction, equals(signedTransaction));
        expect(command.commandType, equals('BroadcastTransactionCommand'));
      });
    });

    group('UTXO Management Commands', () {
      test('should create receive UTXO command', () {
        const walletId = 'wallet_123';
        const txid = 'abc123def456';
        const vout = 0;
        final satoshis = BigInt.from(100000);
        const address = '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2';
        const scriptPubKey = '76a914abcd1234...88ac';

        final command = ReceiveUTXOCommand(
          walletId: walletId,
          txid: txid,
          vout: vout,
          satoshis: satoshis,
          address: address,
          scriptPubKey: scriptPubKey,
        );

        expect(command.walletId, equals(walletId));
        expect(command.txid, equals(txid));
        expect(command.vout, equals(vout));
        expect(command.satoshis, equals(satoshis));
        expect(command.address, equals(address));
        expect(command.scriptPubKey, equals(scriptPubKey));
        expect(command.commandType, equals('ReceiveUTXOCommand'));
      });

      test('should create spend UTXO command', () {
        const walletId = 'wallet_123';
        const utxoKey = 'abc123def456:0';
        const spendingTxId = 'def456abc123';
        final fee = BigInt.from(1000);

        final command = SpendUTXOCommand(
          walletId: walletId,
          utxoKey: utxoKey,
          spendingTxId: spendingTxId,
          fee: fee,
        );

        expect(command.walletId, equals(walletId));
        expect(command.utxoKey, equals(utxoKey));
        expect(command.spendingTxId, equals(spendingTxId));
        expect(command.fee, equals(fee));
        expect(command.commandType, equals('SpendUTXOCommand'));
      });

      test('should create UTXO confirmation update command', () {
        const walletId = 'wallet_123';
        const utxoKey = 'abc123def456:0';
        const blockHeight = 750000;
        const confirmations = 6;

        final command = UpdateUTXOConfirmationsCommand(
          walletId: walletId,
          utxoKey: utxoKey,
          confirmations: confirmations,
          blockHeight: blockHeight,
        );

        expect(command.walletId, equals(walletId));
        expect(command.utxoKey, equals(utxoKey));
        expect(command.confirmations, equals(confirmations));
        expect(command.blockHeight, equals(blockHeight));
        expect(command.commandType, equals('UpdateUTXOConfirmationsCommand'));
      });

      test('should create reserve UTXOs command', () {
        const walletId = 'wallet_123';
        final utxoKeys = ['tx1:0', 'tx2:1', 'tx3:0'];
        const reservationId = 'reservation_123';
        const reservationDuration = Duration(minutes: 10);

        final command = ReserveUTXOsCommand(
          walletId: walletId,
          utxoKeys: utxoKeys,
          reservationId: reservationId,
          reservationDuration: reservationDuration,
        );

        expect(command.walletId, equals(walletId));
        expect(command.utxoKeys, equals(utxoKeys));
        expect(command.reservationId, equals(reservationId));
        expect(command.reservationDuration, equals(reservationDuration));
        expect(command.commandType, equals('ReserveUTXOsCommand'));
      });

      test('should create release UTXOs command', () {
        const walletId = 'wallet_123';
        const reservationId = 'reservation_123';

        final command = ReleaseUTXOsCommand(
          walletId: walletId,
          reservationId: reservationId,
        );

        expect(command.walletId, equals(walletId));
        expect(command.reservationId, equals(reservationId));
        expect(command.commandType, equals('ReleaseUTXOsCommand'));
      });

      test('should handle empty UTXO keys list', () {
        const walletId = 'wallet_123';
        final utxoKeys = <String>[];
        const reservationId = 'reservation_123';

        final command = ReserveUTXOsCommand(
          walletId: walletId,
          utxoKeys: utxoKeys,
          reservationId: reservationId,
        );

        expect(command.utxoKeys, isEmpty);
      });
    });

    group('Command Inheritance and Polymorphism', () {
      test('should work with WalletCommand base type', () {
        final commands = <WalletCommand>[
          CreateWalletCommand(
            walletId: 'wallet_1',
            walletName: 'Wallet 1',
          ),
          UpdateWalletConfigurationCommand(
            walletId: 'wallet_1',
            newName: 'Updated Name',
          ),
          GenerateAddressCommand(
            walletId: 'wallet_1',
            label: 'New Address',
          ),
        ];

        expect(commands.length, equals(3));
        expect(commands[0], isA<CreateWalletCommand>());
        expect(commands[1], isA<UpdateWalletConfigurationCommand>());
        expect(commands[2], isA<GenerateAddressCommand>());

        // All should have the same walletId
        for (final command in commands) {
          expect(command.walletId, equals('wallet_1'));
        }
      });

      test('should maintain command type information', () {
        final createWallet = CreateWalletCommand(
          walletId: 'wallet_1',
          walletName: 'Test Wallet',
        );

        final configUpdate = UpdateWalletConfigurationCommand(
          walletId: 'wallet_1',
          newName: 'Updated Name',
        );

        expect(createWallet.runtimeType, equals(CreateWalletCommand));
        expect(configUpdate.runtimeType, equals(UpdateWalletConfigurationCommand));
        expect(createWallet, isA<WalletCommand>());
        expect(configUpdate, isA<WalletCommand>());
      });

      test('should have unique command types', () {
        final commands = [
          CreateWalletCommand(walletId: 'w1', walletName: 'W1'),
          UpdateWalletConfigurationCommand(walletId: 'w1'),
          GenerateAddressCommand(walletId: 'w1'),
          UpdateAddressLabelCommand(walletId: 'w1', address: '1Addr'),
          CreateTransactionCommand(walletId: 'w1', transactionId: 'tx1', outputs: []),
          SignTransactionCommand(walletId: 'w1', transactionId: 'tx1', rawTransaction: 'hex', utxoKeys: []),
          BroadcastTransactionCommand(walletId: 'w1', transactionId: 'tx1', signedTransaction: 'hex'),
        ];

        final commandTypes = commands.map((cmd) => cmd.commandType).toSet();
        expect(commandTypes.length, equals(commands.length)); // All unique
      });
    });

    group('Edge Cases and Error Conditions', () {
      test('should handle empty strings', () {
        final command = CreateWalletCommand(
          walletId: '',
          walletName: '',
          mnemonic: '',
          passphrase: '',
        );

        expect(command.walletId, isEmpty);
        expect(command.walletName, isEmpty);
        expect(command.mnemonic, isEmpty);
        expect(command.passphrase, isEmpty);
      });

      test('should handle very long wallet names', () {
        const walletId = 'wallet_123';
        final longName = 'Very long wallet name that exceeds typical length limits ' * 10;

        final command = CreateWalletCommand(
          walletId: walletId,
          walletName: longName,
        );

        expect(command.walletName, equals(longName));
        expect(command.walletName.length, greaterThan(100));
      });

      test('should handle very large amounts in transactions', () {
        const walletId = 'wallet_123';
        const transactionId = 'tx_large';
        final largeAmount = BigInt.from(2100000000000000); // 21M BTC in satoshis
        final outputs = [
          TransactionOutput(address: '1Address1', satoshis: largeAmount),
        ];

        final command = CreateTransactionCommand(
          walletId: walletId,
          transactionId: transactionId,
          outputs: outputs,
        );

        expect(command.outputs[0].satoshis, equals(largeAmount));
      });

      test('should handle zero amounts', () {
        const walletId = 'wallet_123';
        final command = ReceiveUTXOCommand(
          walletId: walletId,
          txid: 'tx1',
          vout: 0,
          satoshis: BigInt.zero,
          address: '1Address',
          scriptPubKey: 'script',
        );

        expect(command.satoshis, equals(BigInt.zero));
      });

      test('should handle very old and future timestamps', () {
        final veryOld = DateTime(2009, 1, 3); // Bitcoin genesis block
        final future = DateTime(2030, 1, 1);

        final command1 = CreateWalletCommand(
          walletId: 'wallet_old',
          walletName: 'Old Wallet',
          timestamp: veryOld,
        );

        final command2 = CreateWalletCommand(
          walletId: 'wallet_future',
          walletName: 'Future Wallet',
          timestamp: future,
        );

        expect(command1.timestamp, equals(veryOld));
        expect(command2.timestamp, equals(future));
      });

      test('should handle complex metadata structures', () {
        final complexMetadata = {
          'nested': {
            'deep': {
              'value': 'test',
              'number': 42,
              'boolean': true,
              'list': [1, 2, 3],
            },
          },
          'array': ['a', 'b', 'c'],
          'null_value': null,
        };

        final command = CreateWalletCommand(
          walletId: 'wallet_123',
          walletName: 'Complex Wallet',
          walletMetadata: complexMetadata,
        );

        expect(command.walletMetadata, equals(complexMetadata));
      });

      test('should handle very long reservation times', () {
        const walletId = 'wallet_123';
        final longReservation = Duration(days: 365); // 1 year

        final command = ReserveUTXOsCommand(
          walletId: walletId,
          utxoKeys: ['tx1:0'],
          reservationId: 'long_reservation',
          reservationDuration: longReservation,
        );

        expect(command.reservationDuration, equals(longReservation));
        expect(command.reservationDuration!.inDays, equals(365));
      });
    });
  });
}

/// Test implementation of WalletCommand for testing base functionality
class TestWalletCommand extends WalletCommand {
  TestWalletCommand({
    required super.walletId,
    super.commandId,
    super.timestamp,
    super.metadata,
  });

  @override
  String get commandType => 'TestWalletCommand';
} 