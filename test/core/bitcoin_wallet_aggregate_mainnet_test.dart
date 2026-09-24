import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

/// Mainnet behaviour of BitcoinWalletAggregate.
///
/// Lives in its own file because ScriptTypeRegistry is a process-wide
/// singleton pinned to the first network it is constructed with; the other
/// aggregate tests are all testnet.
///
/// Audit 2026-09-14 KM-3 / H1: the aggregate compared the network string
/// against 'mainnet' in some places and 'main' in others, so a wallet
/// created with 'main' derived testnet addresses, and a 'mainnet' wallet
/// decoded its own change outputs with the testnet prefix and never
/// recorded them.
void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  const externalMainnetAddress = '1BitcoinEaterAddressDontSendf59kuE';

  late DartSVCryptoService cryptoService;
  late InMemorySecureStorage secureStorage;

  setUp(() {
    cryptoService = DartSVCryptoService();
    secureStorage = InMemorySecureStorage();
  });

  Future<BitcoinWalletAggregate> createWallet(String walletId, String network) async {
    final wallet = BitcoinWalletAggregate(
      aggregateId: walletId,
      aggregateType: 'Wallet',
      eventStore: _NoopEventStore(),
      cryptoService: cryptoService,
      secureStorage: secureStorage,
    );
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(
      walletId: walletId,
      walletName: 'Mainnet wallet',
      mnemonic: mnemonic,
      walletMetadata: {'network': network},
    ));
    return wallet;
  }

  // A label is required: _getPrivateKeyForAddress treats a null label in
  // the addresses map as "address not found" (addresses[address] == null).
  Future<String> generateAddress(BitcoinWalletAggregate wallet) async {
    final before = wallet.currentState.addresses.keys.toSet();
    await wallet.commandHandler(GenerateAddressCommand(walletId: wallet.aggregateId, label: 'change'));
    return wallet.currentState.addresses.keys.firstWhere((a) => !before.contains(a));
  }

  /// One dummy input, one P2PKH output to [address].
  dartsv.Transaction paymentTo(String address, int satoshis, {String? inputTxid, int inputVout = 0}) {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput(
      inputTxid ?? 'a' * 64,
      inputVout,
      dartsv.TransactionInput.MAX_SEQ_NUMBER,
    ));
    final script = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey();
    tx.outputs.add(dartsv.TransactionOutput(BigInt.from(satoshis), script));
    return tx;
  }

  group('BitcoinWalletAggregate on mainnet (audit KM-3 / H1)', () {
    test("wallet created with network 'main' derives mainnet addresses", () async {
      final wallet = await createWallet('main-spelling', 'main');

      expect(wallet.currentState.rootAddress, startsWith('1'),
          reason: 'mainnet P2PKH addresses start with 1');
      final generated = await generateAddress(wallet);
      expect(generated, startsWith('1'));
      expect(wallet.currentState.networkType, equals('mainnet'),
          reason: 'the canonical spelling is persisted');

      final hdPub = cryptoService.deriveHDPublicKey(
        await cryptoService.mnemonicToHDPrivateKey(mnemonic, network: dartsv.NetworkType.MAIN),
      );
      expect(wallet.currentState.rootAddress,
          equals(cryptoService.deriveAddress(hdPub, 0, network: dartsv.NetworkType.MAIN)));
      expect(generated,
          equals(cryptoService.deriveAddress(hdPub, 1, network: dartsv.NetworkType.MAIN)));
    });

    test("wallet created with network 'mainnet' records its own outputs when scanning a transaction", () async {
      final wallet = await createWallet('mainnet-scan', 'mainnet');
      final changeAddress = await generateAddress(wallet);
      expect(changeAddress, startsWith('1'));

      final tx = paymentTo(changeAddress, 40000);
      await wallet.commandHandler(RecordOutgoingTransactionCommand(
        walletId: wallet.aggregateId,
        txid: tx.id,
        rawHex: tx.serialize(),
        totalInputSats: 41000,
        totalOutputSats: 40000,
        fee: 1000,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: const [],
        recipientAddresses: const [],
        paymentAmount: BigInt.zero,
        changeAddress: changeAddress,
        changeAmount: BigInt.from(40000),
      ));

      final utxo = wallet.currentState.utxos['${tx.id}:0'];
      expect(utxo, isNotNull, reason: 'the change output pays a wallet address and must become a UTXO');
      expect(utxo!.address, equals(changeAddress));
      expect(utxo.satoshis, equals(BigInt.from(40000)));
    });

    test('mainnet wallet can sign after its outputs have been scanned', () async {
      // Output scanning constructs ScriptTypeRegistry for mainnet; signing
      // must use the same network or the singleton refuses to reinitialise.
      final wallet = await createWallet('mainnet-sign', 'mainnet');
      final address = await generateAddress(wallet);
      final funding = paymentTo(address, 100000);
      await wallet.commandHandler(RecordOutgoingTransactionCommand(
        walletId: wallet.aggregateId,
        txid: funding.id,
        rawHex: funding.serialize(),
        totalInputSats: 101000,
        totalOutputSats: 100000,
        fee: 1000,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: const [],
        recipientAddresses: const [],
        paymentAmount: BigInt.zero,
        changeAddress: address,
        changeAmount: BigInt.from(100000),
      ));
      final utxoKey = '${funding.id}:0';
      expect(wallet.currentState.utxos[utxoKey], isNotNull);
      // ARC/SPV saw the funding transaction on the network. This, not a
      // confirmation count a caller reports, is what makes an output
      // spendable (bead libspiffy-8oaq).
      await wallet.commandHandler(MarkUTXOAvailableCommand(
        walletId: wallet.aggregateId,
        txid: funding.id,
        vout: 0,
      ));
      expect(wallet.currentState.utxos[utxoKey]!.status, equals(UTXOStatus.available));

      final spend = paymentTo(externalMainnetAddress, 99000, inputTxid: funding.id, inputVout: 0);
      final versionBefore = wallet.currentState.version;
      await wallet.commandHandler(SignTransactionCommand(
        walletId: wallet.aggregateId,
        transactionId: spend.id,
        rawTransaction: spend.serialize(),
        utxoKeys: [utxoKey],
        publicKeys: const [],
      ));
      expect(wallet.currentState.version, equals(versionBefore + 1));
    });
  });
}

class _NoopEventStore implements EventStore {
  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async {}

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async {}

  @override
  Future<List<Event>> getEvents(String persistenceId, {int fromSequence = 0, int? toSequence}) async => [];

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async => 0;

  @override
  Future<void> saveSnapshot(String persistenceId, dynamic state, int sequenceNumber) async {}

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async => null;

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}
