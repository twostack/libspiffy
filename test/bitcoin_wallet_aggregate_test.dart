import 'dart:io';
import 'package:test/test.dart';
import 'package:isar/isar.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

void main() {
  group('BitcoinWalletAggregate Tests', () {
    late Isar isar;
    late EventStore eventStore;
    late Directory tempDir;
    late CryptoService cryptoService;
    late SecureStorage secureStorage;

    setUpAll(() async {
      // Create temporary directory for test database
      tempDir = await Directory.systemTemp.createTemp('libspiffy_test_');
    });

    setUp(() async {
      // Initialize Isar database for each test
      await Isar.initializeIsarCore(download: true);
      isar = await Isar.open(
        [EventEnvelopeSchema, SnapshotEnvelopeSchema],
        directory: tempDir.path,
        name: 'test_${DateTime.now().millisecondsSinceEpoch}',
      );
      eventStore = IsarEventStore(isar);
      
      // Initialize services for wallet aggregate
      cryptoService = DartSVCryptoService();
      secureStorage = InMemorySecureStorage();
      
      // Register all wallet event types for deserialization
      EventRegistry.clear();
      _registerWalletEvents();
    });

    tearDown(() async {
      await isar.close();
    });

    tearDownAll(() async {
      // Clean up temporary directory
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    group('Wallet Creation and Initialization', () {
      test('should create and initialize wallet aggregate', () async {
        final wallet = BitcoinWalletAggregate(
          aggregateId: 'wallet-123',
          aggregateType: 'Wallet',
          eventStore: eventStore,
          cryptoService: cryptoService,
          secureStorage: secureStorage,
        );

        expect(wallet.aggregateId, equals('wallet-123'));
        expect(wallet.aggregateType, equals('Wallet'));
        expect(wallet.persistenceId, equals('Wallet_wallet-123'));
        expect(wallet.isInitialized, isFalse);
      });

      test('should handle wallet creation command', () async {
        final wallet = BitcoinWalletAggregate(
          aggregateId: 'wallet-123',
          aggregateType: 'Wallet',
          eventStore: eventStore,
          cryptoService: cryptoService,
          secureStorage: secureStorage,
        );

        // Start the actor to trigger recovery
        wallet.preStart();
        await Future.delayed(Duration(milliseconds: 100)); // Wait for recovery

        // Create wallet
        final createCommand = CreateWalletCommand(
          walletId: 'wallet-123',
          walletName: 'My Test Wallet',
          mnemonic: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
          walletMetadata: {'purpose': 'testing'},
        );

        await wallet.commandHandler(createCommand);

        expect(wallet.isInitialized, isTrue);
        expect(wallet.currentState.name, equals('My Test Wallet'));
        expect(wallet.currentState.isCreated, isTrue);
        expect(wallet.currentState.version, equals(1));
        expect(wallet.currentState.metadata['purpose'], equals('testing'));
      });

      test('should reject duplicate wallet creation', () async {
        final wallet = BitcoinWalletAggregate(
          aggregateId: 'wallet-123',
          aggregateType: 'Wallet',
          eventStore: eventStore,
          cryptoService: cryptoService,
          secureStorage: secureStorage,
        );

        wallet.preStart();
        await Future.delayed(Duration(milliseconds: 100));

        // Create wallet first time
        await wallet.commandHandler(CreateWalletCommand(
          walletId: 'wallet-123',
          walletName: 'My Test Wallet',
          mnemonic: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
        ));

        // Try to create again - should fail
        expect(
          () => wallet.commandHandler(CreateWalletCommand(
            walletId: 'wallet-123',
            walletName: 'Another Wallet',
            mnemonic: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
          )),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('Address Management', () {
      late BitcoinWalletAggregate wallet;

      setUp(() async {
        wallet = BitcoinWalletAggregate(
          aggregateId: 'wallet-123',
          aggregateType: 'Wallet',
          eventStore: eventStore,
          cryptoService: cryptoService,
          secureStorage: secureStorage,
        );
        wallet.preStart();
        await Future.delayed(Duration(milliseconds: 100));

        // Create wallet first
        await wallet.commandHandler(CreateWalletCommand(
          walletId: 'wallet-123',
          walletName: 'My Test Wallet',
          mnemonic: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
        ));
      });

      test('should generate new address', () async {
        final generateCommand = GenerateAddressCommand(
          walletId: 'wallet-123',
          label: 'Receiving Address',
          purpose: 'receive',
        );

        await wallet.commandHandler(generateCommand);

        expect(wallet.currentState.version, equals(2));
        // Wallet creation creates a root address (index 0), then GenerateAddressCommand creates another (index 1)
        expect(wallet.currentState.nextDerivationIndex, equals(2));
        expect(wallet.currentState.addresses, hasLength(2)); // root address + generated address
        
        // Find the labeled address (should be the one with 'Receiving Address' label)
        final labeledAddressEntry = wallet.currentState.addresses.entries
            .firstWhere((e) => e.value == 'Receiving Address');
        expect(labeledAddressEntry.key, isNotEmpty);
      });

      test('should update address label', () async {
        // Generate address first
        await wallet.commandHandler(GenerateAddressCommand(
          walletId: 'wallet-123',
          label: 'Old Label',
        ));

        final address = wallet.currentState.addresses.keys.first;

        // Update label
        final updateCommand = UpdateAddressLabelCommand(
          walletId: 'wallet-123',
          address: address,
          newLabel: 'New Label',
        );

        await wallet.commandHandler(updateCommand);

        expect(wallet.currentState.version, equals(3));
        expect(wallet.currentState.addresses[address], equals('New Label'));
      });
    });

    group('UTXO Management', () {
      late BitcoinWalletAggregate wallet;

      setUp(() async {
        wallet = BitcoinWalletAggregate(
          aggregateId: 'wallet-123',
          aggregateType: 'Wallet',
          eventStore: eventStore,
          cryptoService: cryptoService,
          secureStorage: secureStorage,
        );
        wallet.preStart();
        await Future.delayed(Duration(milliseconds: 100));

        // Create wallet
        await wallet.commandHandler(CreateWalletCommand(
          walletId: 'wallet-123',
          walletName: 'My Test Wallet',
          mnemonic: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
        ));

        // Generate an address
        await wallet.commandHandler(GenerateAddressCommand(
          walletId: 'wallet-123',
          label: 'Receiving Address',
        ));
      });

      test('should receive UTXO', () async {
        final address = wallet.currentState.addresses.keys.first;
        
        final receiveCommand = ReceiveUTXOCommand(
          walletId: 'wallet-123',
          txid: '0000000000000000000000000000000000000000000000000000000000000123',
          vout: 0,
          satoshis: BigInt.from(100000), // 0.001 BTC
          scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
          address: address,
          blockHeight: 800000,
          confirmations: 1,
        );

        await wallet.commandHandler(receiveCommand);

        expect(wallet.currentState.version, equals(3));
        expect(wallet.currentState.utxos, hasLength(1));
        
        final utxo = wallet.currentState.utxos['0000000000000000000000000000000000000000000000000000000000000123:0'];
        expect(utxo, isNotNull);
        expect(utxo!.txid, equals('0000000000000000000000000000000000000000000000000000000000000123'));
        expect(utxo.vout, equals(0));
        expect(utxo.satoshis, equals(BigInt.from(100000)));
        expect(utxo.address, equals(address));
        expect(utxo.status, equals(UTXOStatus.pending)); // New UTXOs start as pending
        expect(utxo.confirmations, equals(1));
      });

      test('should update UTXO confirmations', () async {
        final address = wallet.currentState.addresses.keys.first;
        
        // Receive UTXO first
        await wallet.commandHandler(ReceiveUTXOCommand(
          walletId: 'wallet-123',
          txid: '0000000000000000000000000000000000000000000000000000000000000123',
          vout: 0,
          satoshis: BigInt.from(100000),
          scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
          address: address,
          blockHeight: 800000,
          confirmations: 1,
        ));

        // Update confirmations
        final updateCommand = UpdateUTXOConfirmationsCommand(
          walletId: 'wallet-123',
          utxoKey: '0000000000000000000000000000000000000000000000000000000000000123:0',
          confirmations: 6,
          blockHeight: 800005,
        );

        await wallet.commandHandler(updateCommand);

        expect(wallet.currentState.version, equals(4));
        final utxo = wallet.currentState.utxos['0000000000000000000000000000000000000000000000000000000000000123:0'];
        expect(utxo!.confirmations, equals(6));
        expect(utxo.blockHeight, equals(800005));
      });

      test('should spend UTXO', () async {
        final address = wallet.currentState.addresses.keys.first;
        
        // Receive UTXO first (starts as pending)
        await wallet.commandHandler(ReceiveUTXOCommand(
          walletId: 'wallet-123',
          txid: '0000000000000000000000000000000000000000000000000000000000000123',
          vout: 0,
          satoshis: BigInt.from(100000),
          scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
          address: address,
          confirmations: 0,
        ));

        // Confirm the UTXO to make it available for spending
        await wallet.commandHandler(UpdateUTXOConfirmationsCommand(
          walletId: 'wallet-123',
          utxoKey: '0000000000000000000000000000000000000000000000000000000000000123:0',
          confirmations: 6,
          blockHeight: 800000,
        ));

        // Spend UTXO
        final spendCommand = SpendUTXOCommand(
          walletId: 'wallet-123',
          utxoKey: '0000000000000000000000000000000000000000000000000000000000000123:0',
          spendingTxId: 'tx456',
          fee: BigInt.from(500),
        );

        await wallet.commandHandler(spendCommand);

        expect(wallet.currentState.version, equals(5)); // +1 for confirmation update
        final utxo = wallet.currentState.utxos['0000000000000000000000000000000000000000000000000000000000000123:0'];
        expect(utxo!.status, equals(UTXOStatus.spent));
      });

      test('should reject spending unavailable UTXO', () async {
        // Try to spend non-existent UTXO
        final spendCommand = SpendUTXOCommand(
          walletId: 'wallet-123',
          utxoKey: 'nonexistent:0',
          spendingTxId: 'tx456',
          fee: BigInt.from(500),
        );

        expect(
          () => wallet.commandHandler(spendCommand),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('Transaction Operations', () {
      late BitcoinWalletAggregate wallet;

      setUp(() async {
        wallet = BitcoinWalletAggregate(
          aggregateId: 'wallet-123',
          aggregateType: 'Wallet',
          eventStore: eventStore,
          cryptoService: cryptoService,
          secureStorage: secureStorage,
        );
        wallet.preStart();
        await Future.delayed(Duration(milliseconds: 100));

        // Create wallet with UTXO
        await wallet.commandHandler(CreateWalletCommand(
          walletId: 'wallet-123',
          walletName: 'My Test Wallet',
          mnemonic: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
        ));

        await wallet.commandHandler(GenerateAddressCommand(
          walletId: 'wallet-123',
          label: 'Receiving Address',
        ));

        final address = wallet.currentState.addresses.keys.first;
        // Derive the correct P2PKH scriptPubKey from the wallet's actual address
        final decodedAddress = dartsv.Address.fromBase58(address);
        final pubKeyHash = decodedAddress.pubkeyHash160; // Already a hex string
        final validScriptPubKey = '76a914${pubKeyHash}88ac'; // OP_DUP OP_HASH160 <pubkeyhash> OP_EQUALVERIFY OP_CHECKSIG
        await wallet.commandHandler(ReceiveUTXOCommand(
          walletId: 'wallet-123',
          txid: '0000000000000000000000000000000000000000000000000000000000000123',
          vout: 0,
          satoshis: BigInt.from(100000),
          scriptPubKey: validScriptPubKey,
          address: address,
          confirmations: 0,
        ));

        // Confirm the UTXO to make it available for transactions
        await wallet.commandHandler(UpdateUTXOConfirmationsCommand(
          walletId: 'wallet-123',
          utxoKey: '0000000000000000000000000000000000000000000000000000000000000123:0',
          confirmations: 6,
          blockHeight: 800000,
        ));
      });

      test('should create transaction', () async {
        final createTxCommand = CreateTransactionCommand(
          walletId: 'wallet-123',
          transactionId: 'tx456',
          outputs: [
            TransactionOutput(
              address: '1RecipientAddress',
              satoshis: BigInt.from(50000),
            ),
          ],
          transactionMetadata: {'purpose': 'payment'},
        );

        await wallet.commandHandler(createTxCommand);

        expect(wallet.currentState.version, equals(5)); // +1 for UTXO confirmation in setUp
        // Transaction creation is a placeholder in current implementation
        // In Phase 1D, this will integrate with actual transaction building
      });

      test('should sign transaction', () async {
        // Create transaction first
        await wallet.commandHandler(CreateTransactionCommand(
          walletId: 'wallet-123',
          transactionId: 'tx456',
          outputs: [
            TransactionOutput(
              address: '1RecipientAddress',
              satoshis: BigInt.from(50000),
            ),
          ],
        ));

        // A minimal valid unsigned transaction hex (version 1, 1 input, 1 output, locktime 0)
        const validUnsignedTxHex = '0100000001'  // version + input count
            '0000000000000000000000000000000000000000000000000000000000000000'  // prev txid (32 bytes)
            '00000000'  // prev vout
            '00'  // empty script
            'ffffffff'  // sequence
            '01'  // output count
            '50c3000000000000'  // 50000 satoshis (little endian)
            '00'  // empty output script
            '00000000';  // locktime

        final signCommand = SignTransactionCommand(
          walletId: 'wallet-123',
          transactionId: 'tx456',
          rawTransaction: validUnsignedTxHex,
          utxoKeys: ['0000000000000000000000000000000000000000000000000000000000000123:0'],
          publicKeys: []
        );

        await wallet.commandHandler(signCommand);

        expect(wallet.currentState.version, equals(6)); // setUp(4) + create(1 with UTXOReserved counted together) + sign(1) = 6
        // Signing logic is placeholder - will be implemented in Phase 1D
      });

      test('should broadcast transaction', () async {
        // A minimal valid transaction hex
        const validTxHex = '0100000001'
            '0000000000000000000000000000000000000000000000000000000000000000'
            '00000000'
            '00'
            'ffffffff'
            '01'
            '50c3000000000000'
            '00'
            '00000000';

        // Create and sign transaction first
        await wallet.commandHandler(CreateTransactionCommand(
          walletId: 'wallet-123',
          transactionId: 'tx456',
          outputs: [
            TransactionOutput(
              address: '1RecipientAddress',
              satoshis: BigInt.from(50000),
            ),
          ],
        ));

        await wallet.commandHandler(SignTransactionCommand(
          walletId: 'wallet-123',
          transactionId: 'tx456',
          rawTransaction: validTxHex,
          utxoKeys: ['0000000000000000000000000000000000000000000000000000000000000123:0'],
          publicKeys: []
        ));

        final broadcastCommand = BroadcastTransactionCommand(
          walletId: 'wallet-123',
          transactionId: 'tx456',
          signedTransaction: validTxHex,
        );

        await wallet.commandHandler(broadcastCommand);

        expect(wallet.currentState.version, equals(7)); // setUp(4) + create(1) + sign(1) + broadcast(1)
        // Broadcasting logic is placeholder - will be implemented in Phase 1D
      });
    });

    group('State Recovery and Persistence', () {
      test('should recover state after restart', () async {
        // Create and operate on wallet
        var wallet = BitcoinWalletAggregate(
          aggregateId: 'wallet-123',
          aggregateType: 'Wallet',
          eventStore: eventStore,
          cryptoService: cryptoService,
          secureStorage: secureStorage,
        );
        wallet.preStart();
        await Future.delayed(Duration(milliseconds: 100));

        // Perform operations
        await wallet.commandHandler(CreateWalletCommand(
          walletId: 'wallet-123',
          walletName: 'Recovery Test Wallet',
          mnemonic: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
        ));

        await wallet.commandHandler(GenerateAddressCommand(
          walletId: 'wallet-123',
          label: 'Test Address',
        ));

        final address = wallet.currentState.addresses.keys.first;
        await wallet.commandHandler(ReceiveUTXOCommand(
          walletId: 'wallet-123',
          txid: '0000000000000000000000000000000000000000000000000000000000000123',
          vout: 0,
          satoshis: BigInt.from(100000),
          scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
          address: address,
          confirmations: 1,
        ));

        // Store state before restart
        final originalVersion = wallet.currentState.version;
        final originalName = wallet.currentState.name;
        final originalAddresses = wallet.currentState.addresses;
        final originalUtxos = wallet.currentState.utxos;

        // Simulate restart - create new wallet instance
        wallet = BitcoinWalletAggregate(
          aggregateId: 'wallet-123',
          aggregateType: 'Wallet',
          eventStore: eventStore,
          cryptoService: cryptoService,
          secureStorage: secureStorage,
        );
        wallet.preStart(); // Triggers recovery
        await Future.delayed(Duration(milliseconds: 200)); // Wait for recovery

        // Verify state recovered correctly
        expect(wallet.isInitialized, isTrue);
        expect(wallet.currentState.version, equals(originalVersion));
        expect(wallet.currentState.name, equals(originalName));
        expect(wallet.currentState.addresses, equals(originalAddresses));
        expect(wallet.currentState.utxos.length, equals(originalUtxos.length));
        
        final recoveredUtxo = wallet.currentState.utxos['0000000000000000000000000000000000000000000000000000000000000123:0'];
        final originalUtxo = originalUtxos['0000000000000000000000000000000000000000000000000000000000000123:0'];
        expect(recoveredUtxo?.txid, equals(originalUtxo?.txid));
        expect(recoveredUtxo?.satoshis, equals(originalUtxo?.satoshis));
      });
    });

    group('Business Rule Validation', () {
      late BitcoinWalletAggregate wallet;

      setUp(() async {
        wallet = BitcoinWalletAggregate(
          aggregateId: 'wallet-123',
          aggregateType: 'Wallet',
          eventStore: eventStore,
          cryptoService: cryptoService,
          secureStorage: secureStorage,
        );
        wallet.preStart();
        await Future.delayed(Duration(milliseconds: 100));
      });

      test('should reject operations on non-existent wallet', () async {
        // Try to generate address without creating wallet
        final generateCommand = GenerateAddressCommand(
          walletId: 'wallet-123',
          label: 'Test Address',
        );

        expect(
          () => wallet.commandHandler(generateCommand),
          throwsA(isA<StateError>()),
        );
      });

      test('should reject UTXO operations on non-existent wallet', () async {
        // Try to receive UTXO without creating wallet
        final receiveCommand = ReceiveUTXOCommand(
          walletId: 'wallet-123',
          txid: '0000000000000000000000000000000000000000000000000000000000000123',
          vout: 0,
          satoshis: BigInt.from(100000),
          scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
          address: '1TestAddress',
        );

        expect(
          () => wallet.commandHandler(receiveCommand),
          throwsA(isA<StateError>()),
        );
      });

      test('should reject transaction operations on non-existent wallet', () async {
        // Try to create transaction without creating wallet
        final createTxCommand = CreateTransactionCommand(
          walletId: 'wallet-123',
          transactionId: 'tx456',
          outputs: [
            TransactionOutput(
              address: '1RecipientAddress',  
              satoshis: BigInt.from(50000),
            ),
          ],
        );

        expect(
          () => wallet.commandHandler(createTxCommand),
          throwsA(isA<StateError>()),
        );
      });
    });
  });
}

/// Register all wallet event types for deserialization during testing
void _registerWalletEvents() {
  EventRegistry.register<WalletCreatedEvent>(
    'WalletCreatedEvent',
    WalletCreatedEvent.fromMap,
  );
  EventRegistry.register<WalletConfigurationUpdatedEvent>(
    'WalletConfigurationUpdatedEvent',
    WalletConfigurationUpdatedEvent.fromMap,
  );
  EventRegistry.register<AddressGeneratedEvent>(
    'AddressGeneratedEvent',
    AddressGeneratedEvent.fromMap,
  );
  EventRegistry.register<AddressLabelUpdatedEvent>(
    'AddressLabelUpdatedEvent',
    AddressLabelUpdatedEvent.fromMap,
  );
  EventRegistry.register<UTXOReceivedEvent>(
    'UTXOReceivedEvent',
    UTXOReceivedEvent.fromMap,
  );
  EventRegistry.register<UTXOSpentEvent>(
    'UTXOSpentEvent',
    UTXOSpentEvent.fromMap,
  );
  EventRegistry.register<UTXOConfirmationUpdatedEvent>(
    'UTXOConfirmationUpdatedEvent',
    UTXOConfirmationUpdatedEvent.fromMap,
  );
  EventRegistry.register<TransactionCreatedEvent>(
    'TransactionCreatedEvent',
    TransactionCreatedEvent.fromMap,
  );
  EventRegistry.register<TransactionSignedEvent>(
    'TransactionSignedEvent',
    TransactionSignedEvent.fromMap,
  );
  EventRegistry.register<TransactionBroadcastEvent>(
    'TransactionBroadcastEvent',
    TransactionBroadcastEvent.fromMap,
  );
  EventRegistry.register<UTXOReservationPlacedEvent>(
    'UTXOReservationPlacedEvent',
    UTXOReservationPlacedEvent.fromMap,
  );
  EventRegistry.register<UTXOReservationReleasedEvent>(
    'UTXOReservationReleasedEvent',
    UTXOReservationReleasedEvent.fromMap,
  );
  EventRegistry.register<UTXOReservationExpiredEvent>(
    'UTXOReservationExpiredEvent',
    UTXOReservationExpiredEvent.fromMap,
  );
} 