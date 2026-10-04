/// The payment's note (memo), written by the payer for the payee, is
/// journaled and kept on the transaction row exactly as the opaque
/// counterparty marker is (bead libspiffy-cq16): carried by the commands
/// that record a payment, written on their events only when there is one,
/// set once on the row and never blanked or replaced by a later record.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/wallet_messages.dart' show SPVValidationResult;
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/pending_receive.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/storage/transaction_row_rules.dart';

import '../actors/in_memory_event_store.dart';

const _w = 'memo-wallet';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

const _memo = 'for the bicycle — thanks!';
const _otherMemo = 'something else';

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

class _Wallet {
  final BitcoinWalletAggregate aggregate = BitcoinWalletAggregate(
    aggregateId: _w,
    aggregateType: 'BitcoinWallet',
    eventStore: InMemoryEventStore(),
    cryptoService: DartSVCryptoService(),
    secureStorage: InMemorySecureStorage(),
  );

  late String root;

  WalletState get state => aggregate.state ?? aggregate.createInitialState();

  static Future<_Wallet> create() async {
    final wallet = _Wallet();
    await wallet.handle(CreateWalletCommand(walletId: _w, walletName: 'memo', mnemonic: _mnemonic));
    wallet.root = wallet.state.rootAddress!;
    return wallet;
  }

  Future<List<Event>> handle(WalletCommand command) async {
    final events = await aggregate.handleCommand(state, command);
    for (final e in events) {
      aggregate.eventHandler(e);
    }
    return events;
  }
}

WalletProjection _projection(ReadModelStorage storage) => WalletProjection(
      projectionId: 'memo-projection',
      eventStore: _NoopEventStore(),
      storage: storage,
    );

TransactionRecordedEvent _recorded({required String txid, String? memo, int version = 1, int second = 0}) =>
    TransactionRecordedEvent(
      walletId: _w,
      txid: txid,
      rawHex: '0100000000000000000000',
      totalInputSats: 5000,
      totalOutputSats: 4800,
      fee: 200,
      numInputs: 1,
      numOutputs: 2,
      txVersion: 1,
      txLockTime: 0,
      spentUtxoKeys: const [],
      recipientAddresses: const ['payee-1'],
      paymentAmount: '3000',
      memo: memo,
      version: version,
      timestamp: DateTime.utc(2026, 10, 5, 12, 0, second),
    );

TransactionImportedEvent _imported({required String txid, String? memo, int version = 1, int second = 0}) =>
    TransactionImportedEvent(
      walletId: _w,
      txid: txid,
      rawHex: '0100000000000000000000',
      blockHeight: null,
      bumpProof: '',
      totalOutputSats: 4800,
      numInputs: 1,
      numOutputs: 2,
      txVersion: 1,
      txLockTime: 0,
      walletReceivingAddresses: const ['ours-1'],
      walletReceivedSats: 3000,
      totalInputSats: 5000,
      sendingAddresses: const ['sender-1'],
      memo: memo,
      version: version,
      timestamp: DateTime.utc(2026, 10, 5, 12, 0, second),
    );

UTXOReceivedEvent _received({required String txid, int vout = 0, String? memo, int version = 1, int second = 0}) =>
    UTXOReceivedEvent(
      walletId: _w,
      txid: txid,
      vout: vout,
      satoshis: 1000,
      scriptPubKey: '',
      address: '',
      memo: memo,
      version: version,
      timestamp: DateTime.utc(2026, 10, 5, 12, 0, second),
    );

void main() {
  group('events carry the memo through the journal', () {
    test('UTXOReceivedEvent round-trips the memo', () {
      final event = _received(txid: _txid(1), memo: _memo);
      expect(event.getEventData()['memo'], _memo);
      expect(UTXOReceivedEvent.fromMap(event.getEventData()).memo, _memo);
    });

    test('TransactionRecordedEvent round-trips the memo', () {
      final event = _recorded(txid: _txid(2), memo: _memo);
      expect(event.getEventData()['memo'], _memo);
      expect(TransactionRecordedEvent.fromMap(event.getEventData()).memo, _memo);
    });

    test('TransactionImportedEvent round-trips the memo', () {
      final event = _imported(txid: _txid(3), memo: _memo);
      expect(event.getEventData()['memo'], _memo);
      expect(TransactionImportedEvent.fromMap(event.getEventData()).memo, _memo);
    });

    test('an event without a memo writes no key and reads back none', () {
      for (final data in [
        _received(txid: _txid(4)).getEventData(),
        _recorded(txid: _txid(4)).getEventData(),
        _imported(txid: _txid(4)).getEventData(),
      ]) {
        expect(data.containsKey('memo'), isFalse);
      }
      expect(UTXOReceivedEvent.fromMap(_received(txid: _txid(4)).getEventData()).memo, isNull);
      expect(TransactionRecordedEvent.fromMap(_recorded(txid: _txid(4)).getEventData()).memo, isNull);
      expect(TransactionImportedEvent.fromMap(_imported(txid: _txid(4)).getEventData()).memo, isNull);
    });

    test('journal rows written before the memo existed still load', () {
      final recorded = TransactionRecordedEvent.fromMap({
        'walletId': _w,
        'txid': _txid(5),
        'rawHex': '0100',
        'totalInputSats': 5000,
        'totalOutputSats': 4800,
        'fee': 200,
        'numInputs': 1,
        'numOutputs': 2,
        'txVersion': 1,
        'txLockTime': 0,
        'spentUtxoKeys': <String>[],
        'recipientAddresses': ['payee-1'],
        'paymentAmount': '3000',
        'counterpartyMarker': 'peer:bob',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'version': 3,
      });
      expect((recorded.memo, recorded.counterpartyMarker), (null, 'peer:bob'));

      final imported = TransactionImportedEvent.fromMap({
        'walletId': _w,
        'txid': _txid(6),
        'rawHex': '0100',
        'blockHeight': 880,
        'bumpProof': 'fe00',
        'totalOutputSats': 4800,
        'numInputs': 1,
        'numOutputs': 2,
        'txVersion': 1,
        'txLockTime': 0,
        'walletReceivingAddresses': ['ours-1'],
        'walletReceivedSats': 3000,
        'totalInputSats': 5000,
        'sendingAddresses': ['sender-1'],
        'timestamp': '2026-01-01T00:00:00.000Z',
        'version': 4,
      });
      expect(imported.memo, isNull);

      final received = UTXOReceivedEvent.fromMap({
        'walletId': _w,
        'txid': _txid(7),
        'vout': 0,
        'satoshis': 12345,
        'scriptPubKey': '76a914',
        'address': 'addr-1',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'version': 5,
      });
      expect(received.memo, isNull);
    });
  });

  group('commands plumb the memo to the events that record a payment', () {
    late _Wallet wallet;

    setUp(() async {
      wallet = await _Wallet.create();
    });

    test('ReceiveUTXOCommand', () async {
      final events = await wallet.handle(ReceiveUTXOCommand(
        walletId: _w,
        txid: _txid(21),
        vout: 0,
        satoshis: BigInt.from(50000),
        scriptPubKey: _p2pkh(wallet.root),
        address: wallet.root,
        memo: _memo,
      ));
      expect(events.whereType<UTXOReceivedEvent>().single.memo, _memo);
    });

    test('RecordOutgoingTransactionCommand', () async {
      final events = await wallet.handle(RecordOutgoingTransactionCommand(
        walletId: _w,
        txid: _txid(22),
        rawHex: '0100000000000000000000',
        totalInputSats: 5000,
        totalOutputSats: 4800,
        fee: 200,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: const [],
        recipientAddresses: const ['payee-1'],
        paymentAmount: BigInt.from(4800),
        memo: _memo,
      ));
      expect(events.whereType<TransactionRecordedEvent>().single.memo, _memo);
    });

    test('RecordImportedTransactionCommand', () async {
      final events = await wallet.handle(RecordImportedTransactionCommand(
        walletId: _w,
        txid: _txid(23),
        rawHex: '0100000000000000000000',
        blockHeight: null,
        bumpProofHex: '',
        totalOutputSats: 4800,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        walletReceivingAddresses: const ['ours-1'],
        walletReceivedSats: 3000,
        totalInputSats: 5000,
        sendingAddresses: const ['sender-1'],
        memo: _memo,
      ));
      expect(events.whereType<TransactionImportedEvent>().single.memo, _memo);
    });

    test('a command without a memo journals none', () async {
      final events = await wallet.handle(ReceiveUTXOCommand(
        walletId: _w,
        txid: _txid(24),
        vout: 0,
        satoshis: BigInt.from(50000),
        scriptPubKey: _p2pkh(wallet.root),
        address: wallet.root,
      ));
      expect(events.whereType<UTXOReceivedEvent>().single.memo, isNull);
    });
  });

  group('the memo reaches the read model and is never blanked', () {
    late InMemoryWalletStorage storage;
    late WalletProjection projection;

    setUp(() async {
      storage = InMemoryWalletStorage();
      projection = _projection(storage);
      await storage.storeWallet(_w, 'W');
    });

    Future<BitcoinTransaction?> row(String txid) => storage.getTransaction(txid, walletId: _w);

    test('an outgoing and an incoming payment row carry the memo', () async {
      await projection.handle(_recorded(txid: _txid(31), memo: _memo));
      await projection.handle(_imported(txid: _txid(32), memo: _otherMemo));
      expect((await row(_txid(31)))!.memo, _memo);
      expect((await row(_txid(32)))!.memo, _otherMemo);
    });

    test('a confirmation, a status update and a revert keep the memo', () async {
      await projection.handle(_recorded(txid: _txid(33), memo: _memo));
      await projection.handle(TransactionStatusUpdatedEvent(
        walletId: _w,
        txid: _txid(33),
        newStatus: TransactionStatus.seenOnNetwork,
        version: 2,
        timestamp: DateTime.utc(2026, 10, 5, 12, 30),
      ));
      expect((await row(_txid(33)))!.memo, _memo, reason: 'a status update');
      await projection.handle(TransactionConfirmedEvent(
        walletId: _w,
        txid: _txid(33),
        blockHeight: 901,
        version: 3,
        timestamp: DateTime.utc(2026, 10, 5, 13),
      ));
      expect((await row(_txid(33)))!.status, TransactionStatus.confirmed);
      expect((await row(_txid(33)))!.memo, _memo, reason: 'a confirmation');
      await projection.handle(TransactionConfirmationRevertedEvent(
        walletId: _w,
        txid: _txid(33),
        reason: 'reorg',
        blockHeight: 901,
        version: 4,
        timestamp: DateTime.utc(2026, 10, 5, 14),
      ));
      expect((await row(_txid(33)))!.memo, _memo, reason: 'a reorganization');
    });

    test('a re-recorded or re-imported payment without a memo keeps the stored one, and none replaces it',
        () async {
      await projection.handle(_recorded(txid: _txid(34), memo: _memo));
      await projection.handle(_recorded(txid: _txid(34), version: 2, second: 1));
      expect((await row(_txid(34)))!.memo, _memo);
      await projection.handle(_recorded(txid: _txid(34), memo: _otherMemo, version: 3, second: 2));
      expect((await row(_txid(34)))!.memo, _memo);

      await projection.handle(_imported(txid: _txid(35), memo: _memo));
      await projection.handle(_imported(txid: _txid(35), version: 2, second: 1));
      expect((await row(_txid(35)))!.memo, _memo, reason: 'a replayed import without one');
    });

    test('a UTXO received with a memo stamps the row that has none, and never replaces one', () async {
      await projection.handle(_recorded(txid: _txid(36)));
      expect((await row(_txid(36)))!.memo, isNull);
      await projection.handle(_received(txid: _txid(36), memo: _memo, version: 2, second: 1));
      expect((await row(_txid(36)))!.memo, _memo);
      await projection.handle(_received(txid: _txid(36), vout: 1, memo: _otherMemo, version: 3, second: 2));
      expect((await row(_txid(36)))!.memo, _memo);
    });

    test('a later direct storage write without a memo keeps it', () async {
      await projection.handle(_recorded(txid: _txid(37), memo: _memo));
      final stored = (await row(_txid(37)))!;
      await storage.storeTransaction(
          _w,
          BitcoinTransaction(
            txid: stored.txid,
            rawHex: stored.rawHex,
            status: TransactionStatus.seenOnNetwork,
            inputValue: stored.inputValue,
            outputValue: stored.outputValue,
            fee: stored.fee,
            receivingAddresses: stored.receivingAddresses,
            sendingAddresses: stored.sendingAddresses,
            netAmount: stored.netAmount,
            createdAt: stored.createdAt,
            updatedAt: DateTime.utc(2026, 10, 5, 15),
          ));
      expect((await row(_txid(37)))!.memo, _memo);
    });
  });

  group('TransactionRowRules.memoAfter', () {
    test('the first memo wins and nothing later blanks or replaces it', () {
      expect(TransactionRowRules.memoAfter(null, null), isNull);
      expect(TransactionRowRules.memoAfter(null, _memo), _memo);
      expect(TransactionRowRules.memoAfter(_memo, null), _memo);
      expect(TransactionRowRules.memoAfter(_memo, _otherMemo), _memo);
      // A blank string is not a memo.
      expect(TransactionRowRules.memoAfter(null, ''), isNull);
      expect(TransactionRowRules.memoAfter('', ''), isNull);
      expect(TransactionRowRules.memoAfter('', _memo), _memo);
      expect(TransactionRowRules.memoAfter(_memo, ''), _memo);
    });
  });

  group('the Isar transaction entity keeps the memo', () {
    BitcoinTransaction tx({String? memo}) => BitcoinTransaction(
          walletId: _w,
          txid: _txid(41),
          rawHex: '0100000000000000000000',
          status: TransactionStatus.pending,
          inputValue: BigInt.from(5000),
          outputValue: BigInt.from(4800),
          fee: BigInt.from(200),
          receivingAddresses: const [],
          sendingAddresses: const [],
          netAmount: BigInt.from(3000),
          createdAt: DateTime.utc(2026, 10, 5),
          updatedAt: DateTime.utc(2026, 10, 5),
          memo: memo,
        );

    test('applyDomain without a memo keeps the stored one, and never replaces it', () {
      final entity = BitcoinTransactionEntity.fromDomain(tx(memo: _memo));
      expect(entity.notes, _memo);
      entity.applyDomain(tx());
      expect(entity.notes, _memo);
      entity.applyDomain(tx(memo: _otherMemo));
      expect(entity.notes, _memo);
      expect(entity.toDomain().memo, _memo);
    });

    test('a row stored without one takes the first memo a later record carries', () {
      final entity = BitcoinTransactionEntity.fromDomain(tx());
      expect(entity.notes, isNull);
      entity.applyDomain(tx(memo: _memo));
      expect(entity.notes, _memo);
    });
  });

  group('a parked receive keeps the memo', () {
    final receive = PendingReceive(
      walletId: _w,
      txid: _txid(51),
      beefHex: '0100beef',
      fromCounterparty: 'bob',
      memo: _memo,
      neededHeight: 10,
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
    );

    test('copyWith keeps it, and the Isar entity round-trips it', () {
      expect(receive.copyWith(neededHeight: 11).memo, _memo);
      expect(PendingReceiveEntity.fromDomain(receive).toDomain().memo, _memo);
    });
  });

  group('the SPV verdict carries the memo to the wallet', () {
    test('answering stamps the memo; a blank one is none', () {
      final result = SPVValidationResult(txid: _txid(61), isValid: true);
      expect(result.answering('bob', memo: _memo).memo, _memo);
      expect(result.answering('bob', memo: '').memo, isNull);
      expect(result.answering('bob').memo, isNull);
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
