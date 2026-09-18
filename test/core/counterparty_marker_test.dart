/// libspiffy-cq16: a counterparty identity marker on every payment, both
/// directions (spv-understanding.md, "Core Data Management" requirement 5).
///
/// The marker is an OPAQUE app-chosen string — an Ed25519 identity key, an
/// email address, a peer id, an internal account id. libspiffy stores it,
/// returns it and never interprets it. It is distinct from the address-derived
/// `counterparty` / `primary_counterparty` columns of migration v015: an
/// address is not an identity.
///
/// Before this bead the marker rode through ReceiveTransactionCommand ->
/// ReceiveTransactionMessage -> the SPV messages and was persisted only on a
/// receive parked waiting for its headers (bead libspiffy-vfai). A receive
/// that succeeded kept no record of who sent it, and the outgoing side had no
/// such field at all.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/storage/transaction_row_rules.dart';

import '../actors/in_memory_event_store.dart';

const _w = 'cq16-wallet';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// The kind of value an app hands us: not an address, not a key libspiffy
/// can parse. It is stored verbatim.
const _marker = 'ed25519:9f3a1c7e-alice@example.com';
const _otherMarker = 'peer:bob-2f91';

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

/// A wallet aggregate driven without an actor system.
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
    await wallet.handle(CreateWalletCommand(walletId: _w, walletName: 'cq16', mnemonic: _mnemonic));
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
      projectionId: 'cq16-projection',
      eventStore: _NoopEventStore(),
      storage: storage,
    );

TransactionRecordedEvent _recorded({
  required String txid,
  String? counterpartyMarker,
  int version = 1,
  int second = 0,
}) =>
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
      counterpartyMarker: counterpartyMarker,
      version: version,
      timestamp: DateTime.utc(2026, 9, 17, 12, 0, second),
    );

TransactionImportedEvent _imported({
  required String txid,
  String? counterpartyMarker,
  int version = 1,
  int second = 0,
}) =>
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
      counterpartyMarker: counterpartyMarker,
      version: version,
      timestamp: DateTime.utc(2026, 9, 17, 12, 0, second),
    );

void main() {
  group('cq16 events carry an opaque counterparty marker', () {
    test('UTXOReceivedEvent round-trips the marker through the journal', () {
      final event = UTXOReceivedEvent(
        walletId: _w,
        txid: _txid(1),
        vout: 0,
        satoshis: 5000,
        scriptPubKey: '',
        address: '',
        counterpartyMarker: _marker,
        version: 2,
        timestamp: DateTime.utc(2026, 9, 17),
      );
      expect(event.counterpartyMarker, _marker);
      expect(event.getEventData()['counterpartyMarker'], _marker);
      expect(UTXOReceivedEvent.fromMap(event.getEventData()).counterpartyMarker, _marker);
    });

    test('TransactionRecordedEvent round-trips the marker through the journal', () {
      final event = _recorded(txid: _txid(2), counterpartyMarker: _marker);
      expect(event.counterpartyMarker, _marker);
      expect(event.getEventData()['counterpartyMarker'], _marker);
      expect(TransactionRecordedEvent.fromMap(event.getEventData()).counterpartyMarker, _marker);
    });

    test('TransactionImportedEvent round-trips the marker through the journal', () {
      final event = _imported(txid: _txid(3), counterpartyMarker: _marker);
      expect(event.counterpartyMarker, _marker);
      expect(event.getEventData()['counterpartyMarker'], _marker);
      expect(TransactionImportedEvent.fromMap(event.getEventData()).counterpartyMarker, _marker);
    });

    test('an event without a marker serializes exactly as it did before the field existed', () {
      final received = UTXOReceivedEvent(
        walletId: _w,
        txid: _txid(4),
        vout: 1,
        satoshis: 7,
        scriptPubKey: '',
        address: '',
      );
      expect(received.getEventData().containsKey('counterpartyMarker'), isFalse);
      expect(_recorded(txid: _txid(4)).getEventData().containsKey('counterpartyMarker'), isFalse);
      expect(_imported(txid: _txid(4)).getEventData().containsKey('counterpartyMarker'), isFalse);
    });
  });

  group('cq16 journals written before the marker existed replay unchanged', () {
    // Exactly the maps the releases before this bead wrote: no
    // 'counterpartyMarker' key at all.
    test('a pre-change UTXOReceivedEvent row rehydrates with a null marker', () {
      final event = UTXOReceivedEvent.fromMap({
        'walletId': _w,
        'txid': _txid(11),
        'vout': 0,
        'satoshis': 12345,
        'scriptPubKey': '76a914',
        'address': 'addr-1',
        'blockHeight': 900,
        'confirmations': 3,
        'initialStatus': 'available',
        'derivationIndex': 2,
        'pluginMetadata': null,
        'eventId': 'evt-11',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'version': 7,
      });
      expect(event.counterpartyMarker, isNull);
      expect((event.txid, event.vout, event.satoshis), (_txid(11), 0, 12345));
      expect((event.blockHeight, event.confirmations), (900, 3));
      expect(event.initialStatus, UTXOStatus.available);
      expect((event.derivationIndex, event.eventId, event.version), (2, 'evt-11', 7));
    });

    test('a pre-change TransactionRecordedEvent row rehydrates with a null marker', () {
      final event = TransactionRecordedEvent.fromMap({
        'walletId': _w,
        'txid': _txid(12),
        'rawHex': '0100',
        'totalInputSats': 5000,
        'totalOutputSats': 4800,
        'fee': 200,
        'numInputs': 1,
        'numOutputs': 2,
        'txVersion': 1,
        'txLockTime': 0,
        'spentUtxoKeys': [_txid(1) + ':0'],
        'recipientAddresses': ['payee-1'],
        'paymentAmount': '3000',
        'changeAddress': 'change-1',
        'changeAmount': '1800',
        'eventId': 'evt-12',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'version': 8,
      });
      expect(event.counterpartyMarker, isNull);
      expect((event.txid, event.fee, event.paymentAmount), (_txid(12), 200, '3000'));
      expect(event.spentUtxoKeys, ['${_txid(1)}:0']);
      expect((event.changeAddress, event.changeAmount, event.version), ('change-1', '1800', 8));
    });

    test('a pre-change TransactionImportedEvent row rehydrates with a null marker', () {
      final event = TransactionImportedEvent.fromMap({
        'walletId': _w,
        'txid': _txid(13),
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
        'eventId': 'evt-13',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'version': 9,
      });
      expect(event.counterpartyMarker, isNull);
      expect((event.txid, event.blockHeight, event.bumpProof), (_txid(13), 880, 'fe00'));
      expect(event.sendingAddresses, ['sender-1']);
      expect(event.ancestors, isEmpty);
      expect(event.version, 9);
    });

    test('a pre-change journal replays into the read model with a null marker', () async {
      final storage = InMemoryWalletStorage();
      final projection = _projection(storage);
      await storage.storeWallet(_w, 'W');

      await projection.handle(TransactionRecordedEvent.fromMap({
        'walletId': _w,
        'txid': _txid(14),
        'rawHex': '0100',
        'totalInputSats': 5000,
        'totalOutputSats': 4800,
        'fee': 200,
        'numInputs': 1,
        'numOutputs': 1,
        'txVersion': 1,
        'txLockTime': 0,
        'spentUtxoKeys': <String>[],
        'recipientAddresses': ['payee-1'],
        'paymentAmount': '3000',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'version': 1,
      }));

      final row = await storage.getTransaction(_txid(14), walletId: _w);
      expect(row, isNotNull);
      expect(row!.counterpartyMarker, isNull);
      expect(row.netAmount, BigInt.from(-3200));
    });
  });

  group('cq16 commands plumb the marker to the events that record a payment', () {
    late _Wallet wallet;

    setUp(() async {
      wallet = await _Wallet.create();
    });

    test('an incoming payment journals who it came from', () async {
      final events = await wallet.handle(ReceiveUTXOCommand(
        walletId: _w,
        txid: _txid(21),
        vout: 0,
        satoshis: BigInt.from(50000),
        scriptPubKey: _p2pkh(wallet.root),
        address: wallet.root,
        counterpartyMarker: _marker,
      ));
      final received = events.whereType<UTXOReceivedEvent>().single;
      expect(received.counterpartyMarker, _marker);
    });

    test('a receive without a marker still works and journals none', () async {
      final events = await wallet.handle(ReceiveUTXOCommand(
        walletId: _w,
        txid: _txid(22),
        vout: 0,
        satoshis: BigInt.from(50000),
        scriptPubKey: _p2pkh(wallet.root),
        address: wallet.root,
      ));
      expect(events.whereType<UTXOReceivedEvent>().single.counterpartyMarker, isNull);
    });

    test('an outgoing payment journals who it was paid to', () async {
      final events = await wallet.handle(RecordOutgoingTransactionCommand(
        walletId: _w,
        txid: _txid(23),
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
        counterpartyMarker: _otherMarker,
      ));
      expect(events.whereType<TransactionRecordedEvent>().single.counterpartyMarker, _otherMarker);
    });

    test('an imported (received) transaction journals who handed it to us', () async {
      final events = await wallet.handle(RecordImportedTransactionCommand(
        walletId: _w,
        txid: _txid(24),
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
        counterpartyMarker: _marker,
      ));
      expect(events.whereType<TransactionImportedEvent>().single.counterpartyMarker, _marker);
    });
  });

  group('cq16 the marker reaches the read model and is never blanked', () {
    late InMemoryWalletStorage storage;
    late WalletProjection projection;

    setUp(() async {
      storage = InMemoryWalletStorage();
      projection = _projection(storage);
      await storage.storeWallet(_w, 'W');
    });

    Future<BitcoinTransaction?> row(String txid) => storage.getTransaction(txid, walletId: _w);

    test('an outgoing payment row carries the marker', () async {
      await projection.handle(_recorded(txid: _txid(31), counterpartyMarker: _otherMarker));
      expect((await row(_txid(31)))!.counterpartyMarker, _otherMarker);
    });

    test('an incoming payment row carries the marker', () async {
      await projection.handle(_imported(txid: _txid(32), counterpartyMarker: _marker));
      expect((await row(_txid(32)))!.counterpartyMarker, _marker);
    });

    test('a later confirmation does not blank the marker', () async {
      await projection.handle(_recorded(txid: _txid(33), counterpartyMarker: _otherMarker));
      await projection.handle(TransactionConfirmedEvent(
        walletId: _w,
        txid: _txid(33),
        blockHeight: 901,
        version: 2,
        timestamp: DateTime.utc(2026, 9, 17, 13),
      ));
      final stored = (await row(_txid(33)))!;
      expect(stored.status, TransactionStatus.confirmed);
      expect(stored.counterpartyMarker, _otherMarker,
          reason: 'a status update must never overwrite a marker that was set');
    });

    test('a re-recorded payment without a marker keeps the stored one', () async {
      await projection.handle(_recorded(txid: _txid(34), counterpartyMarker: _otherMarker));
      await projection.handle(_recorded(txid: _txid(34), version: 2, second: 1));
      expect((await row(_txid(34)))!.counterpartyMarker, _otherMarker);
    });

    test('a UTXO received with a marker stamps the payment row that has none, and never replaces one',
        () async {
      // The row exists first (an outgoing payment of ours recorded without a
      // marker), then the receive of one of its outputs names a counterparty.
      await projection.handle(_recorded(txid: _txid(35)));
      expect((await row(_txid(35)))!.counterpartyMarker, isNull);

      await projection.handle(UTXOReceivedEvent(
        walletId: _w,
        txid: _txid(35),
        vout: 0,
        satoshis: 1000,
        scriptPubKey: '',
        address: '',
        counterpartyMarker: _marker,
        version: 2,
        timestamp: DateTime.utc(2026, 9, 17, 12, 0, 1),
      ));
      expect((await row(_txid(35)))!.counterpartyMarker, _marker);

      // A second receive naming somebody else never replaces it.
      await projection.handle(UTXOReceivedEvent(
        walletId: _w,
        txid: _txid(35),
        vout: 1,
        satoshis: 1000,
        scriptPubKey: '',
        address: '',
        counterpartyMarker: _otherMarker,
        version: 3,
        timestamp: DateTime.utc(2026, 9, 17, 12, 0, 2),
      ));
      expect((await row(_txid(35)))!.counterpartyMarker, _marker);
    });
  });

  group('cq16 TransactionRowRules.counterpartyMarkerAfter', () {
    test('the first marker wins and nothing later blanks or replaces it', () {
      expect(TransactionRowRules.counterpartyMarkerAfter(null, null), isNull);
      expect(TransactionRowRules.counterpartyMarkerAfter(null, _marker), _marker);
      expect(TransactionRowRules.counterpartyMarkerAfter(_marker, null), _marker);
      expect(TransactionRowRules.counterpartyMarkerAfter(_marker, _otherMarker), _marker);
      // A blank string is not a marker: it is what an actor message carries
      // when the app supplied nothing.
      expect(TransactionRowRules.counterpartyMarkerAfter(null, ''), isNull);
      expect(TransactionRowRules.counterpartyMarkerAfter(_marker, ''), _marker);
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
