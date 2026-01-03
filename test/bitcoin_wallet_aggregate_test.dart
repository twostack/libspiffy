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

    group('RecordOutgoingTransaction - Output Scanning', () {
      late BitcoinWalletAggregate wallet;
      late String walletAddress1;
      late String walletAddress2;
      late String externalAddress;

      setUp(() async {
        wallet = BitcoinWalletAggregate(
          aggregateId: 'wallet-456',
          aggregateType: 'Wallet',
          eventStore: eventStore,
          cryptoService: cryptoService,
          secureStorage: secureStorage,
        );
        wallet.preStart();
        await Future.delayed(Duration(milliseconds: 100));

        // Create wallet
        await wallet.commandHandler(CreateWalletCommand(
          walletId: 'wallet-456',
          walletName: 'Output Scan Test Wallet',
          mnemonic: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
        ));

        // Generate two addresses for testing
        await wallet.commandHandler(GenerateAddressCommand(
          walletId: 'wallet-456',
          label: 'Address 1',
        ));
        await wallet.commandHandler(GenerateAddressCommand(
          walletId: 'wallet-456',
          label: 'Address 2',
        ));

        final addresses = wallet.currentState.addresses.keys.toList();
        walletAddress1 = addresses[0];
        walletAddress2 = addresses[1];
        
        // Use a valid external address for testnet
        externalAddress = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF'; // Valid testnet address
      });

      test('should create UTXOs for all P2PKH outputs belonging to wallet', () async {
        // Build a transaction with 3 outputs:
        // - Output 0: to external address (50000 sats)
        // - Output 1: to wallet address 1 (30000 sats)
        // - Output 2: to wallet address 2 (19000 sats)
        // Total: 99000 sats + 1000 sat fee = 100000 sats input
        
        final tx = dartsv.Transaction();
        tx.version = 1;
        tx.nLockTime = 0;
        
        // Add a dummy input
        tx.inputs.add(dartsv.TransactionInput(
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          0,
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
        ));
        
        // Output 0: External address
        final externalAddr = dartsv.Address.fromBase58(externalAddress);
        final externalScript = dartsv.P2PKHLockBuilder.fromAddress(externalAddr).getScriptPubkey();
        tx.outputs.add(dartsv.TransactionOutput(BigInt.from(50000), externalScript));
        
        // Output 1: Wallet address 1
        final addr1 = dartsv.Address.fromBase58(walletAddress1);
        final script1 = dartsv.P2PKHLockBuilder.fromAddress(addr1).getScriptPubkey();
        tx.outputs.add(dartsv.TransactionOutput(BigInt.from(30000), script1));
        
        // Output 2: Wallet address 2
        final addr2 = dartsv.Address.fromBase58(walletAddress2);
        final script2 = dartsv.P2PKHLockBuilder.fromAddress(addr2).getScriptPubkey();
        tx.outputs.add(dartsv.TransactionOutput(BigInt.from(19000), script2));
        
        final txHex = tx.serialize();
        final txid = tx.id;
        
        // Record the transaction
        final recordCommand = RecordOutgoingTransactionCommand(
          walletId: 'wallet-456',
          txid: txid,
          rawHex: txHex,
          totalInputSats: 100000,
          totalOutputSats: 99000,
          fee: 1000,
          numInputs: 1,
          numOutputs: 3,
          txVersion: 1,
          txLockTime: 0,
          spentUtxoKeys: ['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:0'],
          recipientAddresses: [externalAddress],
          paymentAmount: BigInt.from(50000),
          changeAddress: null,
          changeAmount: null,
        );
        
        await wallet.commandHandler(recordCommand);
        
        // Should create UTXOs for outputs 1 and 2 (wallet addresses)
        expect(wallet.currentState.utxos, hasLength(2));
        
        final utxo1 = wallet.currentState.utxos['$txid:1'];
        expect(utxo1, isNotNull);
        expect(utxo1!.address, equals(walletAddress1));
        expect(utxo1.satoshis, equals(BigInt.from(30000)));
        expect(utxo1.status, equals(UTXOStatus.pending));
        
        final utxo2 = wallet.currentState.utxos['$txid:2'];
        expect(utxo2, isNotNull);
        expect(utxo2!.address, equals(walletAddress2));
        expect(utxo2.satoshis, equals(BigInt.from(19000)));
        expect(utxo2.status, equals(UTXOStatus.pending));
      });

      test('should handle transaction with only external outputs', () async {
        // Build a transaction with only external outputs
        final tx = dartsv.Transaction();
        tx.version = 1;
        tx.nLockTime = 0;
        
        tx.inputs.add(dartsv.TransactionInput(
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          0,
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
        ));
        
        // Only external output
        final externalAddr = dartsv.Address.fromBase58(externalAddress);
        final externalScript = dartsv.P2PKHLockBuilder.fromAddress(externalAddr).getScriptPubkey();
        tx.outputs.add(dartsv.TransactionOutput(BigInt.from(99000), externalScript));
        
        final txHex = tx.serialize();
        final txid = tx.id;
        
        final recordCommand = RecordOutgoingTransactionCommand(
          walletId: 'wallet-456',
          txid: txid,
          rawHex: txHex,
          totalInputSats: 100000,
          totalOutputSats: 99000,
          fee: 1000,
          numInputs: 1,
          numOutputs: 1,
          txVersion: 1,
          txLockTime: 0,
          spentUtxoKeys: ['bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:0'],
          recipientAddresses: [externalAddress],
          paymentAmount: BigInt.from(99000),
          changeAddress: null,
          changeAmount: null,
        );
        
        await wallet.commandHandler(recordCommand);
        
        // Should not create any UTXOs (all outputs are external)
        expect(wallet.currentState.utxos, hasLength(0));
      });

      test('should handle P2PK outputs to wallet', () async {
        // Generate a new keypair for this test
        final testPrivKey = dartsv.SVPrivateKey();
        final testPubKey = testPrivKey.publicKey;
        final testAddress = dartsv.Address.fromPublicKey(testPubKey, dartsv.NetworkType.TEST).toBase58();
        
        // Add this address to the wallet manually
        wallet.currentState.addresses[testAddress] = 'P2PK Test Address';
        
        // Build transaction with P2PK output using P2PKLockBuilder
        final tx = dartsv.Transaction();
        tx.version = 1;
        tx.nLockTime = 0;
        
        tx.inputs.add(dartsv.TransactionInput(
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
          0,
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
        ));
        
        // P2PK output using P2PKLockBuilder
        final p2pkLockBuilder = dartsv.P2PKLockBuilder(testPubKey);
        final p2pkScript = p2pkLockBuilder.getScriptPubkey();
        tx.outputs.add(dartsv.TransactionOutput(BigInt.from(50000), p2pkScript));
        
        final txHex = tx.serialize();
        final txid = tx.id;
        
        final recordCommand = RecordOutgoingTransactionCommand(
          walletId: 'wallet-456',
          txid: txid,
          rawHex: txHex,
          totalInputSats: 51000,
          totalOutputSats: 50000,
          fee: 1000,
          numInputs: 1,
          numOutputs: 1,
          txVersion: 1,
          txLockTime: 0,
          spentUtxoKeys: ['cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc:0'],
          recipientAddresses: [],
          paymentAmount: BigInt.from(50000),
          changeAddress: null,
          changeAmount: null,
        );
        
        await wallet.commandHandler(recordCommand);
        
        // Should create UTXO for P2PK output
        expect(wallet.currentState.utxos, hasLength(1));
        
        final utxo = wallet.currentState.utxos['$txid:0'];
        expect(utxo, isNotNull);
        expect(utxo!.address, equals(testAddress));
        expect(utxo.satoshis, equals(BigInt.from(50000)));
      });

      test('should handle P2MS multisig outputs where wallet has one key', () async {
        // Generate two keypairs - one for wallet, one external
        final walletPrivKey = dartsv.SVPrivateKey();
        final walletPubKey = walletPrivKey.publicKey;
        final walletAddr = dartsv.Address.fromPublicKey(walletPubKey, dartsv.NetworkType.TEST).toBase58();
        
        final externalPrivKey = dartsv.SVPrivateKey();
        final externalPubKey = externalPrivKey.publicKey;
        
        // Add wallet address
        wallet.currentState.addresses[walletAddr] = 'Multisig Key';
        
        // Build transaction with 2-of-2 multisig output
        final tx = dartsv.Transaction();
        tx.version = 1;
        tx.nLockTime = 0;
        
        tx.inputs.add(dartsv.TransactionInput(
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
          0,
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
        ));
        
        // Create 2-of-2 multisig script
        final lockBuilder = dartsv.P2MSLockBuilder(
          [walletPubKey, externalPubKey],
          2,
          sorting: true,
        );
        final multisigScript = lockBuilder.getScriptPubkey();
        tx.outputs.add(dartsv.TransactionOutput(BigInt.from(100000), multisigScript));
        
        final txHex = tx.serialize();
        final txid = tx.id;
        
        final recordCommand = RecordOutgoingTransactionCommand(
          walletId: 'wallet-456',
          txid: txid,
          rawHex: txHex,
          totalInputSats: 101000,
          totalOutputSats: 100000,
          fee: 1000,
          numInputs: 1,
          numOutputs: 1,
          txVersion: 1,
          txLockTime: 0,
          spentUtxoKeys: ['dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd:0'],
          recipientAddresses: [],
          paymentAmount: BigInt.from(100000),
          changeAddress: null,
          changeAmount: null,
        );
        
        await wallet.commandHandler(recordCommand);
        
        // Should create UTXO for multisig output since wallet has one of the keys
        expect(wallet.currentState.utxos, hasLength(1));
        
        final utxo = wallet.currentState.utxos['$txid:0'];
        expect(utxo, isNotNull);
        expect(utxo!.address, equals(walletAddr));
        expect(utxo.satoshis, equals(BigInt.from(100000)));
      });

      test('should handle settlement-like transaction (payment channel)', () async {
        // Simulate a payment channel settlement where:
        // - Input: 2-of-2 multisig UTXO (funded channel)
        // - Output 0: Server payment (wallet address 1)
        // - Output 1: Client refund (external address)
        
        final tx = dartsv.Transaction();
        tx.version = 1;
        tx.nLockTime = 0;
        
        // Input from multisig funding
        tx.inputs.add(dartsv.TransactionInput(
          'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
          0,
          1, // sequence number 1 (settlement tx)
        ));
        
        // Output 0: Server payment (to wallet)
        final addr1 = dartsv.Address.fromBase58(walletAddress1);
        final script1 = dartsv.P2PKHLockBuilder.fromAddress(addr1).getScriptPubkey();
        tx.outputs.add(dartsv.TransactionOutput(BigInt.from(70000), script1));
        
        // Output 1: Client refund (external)
        final externalAddr = dartsv.Address.fromBase58(externalAddress);
        final externalScript = dartsv.P2PKHLockBuilder.fromAddress(externalAddr).getScriptPubkey();
        tx.outputs.add(dartsv.TransactionOutput(BigInt.from(29000), externalScript));
        
        final txHex = tx.serialize();
        final txid = tx.id;
        
        // Record as settlement transaction
        final recordCommand = RecordOutgoingTransactionCommand(
          walletId: 'wallet-456',
          txid: txid,
          rawHex: txHex,
          totalInputSats: 100000,
          totalOutputSats: 99000,
          fee: 1000,
          numInputs: 1,
          numOutputs: 2,
          txVersion: 1,
          txLockTime: 0,
          spentUtxoKeys: ['eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee:0'],
          recipientAddresses: [],
          paymentAmount: BigInt.zero, // Settlement, not a regular payment
          changeAddress: null, // No change - explicit settlement
          changeAmount: null,
        );
        
        await wallet.commandHandler(recordCommand);
        
        // Should create UTXO for the server payment output
        expect(wallet.currentState.utxos, hasLength(1));
        
        final utxo = wallet.currentState.utxos['$txid:0'];
        expect(utxo, isNotNull);
        expect(utxo!.address, equals(walletAddress1));
        expect(utxo.satoshis, equals(BigInt.from(70000)));
        expect(utxo.status, equals(UTXOStatus.pending));
      });

      test('should mark spent UTXOs and create wallet UTXOs in same transaction', () async {
        // First, give wallet a UTXO to spend
        final initialUtxoKey = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff:0';
        await wallet.commandHandler(ReceiveUTXOCommand(
          walletId: 'wallet-456',
          txid: 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
          vout: 0,
          satoshis: BigInt.from(100000),
          scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(
            dartsv.Address.fromBase58(walletAddress1)
          ).getScriptPubkey().toHex(),
          address: walletAddress1,
          confirmations: 6,
        ));
        
        // Build transaction that spends it and creates change
        final tx = dartsv.Transaction();
        tx.version = 1;
        tx.nLockTime = 0;
        
        tx.inputs.add(dartsv.TransactionInput(
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
          0,
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
        ));
        
        // Output 0: Payment to external (50000 sats)
        final externalAddr = dartsv.Address.fromBase58(externalAddress);
        final externalScript = dartsv.P2PKHLockBuilder.fromAddress(externalAddr).getScriptPubkey();
        tx.outputs.add(dartsv.TransactionOutput(BigInt.from(50000), externalScript));
        
        // Output 1: Change back to wallet address 2 (49000 sats)
        final addr2 = dartsv.Address.fromBase58(walletAddress2);
        final script2 = dartsv.P2PKHLockBuilder.fromAddress(addr2).getScriptPubkey();
        tx.outputs.add(dartsv.TransactionOutput(BigInt.from(49000), script2));
        
        final txHex = tx.serialize();
        final txid = tx.id;
        
        final recordCommand = RecordOutgoingTransactionCommand(
          walletId: 'wallet-456',
          txid: txid,
          rawHex: txHex,
          totalInputSats: 100000,
          totalOutputSats: 99000,
          fee: 1000,
          numInputs: 1,
          numOutputs: 2,
          txVersion: 1,
          txLockTime: 0,
          spentUtxoKeys: [initialUtxoKey],
          recipientAddresses: [externalAddress],
          paymentAmount: BigInt.from(50000),
          changeAddress: null,
          changeAmount: null,
        );
        
        await wallet.commandHandler(recordCommand);
        
        // Should have 1 UTXO (the change), and the original should be spent
        expect(wallet.currentState.utxos, hasLength(2)); // Original + new change
        
        final spentUtxo = wallet.currentState.utxos[initialUtxoKey];
        expect(spentUtxo, isNotNull);
        expect(spentUtxo!.status, equals(UTXOStatus.spent));
        
        final changeUtxo = wallet.currentState.utxos['$txid:1'];
        expect(changeUtxo, isNotNull);
        expect(changeUtxo!.address, equals(walletAddress2));
        expect(changeUtxo.satoshis, equals(BigInt.from(49000)));
        expect(changeUtxo.status, equals(UTXOStatus.pending));
      });

      test('COMPREHENSIVE: Payment channel settlement with correct UTXO attribution', () async {
        // This test validates the complete payment channel settlement flow:
        // 1. Multisig funding UTXO exists and is marked as spent
        // 2. Server payment output creates a UTXO for wallet
        // 3. Client refund output does NOT create a UTXO (external)
        // 4. Transaction metadata correctly shows client as recipient
        
        // Setup: Create a multisig funding UTXO (simulating channel funding)
        final serverPrivKey = dartsv.SVPrivateKey();
        final serverPubKey = serverPrivKey.publicKey;
        final serverAddr = dartsv.Address.fromPublicKey(serverPubKey, dartsv.NetworkType.TEST).toBase58();
        
        final clientPrivKey = dartsv.SVPrivateKey();
        final clientPubKey = clientPrivKey.publicKey;
        final clientAddr = dartsv.Address.fromPublicKey(clientPubKey, dartsv.NetworkType.TEST).toBase58();
        
        // Add server address to wallet
        wallet.currentState.addresses[serverAddr] = 'Payment Channel Server Key';
        
        // Create the multisig funding UTXO
        final fundingTxid = 'abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd';
        final fundingVout = 1;
        final fundingAmount = 10000;
        
        final lockBuilder = dartsv.P2MSLockBuilder(
          [serverPubKey, clientPubKey],
          2,
          sorting: true,
        );
        final multisigScript = lockBuilder.getScriptPubkey();
        
        // Record the funding UTXO (2-of-2 multisig)
        await wallet.commandHandler(ReceiveUTXOCommand(
          walletId: 'wallet-456',
          txid: fundingTxid,
          vout: fundingVout,
          satoshis: BigInt.from(fundingAmount),
          scriptPubKey: multisigScript.toHex(),
          address: serverAddr, // Associated with server's key in the multisig
          confirmations: 6,
        ));
        
        // Build the settlement transaction
        // Structure:
        // - Input: The multisig funding UTXO
        // - Output 0: Server payment (2400 sats to wallet)
        // - Output 1: Client refund (7599 sats to external)
        // - Fee: 1 sat
        
        final settlementTx = dartsv.Transaction();
        settlementTx.version = 1;
        settlementTx.nLockTime = 0;
        
        // Input: Spend the multisig funding UTXO
        settlementTx.inputs.add(dartsv.TransactionInput(
          fundingTxid,
          fundingVout,
          1, // sequence number for settlement
        ));
        
        // Output 0: Server payment (to wallet)
        final serverScript = dartsv.P2PKHLockBuilder.fromAddress(
          dartsv.Address.fromBase58(serverAddr)
        ).getScriptPubkey();
        settlementTx.outputs.add(dartsv.TransactionOutput(BigInt.from(2400), serverScript));
        
        // Output 1: Client refund (external)
        final clientScript = dartsv.P2PKHLockBuilder.fromAddress(
          dartsv.Address.fromBase58(clientAddr)
        ).getScriptPubkey();
        settlementTx.outputs.add(dartsv.TransactionOutput(BigInt.from(7599), clientScript));
        
        final settlementTxHex = settlementTx.serialize();
        final settlementTxid = settlementTx.id;
        
        // Record the settlement transaction (as done by payment channel coordinator)
        final recordCommand = RecordOutgoingTransactionCommand(
          walletId: 'wallet-456',
          txid: settlementTxid,
          rawHex: settlementTxHex,
          totalInputSats: fundingAmount,
          totalOutputSats: 9999,
          fee: 1,
          numInputs: 1,
          numOutputs: 2,
          txVersion: 1,
          txLockTime: 0,
          spentUtxoKeys: ['$fundingTxid:$fundingVout'],
          recipientAddresses: [clientAddr], // Client is the recipient
          paymentAmount: BigInt.from(7599), // Amount sent to client
          changeAddress: null,
          changeAmount: null,
        );
        
        await wallet.commandHandler(recordCommand);
        
        // VALIDATIONS
        
        // 1. The multisig funding UTXO should be marked as spent
        final fundingUtxo = wallet.currentState.utxos['$fundingTxid:$fundingVout'];
        expect(fundingUtxo, isNotNull, reason: 'Funding UTXO should exist');
        expect(fundingUtxo!.status, equals(UTXOStatus.spent), 
            reason: 'Funding UTXO should be marked as spent');
        
        // 2. Server payment output should create a UTXO for the wallet
        final serverPaymentUtxo = wallet.currentState.utxos['$settlementTxid:0'];
        expect(serverPaymentUtxo, isNotNull, 
            reason: 'Server payment UTXO should be created');
        expect(serverPaymentUtxo!.address, equals(serverAddr),
            reason: 'Server payment UTXO should belong to wallet address');
        expect(serverPaymentUtxo.satoshis, equals(BigInt.from(2400)),
            reason: 'Server payment UTXO should have correct amount');
        expect(serverPaymentUtxo.status, equals(UTXOStatus.pending),
            reason: 'New UTXO should start as pending');
        
        // 3. Client refund output should NOT create a UTXO (it's external)
        final clientRefundUtxo = wallet.currentState.utxos['$settlementTxid:1'];
        expect(clientRefundUtxo, isNull,
            reason: 'Client refund UTXO should NOT be created (external address)');
        
        // 4. Total UTXOs should be 2: spent funding + new server payment
        expect(wallet.currentState.utxos, hasLength(2),
            reason: 'Should have exactly 2 UTXOs (spent funding + new server payment)');
        
        print('✅ Payment channel settlement UTXO attribution test passed!');
        print('   - Funding UTXO correctly marked as spent');
        print('   - Server payment UTXO correctly created (2400 sats)');
        print('   - Client refund UTXO correctly NOT created (external)');
        print('   - Total UTXO count correct: ${wallet.currentState.utxos.length}');
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
  EventRegistry.register<TransactionRecordedEvent>(
    'TransactionRecordedEvent',
    TransactionRecordedEvent.fromMap,
  );
  EventRegistry.register<TransactionConfirmedEvent>(
    'TransactionConfirmedEvent',
    TransactionConfirmedEvent.fromMap,
  );
} 