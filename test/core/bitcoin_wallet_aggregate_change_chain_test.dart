import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';

/// Audit 2026-09-14 H3 (libspiffy-4sm): keys for change-chain addresses
/// were never derivable.
///
/// `GenerateAddressCommand(purpose: 'change')` derived the address on the
/// change chain (m/1/i) but the aggregate recorded only the index, and every
/// signing path derived m/0/i, so a change output the wallet itself created
/// could not be spent through the wallet.
///
/// Testnet only: ScriptTypeRegistry is a process-wide singleton pinned to
/// the first network it is built with.
void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  const externalAddress = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF'; // testnet
  const fundingTxid =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1';

  late DartSVCryptoService cryptoService;
  late InMemorySecureStorage secureStorage;
  late InMemoryEventStore eventStore;

  setUp(() {
    cryptoService = DartSVCryptoService();
    secureStorage = InMemorySecureStorage();
    eventStore = InMemoryEventStore();
    EventRegistry.clear();
    _registerWalletEvents();
  });

  Future<BitcoinWalletAggregate> openWallet(String walletId, EventStore store) async {
    final wallet = BitcoinWalletAggregate(
      aggregateId: walletId,
      aggregateType: 'Wallet',
      eventStore: store,
      cryptoService: cryptoService,
      secureStorage: secureStorage,
    );
    await wallet.preStart();
    return wallet;
  }

  Future<BitcoinWalletAggregate> createWallet(String walletId) async {
    final wallet = await openWallet(walletId, eventStore);
    await wallet.commandHandler(CreateWalletCommand(
      walletId: walletId,
      walletName: 'Change-chain wallet',
      mnemonic: mnemonic,
    ));
    return wallet;
  }

  Future<String> generateAddress(BitcoinWalletAggregate wallet, {String? purpose}) async {
    final before = wallet.currentState.addresses.keys.toSet();
    await wallet.commandHandler(GenerateAddressCommand(
      walletId: wallet.aggregateId,
      label: purpose ?? 'receive',
      purpose: purpose,
    ));
    return wallet.currentState.addresses.keys.firstWhere((a) => !before.contains(a));
  }

  String p2pkhScriptHex(String address) =>
      '76a914${dartsv.Address.fromBase58(address).pubkeyHash160}88ac';

  /// Funds [address] with a confirmed (available) P2PKH UTXO.
  Future<String> fund(BitcoinWalletAggregate wallet, String address,
      {required String txid, required int vout, required int satoshis}) async {
    await wallet.commandHandler(ReceiveUTXOCommand(
      walletId: wallet.aggregateId,
      txid: txid,
      vout: vout,
      satoshis: BigInt.from(satoshis),
      scriptPubKey: p2pkhScriptHex(address),
      address: address,
      confirmations: 0,
    ));
    final utxoKey = '$txid:$vout';
    await wallet.commandHandler(UpdateUTXOConfirmationsCommand(
      walletId: wallet.aggregateId,
      utxoKey: utxoKey,
      confirmations: 6,
      blockHeight: 800000,
    ));
    expect(wallet.currentState.utxos[utxoKey]!.status, equals(UTXOStatus.available));
    return utxoKey;
  }

  /// Unsigned transaction spending [utxoKeys] to the given address/amount
  /// outputs, in order.
  String unsignedTx(List<String> utxoKeys, Map<String, int> outputs) {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    for (final key in utxoKeys) {
      final parts = key.split(':');
      tx.inputs.add(dartsv.TransactionInput(
        parts[0],
        int.parse(parts[1]),
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
      ));
    }
    outputs.forEach((address, sats) {
      final script = dartsv.P2PKHLockBuilder.fromAddress(
        dartsv.Address.fromBase58(address),
      ).getScriptPubkey();
      tx.outputs.add(dartsv.TransactionOutput(BigInt.from(sats), script));
    });
    return tx.serialize();
  }

  Future<TransactionSignedEvent> sign(
    BitcoinWalletAggregate wallet, {
    required String id,
    required String rawTx,
    required List<String> utxoKeys,
    List<int> derivationIndices = const [],
    List<bool> isChangeFlags = const [],
  }) async {
    await wallet.commandHandler(SignTransactionCommand(
      walletId: wallet.aggregateId,
      transactionId: id,
      rawTransaction: rawTx,
      utxoKeys: utxoKeys,
      publicKeys: const [],
      derivationIndices: derivationIndices,
      isChangeFlags: isChangeFlags,
    ));
    return eventStore.journal[wallet.persistenceId]!
        .whereType<TransactionSignedEvent>()
        .last;
  }

  /// Creates a wallet, funds a receive address, generates a change address,
  /// signs and records a payment whose change goes to that address, and
  /// returns the wallet together with the now-available change UTXO.
  Future<({BitcoinWalletAggregate wallet, String changeAddress, String changeUtxoKey})>
      walletWithChangeUtxo(String walletId) async {
    final wallet = await createWallet(walletId);
    final receiveAddress = await generateAddress(wallet);
    final fundingKey = await fund(wallet, receiveAddress,
        txid: fundingTxid, vout: 0, satoshis: 100000);

    final changeAddress = await generateAddress(wallet, purpose: 'change');
    expect(changeAddress, isNot(equals(receiveAddress)));

    // The change address really is on the change chain (m/1/i).
    final changeIndex =
        (wallet.currentState.metadata['address_indices'] as Map)[changeAddress] as int;
    final hdPriv = await cryptoService.mnemonicToHDPrivateKey(mnemonic,
        network: dartsv.NetworkType.TEST);
    expect(
      cryptoService.generateChangeAddress(
        cryptoService.deriveHDPublicKey(hdPriv),
        changeIndex,
        network: dartsv.NetworkType.TEST,
      ),
      equals(changeAddress),
    );

    // Payment: 50 000 to an external address, 49 000 change, 1 000 fee.
    final signed = await sign(
      wallet,
      id: 'payment-1',
      rawTx: unsignedTx([fundingKey], {externalAddress: 50000, changeAddress: 49000}),
      utxoKeys: [fundingKey],
    );
    await wallet.commandHandler(RecordOutgoingTransactionCommand(
      walletId: walletId,
      txid: signed.txid,
      rawHex: signed.signedRawHex,
      totalInputSats: 100000,
      totalOutputSats: 99000,
      fee: 1000,
      numInputs: 1,
      numOutputs: 2,
      txVersion: 1,
      txLockTime: 0,
      spentUtxoKeys: [fundingKey],
      recipientAddresses: [externalAddress],
      paymentAmount: BigInt.from(50000),
      changeAddress: changeAddress,
      changeAmount: BigInt.from(49000),
    ));

    final changeUtxoKey = '${signed.txid}:1';
    final changeUtxo = wallet.currentState.utxos[changeUtxoKey];
    expect(changeUtxo, isNotNull, reason: 'output scanning must record the change output');
    expect(changeUtxo!.address, equals(changeAddress));
    await wallet.commandHandler(MarkUTXOAvailableCommand(
      walletId: walletId,
      txid: signed.txid,
      vout: 1,
    ));
    expect(wallet.currentState.utxos[changeUtxoKey]!.status, equals(UTXOStatus.available));
    return (wallet: wallet, changeAddress: changeAddress, changeUtxoKey: changeUtxoKey);
  }

  group('H3: change-chain keys', () {
    test('signs a transaction that spends a change output the wallet created', () async {
      final setup = await walletWithChangeUtxo('wallet-change-1');
      final wallet = setup.wallet;

      final versionBefore = wallet.currentState.version;
      // The aggregate verifies every signed input against its UTXO before
      // emitting TransactionSignedEvent; on the old code this throws
      // SCRIPT_ERR_EQUALVERIFY because m/0/i is used instead of m/1/i.
      await sign(
        wallet,
        id: 'spend-change',
        rawTx: unsignedTx([setup.changeUtxoKey], {externalAddress: 48000}),
        utxoKeys: [setup.changeUtxoKey],
      );
      expect(wallet.currentState.version, equals(versionBefore + 1));
    });

    test('records the chain alongside the index in aggregate state', () async {
      final setup = await walletWithChangeUtxo('wallet-change-2');
      final state = setup.wallet.currentState;
      final chains = state.metadata['address_chains'] as Map?;
      expect(chains, isNotNull);
      expect(chains![setup.changeAddress], isTrue);
      // Root and receive addresses are on the receive chain.
      expect(chains[state.rootAddress] ?? false, isFalse);
    });

    test('chain information survives a journal round-trip and replay', () async {
      final setup = await walletWithChangeUtxo('wallet-change-3');
      final walletId = setup.wallet.aggregateId;

      // Serialize every journaled event and deserialize it through the
      // registry, exactly as a persistent store would, into a fresh store.
      final replayStore = InMemoryEventStore();
      final serialized = eventStore.journal[setup.wallet.persistenceId]!
          .map((e) => EventRegistry.fromMap(e.toMap()))
          .toList();
      await replayStore.persistEvents(setup.wallet.persistenceId, serialized, 0);

      final fresh = await openWallet(walletId, replayStore);
      expect(fresh.currentState.isCreated, isTrue);
      expect(fresh.currentState.utxos.containsKey(setup.changeUtxoKey), isTrue);
      expect((fresh.currentState.metadata['address_chains'] as Map?)?[setup.changeAddress],
          isTrue);

      final versionBefore = fresh.currentState.version;
      await fresh.commandHandler(SignTransactionCommand(
        walletId: walletId,
        transactionId: 'spend-change-after-replay',
        rawTransaction: unsignedTx([setup.changeUtxoKey], {externalAddress: 48000}),
        utxoKeys: [setup.changeUtxoKey],
        publicKeys: const [],
      ));
      expect(fresh.currentState.version, equals(versionBefore + 1));
    });

    test('a caller-supplied derivation index without a chain still signs change', () async {
      // Coordinators pass the index from the read model; when they do not
      // pass the chain the aggregate must resolve it from its own state.
      final setup = await walletWithChangeUtxo('wallet-change-4');
      final wallet = setup.wallet;
      final index =
          (wallet.currentState.metadata['address_indices'] as Map)[setup.changeAddress] as int;

      final versionBefore = wallet.currentState.version;
      await sign(
        wallet,
        id: 'spend-change-with-index',
        rawTx: unsignedTx([setup.changeUtxoKey], {externalAddress: 48000}),
        utxoKeys: [setup.changeUtxoKey],
        derivationIndices: [index],
      );
      expect(wallet.currentState.version, equals(versionBefore + 1));
    });

    test('a caller-supplied chain flag is honoured', () async {
      final setup = await walletWithChangeUtxo('wallet-change-5');
      final wallet = setup.wallet;
      final index =
          (wallet.currentState.metadata['address_indices'] as Map)[setup.changeAddress] as int;

      final versionBefore = wallet.currentState.version;
      await sign(
        wallet,
        id: 'spend-change-with-flag',
        rawTx: unsignedTx([setup.changeUtxoKey], {externalAddress: 48000}),
        utxoKeys: [setup.changeUtxoKey],
        derivationIndices: [index],
        isChangeFlags: [true],
      );
      expect(wallet.currentState.version, equals(versionBefore + 1));
    });

    test('discovered change addresses are signable', () async {
      // Import path: the address is registered via RegisterDiscoveredAddressCommand
      // with isChange: true, which the aggregate previously dropped.
      final wallet = await createWallet('wallet-change-6');
      final hdPriv = await cryptoService.mnemonicToHDPrivateKey(mnemonic,
          network: dartsv.NetworkType.TEST);
      const index = 7;
      final discovered = cryptoService.generateChangeAddress(
        cryptoService.deriveHDPublicKey(hdPriv),
        index,
        network: dartsv.NetworkType.TEST,
      );
      await wallet.commandHandler(RegisterDiscoveredAddressCommand(
        walletId: wallet.aggregateId,
        address: discovered,
        derivationIndex: index,
        isChange: true,
        transactionCount: 1,
      ));
      final utxoKey = await fund(wallet, discovered,
          txid: fundingTxid, vout: 3, satoshis: 70000);

      final versionBefore = wallet.currentState.version;
      await sign(
        wallet,
        id: 'spend-discovered-change',
        rawTx: unsignedTx([utxoKey], {externalAddress: 69000}),
        utxoKeys: [utxoKey],
      );
      expect(wallet.currentState.version, equals(versionBefore + 1));
    });
  });
}

void _registerWalletEvents() {
  LibSpiffyActorSystem.registerEventTypes();
}
