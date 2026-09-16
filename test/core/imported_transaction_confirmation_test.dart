/// Bead libspiffy-73bj, at the aggregate: a merkle proof confirms a
/// transaction the wallet RECEIVED, and the write model keeps that
/// confirmation.
///
/// `ConfirmTransactionCommand(onlyIfRecorded: true)` — the command a BUMP in
/// a received BEEF produces — matched only the outgoing records, so a
/// payment we received and held unproven was never confirmed in the journal.
/// It is now, with exactly the half of an outgoing confirmation that applies:
/// a received transaction creates wallet outputs and spends none of our
/// inputs, so its pending outputs become spendable and no UTXO is spent.
///
/// The end-to-end path is test/integration/imported_transaction_proof_confirms_test.dart;
/// these tests pin the record the aggregate keeps, its idempotency, its
/// reversal and what a later unproven re-delivery may not undo.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _w = '73bj-wallet';
const _pid = 'BitcoinWallet_$_w';

/// The transaction we received: one output paying our root address.
final _received = '11' * 32;

final _crypto = DartSVCryptoService();

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

void main() {
  late InMemoryEventStore store;
  late BitcoinWalletAggregate wallet;

  WalletState state() => wallet.currentState;
  List<Event> journal() => store.journal[_pid] ?? const [];
  Map<dynamic, dynamic> importedRecord() => (state().metadata['importedTransactions'] as Map)[_received] as Map;
  List<TransactionConfirmedEvent> confirmations() =>
      journal().whereType<TransactionConfirmedEvent>().where((e) => e.txid == _received).toList();

  /// The wallet, holding one pending output of the transaction it received
  /// and its imported record, with no proof for it.
  setUp(() async {
    store = InMemoryEventStore();
    wallet = BitcoinWalletAggregate(
      aggregateId: _w,
      aggregateType: 'BitcoinWallet',
      eventStore: store,
      cryptoService: _crypto,
      secureStorage: InMemorySecureStorage(),
    );
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(
        walletId: _w, walletName: '73bj', mnemonic: _mnemonic, walletMetadata: {'network': 'testnet'}));
    final root = state().rootAddress!;
    await wallet.commandHandler(ReceiveUTXOCommand(
      walletId: _w,
      txid: _received,
      vout: 0,
      satoshis: BigInt.from(200000),
      scriptPubKey: _p2pkh(root),
      address: root,
      initialStatus: UTXOStatus.pending,
    ));
    await wallet.commandHandler(RecordImportedTransactionCommand(
      walletId: _w,
      txid: _received,
      rawHex: '',
      blockHeight: 0,
      bumpProofHex: '',
      totalOutputSats: 200000,
      numInputs: 1,
      numOutputs: 1,
      txVersion: 1,
      txLockTime: 0,
      walletReceivingAddresses: [root],
      walletReceivedSats: 200000,
      totalInputSats: 210000,
      sendingAddresses: const [],
    ));
    expect(importedRecord()['status'], isNull, reason: 'nothing proves it yet');
  });

  Future<void> confirmFromProof({int blockHeight = 700, String? bump}) =>
      wallet.commandHandler(ConfirmTransactionCommand(
        walletId: _w,
        txid: _received,
        blockHeight: blockHeight,
        blockHash: 'bb' * 32,
        bumpHex: bump ?? 'bu' * 8,
        onlyIfRecorded: true,
      ));

  test('a proof for a transaction the wallet received is journaled, and makes its output spendable', () async {
    final before = journal().length;
    await confirmFromProof();

    final events = journal().skip(before).toList();
    expect(events.map((e) => e.runtimeType.toString()),
        ['UTXOMarkedAvailableEvent', 'TransactionConfirmedEvent'],
        reason: 'a received transaction is confirmed and its outputs released, and nothing else');
    expect(events.whereType<UTXOSpentEvent>(), isEmpty,
        reason: 'a transaction we received spends none of our inputs');

    final confirmed = confirmations().single;
    expect((confirmed.blockHeight, confirmed.blockHash, confirmed.bumpHex), (700, 'bb' * 32, 'bu' * 8));
    expect(state().utxos['$_received:0']!.status, UTXOStatus.available);
    expect(importedRecord()['status'], 'confirmed');
    expect(importedRecord()['blockHeight'], 700);
  });

  test('the same proof offered twice confirms once', () async {
    await confirmFromProof();
    final after = journal().length;
    await confirmFromProof();

    expect(journal().length, after, reason: 'a redelivered proof journaled a second confirmation');
    expect(confirmations(), hasLength(1));
  });

  test('a later re-delivery without a proof does not take the confirmed record back to no block', () async {
    await confirmFromProof();
    await wallet.commandHandler(RecordImportedTransactionCommand(
      walletId: _w,
      txid: _received,
      rawHex: '',
      blockHeight: 0,
      bumpProofHex: '',
      totalOutputSats: 200000,
      numInputs: 1,
      numOutputs: 1,
      txVersion: 1,
      txLockTime: 0,
      walletReceivingAddresses: [state().rootAddress!],
      walletReceivedSats: 200000,
      totalInputSats: 210000,
      sendingAddresses: const [],
    ));

    expect((importedRecord()['status'], importedRecord()['blockHeight']), ('confirmed', 700),
        reason: 'a re-delivery carrying no proof lowered the height the proof established');
    expect(importedRecord()['lastImportedAt'], isNotNull, reason: 'the re-delivery is still recorded');
  });

  test('a reverted confirmation is taken back, and a proof on the new chain confirms it again', () async {
    await confirmFromProof();
    await wallet.commandHandler(RevertTransactionConfirmationCommand(
        walletId: _w, txid: _received, blockHeight: 700, reason: 'reorg'));

    expect(importedRecord()['status'], 'pending');
    expect(importedRecord().containsKey('blockHeight'), isFalse);
    expect(state().utxos['$_received:0']!.status, UTXOStatus.pending,
        reason: 'an output spendable only because of the proof goes back to pending');

    // The same transaction is mined on the new chain: it confirms again.
    await confirmFromProof(blockHeight: 702, bump: 'cc' * 8);
    expect(confirmations().map((e) => e.blockHeight), [700, 702]);
    expect(importedRecord()['blockHeight'], 702);
    expect(state().utxos['$_received:0']!.status, UTXOStatus.available);
  });

  test('a proof for a transaction the wallet never saw journals nothing', () async {
    final before = journal().length;
    await wallet.commandHandler(ConfirmTransactionCommand(
      walletId: _w,
      txid: '99' * 32,
      blockHeight: 700,
      blockHash: 'bb' * 32,
      bumpHex: 'bu' * 8,
      onlyIfRecorded: true,
    ));
    expect(journal().length, before,
        reason: 'a BUMP proving a counterparty transaction wrote to the wallet journal');
  });

  test('the confirmation of a received transaction survives a replay of the journal', () async {
    await confirmFromProof();
    final replayed = BitcoinWalletAggregate(
      aggregateId: _w,
      aggregateType: 'BitcoinWallet',
      eventStore: store,
      cryptoService: _crypto,
      secureStorage: InMemorySecureStorage(),
    );
    await replayed.preStart();

    final record = (replayed.currentState.metadata['importedTransactions'] as Map)[_received] as Map;
    expect((record['status'], record['blockHeight']), ('confirmed', 700));
    expect(replayed.currentState.utxos['$_received:0']!.status, UTXOStatus.available);
  });
}
