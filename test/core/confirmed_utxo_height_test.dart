/// Bead libspiffy-4dja: a UTXO confirmed from a merkle proof kept
/// `blockHeight` null.
///
/// After a proof-driven confirmation the TRANSACTION row carried the proven
/// block height, but the UTXO rows of that same transaction did not: the
/// wallet reported a transaction confirmed at height N while its own output
/// said height null. The confirmation only moved the output from pending to
/// available (`MarkUTXOAvailableCommand` / `UtxoLedger.markAvailable`, which
/// deliberately carries no height), and nothing ever wrote the height the
/// proof established onto the output.
///
/// The rule the fix has to respect (bead libspiffy-5ry / V-60,
/// spv-understanding.md): a height on a UTXO means a verified proof backs
/// it. The only height these tests ever put on an output is the one
/// [ConfirmTransactionCommand] carries, which every sender derives from a
/// BUMP checked against our own header chain.
///
/// Testnet only: ScriptTypeRegistry is a process-wide singleton pinned to
/// the first network it is built with.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _externalAddress = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF'; // testnet
const _fundingTxid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1';
const _receivedTxid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2';

/// The height the proof puts the transaction at, and the block it names.
const _provenHeight = 812345;
const _provenBlockHash = '00000000000000000abcdef0123456789abcdef0123456789abcdef012345678';

void main() {
  late DartSVCryptoService crypto;
  late InMemorySecureStorage secrets;
  late InMemoryEventStore eventStore;

  setUp(() {
    crypto = DartSVCryptoService();
    secrets = InMemorySecureStorage();
    eventStore = InMemoryEventStore();
    EventRegistry.clear();
    LibSpiffyActorSystem.registerEventTypes();
  });

  Future<BitcoinWalletAggregate> createWallet(String walletId) async {
    final wallet = BitcoinWalletAggregate(
      aggregateId: walletId,
      aggregateType: 'Wallet',
      eventStore: eventStore,
      cryptoService: crypto,
      secureStorage: secrets,
    );
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(
      walletId: walletId,
      walletName: '4dja wallet',
      mnemonic: _mnemonic,
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

  String p2pkhScriptHex(String address) => '76a914${dartsv.Address.fromBase58(address).pubkeyHash160}88ac';

  String unsignedTx(List<String> utxoKeys, Map<String, int> outputs) {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    for (final key in utxoKeys) {
      final parts = key.split(':');
      tx.inputs.add(dartsv.TransactionInput(parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
    }
    outputs.forEach((address, sats) {
      tx.outputs.add(dartsv.TransactionOutput(
          BigInt.from(sats), dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey()));
    });
    return tx.serialize();
  }

  /// The wallet's journal, replayed through a fresh read model.
  Future<InMemoryWalletStorage> readModel(BitcoinWalletAggregate wallet) async {
    final storage = InMemoryWalletStorage();
    final projection = WalletProjection(projectionId: '4dja', eventStore: eventStore, storage: storage);
    for (final event in eventStore.journal[wallet.persistenceId]!) {
      await projection.handle(event);
    }
    return storage;
  }

  Future<BitcoinUtxo?> row(InMemoryWalletStorage storage, String walletId, String key) async {
    for (final utxo in await storage.getUTXOs(walletId, includeSpent: true)) {
      if (utxo.key == key) return utxo;
    }
    return null;
  }

  /// A wallet that has paid out and kept the change: the payment is recorded,
  /// its change output is pending, and nothing has proven it yet.
  Future<({BitcoinWalletAggregate wallet, String txid, String changeKey})> walletWithPendingChange(
      String walletId) async {
    final wallet = await createWallet(walletId);
    final receiveAddress = await generateAddress(wallet);
    await wallet.commandHandler(ReceiveUTXOCommand(
      walletId: walletId,
      txid: _fundingTxid,
      vout: 0,
      satoshis: BigInt.from(100000),
      scriptPubKey: p2pkhScriptHex(receiveAddress),
      address: receiveAddress,
      initialStatus: UTXOStatus.available,
    ));
    final changeAddress = await generateAddress(wallet, purpose: 'change');
    final rawHex = unsignedTx(['$_fundingTxid:0'], {_externalAddress: 50000, changeAddress: 49000});
    final txid = dartsv.Transaction.fromHex(rawHex).id;
    await wallet.commandHandler(RecordOutgoingTransactionCommand(
      walletId: walletId,
      txid: txid,
      rawHex: rawHex,
      totalInputSats: 100000,
      totalOutputSats: 99000,
      fee: 1000,
      numInputs: 1,
      numOutputs: 2,
      txVersion: 1,
      txLockTime: 0,
      spentUtxoKeys: ['$_fundingTxid:0'],
      recipientAddresses: [_externalAddress],
      paymentAmount: BigInt.from(50000),
      changeAddress: changeAddress,
      changeAmount: BigInt.from(49000),
    ));
    final changeKey = '$txid:1';
    final change = wallet.currentState.utxos[changeKey];
    expect(change, isNotNull, reason: 'the change output must be scanned into the wallet');
    expect((change!.status, change.blockHeight), (UTXOStatus.pending, null),
        reason: 'nothing has proven the payment yet');
    return (wallet: wallet, txid: txid, changeKey: changeKey);
  }

  /// A wallet holding a payment a counterparty handed over without a proof:
  /// the transaction is recorded and its output is pending, with no height.
  Future<({BitcoinWalletAggregate wallet, String utxoKey})> walletWithUnprovenReceipt(String walletId) async {
    final wallet = await createWallet(walletId);
    final address = await generateAddress(wallet);
    await wallet.commandHandler(RecordImportedTransactionCommand(
      walletId: walletId,
      txid: _receivedTxid,
      rawHex: unsignedTx(['$_fundingTxid:9'], {address: 70000}),
      blockHeight: null,
      bumpProofHex: '',
      totalOutputSats: 70000,
      numInputs: 1,
      numOutputs: 1,
      txVersion: 1,
      txLockTime: 0,
      walletReceivingAddresses: [address],
      walletReceivedSats: 70000,
      totalInputSats: 0,
      sendingAddresses: const [],
    ));
    await wallet.commandHandler(ReceiveUTXOCommand(
      walletId: walletId,
      txid: _receivedTxid,
      vout: 0,
      satoshis: BigInt.from(70000),
      scriptPubKey: p2pkhScriptHex(address),
      address: address,
      // No proof came with it: pending, and the command refuses a height
      // with a pending status anyway (bead libspiffy-5ry).
      initialStatus: UTXOStatus.pending,
    ));
    final key = '$_receivedTxid:0';
    expect(wallet.currentState.utxos[key]!.blockHeight, isNull);
    return (wallet: wallet, utxoKey: key);
  }

  Future<void> confirm(BitcoinWalletAggregate wallet, String txid, {int height = _provenHeight}) =>
      wallet.commandHandler(ConfirmTransactionCommand(
        walletId: wallet.aggregateId,
        txid: txid,
        blockHeight: height,
        blockHash: _provenBlockHash,
      ));

  group('4dja: the change of a payment a proof confirms', () {
    test('carries the proven height in the wallet aggregate', () async {
      final setup = await walletWithPendingChange('4dja-change-write');
      await confirm(setup.wallet, setup.txid);

      final change = setup.wallet.currentState.utxos[setup.changeKey]!;
      expect(change.status, UTXOStatus.available);
      expect(change.blockHeight, _provenHeight,
          reason: 'the confirming proof puts the change output in a block; the UTXO must say so');
    });

    test('carries the proven height in the read model, agreeing with the transaction row', () async {
      final setup = await walletWithPendingChange('4dja-change-read');
      await confirm(setup.wallet, setup.txid);

      final storage = await readModel(setup.wallet);
      final tx = (await storage.getTransaction(setup.txid, walletId: setup.wallet.aggregateId))!;
      final change = (await row(storage, setup.wallet.aggregateId, setup.changeKey))!;
      expect((tx.status, tx.blockHeight), (TransactionStatus.confirmed, _provenHeight));
      expect((change.status, change.blockHeight), (UTXOStatus.available, _provenHeight),
          reason: 'the transaction row and its own output row must not disagree about the block');
    });
  });

  group('4dja: a received payment proven after it arrived', () {
    test('its output carries the proven height in the aggregate and the read model', () async {
      final setup = await walletWithUnprovenReceipt('4dja-receive');
      await confirm(setup.wallet, _receivedTxid);

      final utxo = setup.wallet.currentState.utxos[setup.utxoKey]!;
      expect((utxo.status, utxo.blockHeight), (UTXOStatus.available, _provenHeight));

      final storage = await readModel(setup.wallet);
      final tx = (await storage.getTransaction(_receivedTxid, walletId: setup.wallet.aggregateId))!;
      final projected = (await row(storage, setup.wallet.aggregateId, setup.utxoKey))!;
      expect(tx.blockHeight, _provenHeight);
      expect(projected.blockHeight, _provenHeight);
    });
  });

  group('4dja: a height comes only from a verified confirmation', () {
    test('an output made available without a proof stays heightless', () async {
      final setup = await walletWithPendingChange('4dja-no-proof');
      // What ARC's SEEN_ON_NETWORK does: the output is spendable, but
      // nothing has been mined, so no height may appear.
      await setup.wallet.commandHandler(MarkUTXOAvailableCommand(
        walletId: setup.wallet.aggregateId,
        txid: setup.txid,
        vout: 1,
      ));

      final change = setup.wallet.currentState.utxos[setup.changeKey]!;
      expect(change.status, UTXOStatus.available);
      expect(change.blockHeight, isNull, reason: 'seen on the network is not mined');

      final storage = await readModel(setup.wallet);
      expect((await row(storage, setup.wallet.aggregateId, setup.changeKey))!.blockHeight, isNull);
    });

    test('a confirmation taken back takes the height off the output again', () async {
      final setup = await walletWithPendingChange('4dja-revert');
      await confirm(setup.wallet, setup.txid);
      expect(setup.wallet.currentState.utxos[setup.changeKey]!.blockHeight, _provenHeight);

      await setup.wallet.commandHandler(RevertTransactionConfirmationCommand(
        walletId: setup.wallet.aggregateId,
        txid: setup.txid,
        blockHeight: _provenHeight,
        blockHash: _provenBlockHash,
        reason: 'the block left the active chain',
      ));

      final change = setup.wallet.currentState.utxos[setup.changeKey]!;
      expect((change.status, change.blockHeight), (UTXOStatus.pending, null));

      final storage = await readModel(setup.wallet);
      final projected = (await row(storage, setup.wallet.aggregateId, setup.changeKey))!;
      expect((projected.status, projected.blockHeight), (UTXOStatus.pending, null));
    });

    test('a UTXO of another transaction is left alone', () async {
      final setup = await walletWithPendingChange('4dja-other-tx');
      await confirm(setup.wallet, setup.txid);

      // The funding UTXO belongs to a different transaction: the payment's
      // proof says nothing about it.
      final funding = setup.wallet.currentState.utxos['$_fundingTxid:0']!;
      expect(funding.blockHeight, isNull);
    });
  });
}
