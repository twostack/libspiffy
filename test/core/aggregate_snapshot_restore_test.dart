/// Audit 2026-09-14 M6 (libspiffy-q1o): aggregate snapshots.
///
/// No aggregate overrode `restoreStateFromMap`, so eventador's recovery threw
/// on every stored snapshot, fell back to the empty initial state, and then
/// replayed only the events AFTER the snapshot: every event up to the
/// snapshot was silently lost (a wallet came back as "not created"). The
/// states also could not be written completely: `BitcoinUtxo.toMap` dropped
/// the reservation fields, and `ChannelState` / `InvoiceState` inherited the
/// base `State.toMap` (version and timestamp only).
///
/// Each test takes a snapshot midway through a journal, appends the rest of
/// the journal, restarts the aggregate from the store, and checks that the
/// state equals a full replay of the same journal. The store serializes
/// snapshots with eventador's CBOR serializer and reads events after a
/// sequence number exclusively, as the Isar and Postgres event stores do.
library;

import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/channel_state.dart';
import 'package:libspiffy/src/core/invoice_aggregate.dart';
import 'package:libspiffy/src/core/invoice_events.dart';
import 'package:libspiffy/src/core/payment_channel_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/models/invoice_state.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/models/address_chain.dart';

import 'wallet_event_fixtures.dart';

/// In-memory event store with snapshots (CBOR-serialized, like the real
/// stores) and exclusive `fromSequence`.
class _SnapshotStore implements EventStore {
  final Map<String, List<Event>> journal = {};
  final Map<String, ({List<int> bytes, int sequenceNumber, String type})> snapshots = {};

  void append(String persistenceId, Iterable<Event> events) =>
      journal.putIfAbsent(persistenceId, () => []).addAll(events);

  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async =>
      append(persistenceId, [event]);

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async =>
      append(persistenceId, events);

  @override
  Future<List<Event>> getEvents(String persistenceId, {int fromSequence = 0, int? toSequence}) async {
    final events = journal[persistenceId] ?? const <Event>[];
    final end = toSequence == null || toSequence > events.length ? events.length : toSequence;
    if (fromSequence >= end) return const [];
    return events.sublist(fromSequence, end);
  }

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async =>
      journal[persistenceId]?.length ?? 0;

  @override
  Future<void> saveSnapshot(String persistenceId, dynamic state, int sequenceNumber) async {
    snapshots[persistenceId] = (
      bytes: CborSerializer.serializeState(state),
      sequenceNumber: sequenceNumber,
      type: state is State ? state.typeName : state.runtimeType.toString(),
    );
  }

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async {
    final s = snapshots[persistenceId];
    if (s == null) return null;
    return SnapshotData(
      state: CborSerializer.deserializeState(s.bytes, s.type),
      sequenceNumber: s.sequenceNumber,
      timestamp: DateTime.utc(2026),
    );
  }

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}

// ---------------------------------------------------------------------------
// Aggregates that can be told to snapshot (createSnapshot is protected).
// ---------------------------------------------------------------------------

class _Wallet extends BitcoinWalletAggregate {
  _Wallet(EventStore store, InMemorySecureStorage secureStorage, String id)
      : super(
          aggregateId: id,
          aggregateType: 'BitcoinWallet',
          eventStore: store,
          cryptoService: DartSVCryptoService(),
          secureStorage: secureStorage,
        );

  Future<void> snapshotNow() => createSnapshot();
}

class _Invoice extends InvoiceAggregate {
  _Invoice(EventStore store, String id)
      : super(aggregateId: id, aggregateType: 'Invoice', eventStore: store);

  Future<void> snapshotNow() => createSnapshot();
}

class _Channel extends PaymentChannelAggregate {
  _Channel(EventStore store, String id)
      : super(aggregateId: id, eventStore: store, cryptoService: DartSVCryptoService());

  Future<void> snapshotNow() => createSnapshot();
}

/// Snapshots after [before], appends [after], and returns the aggregate
/// restarted from the snapshot plus the tail, and one replayed from scratch.
Future<(T restored, T replayed)> _snapshotAndRestart<T extends PersistentActor>({
  required String persistenceId,
  required List<Event> before,
  required List<Event> after,
  required T Function(EventStore store) create,
  required Future<void> Function(T aggregate) snapshot,
}) async {
  final store = _SnapshotStore()..append(persistenceId, before);
  final first = create(store);
  await first.preStart();
  await snapshot(first);
  expect(store.snapshots[persistenceId]?.sequenceNumber, before.length,
      reason: 'the snapshot was taken');
  store.append(persistenceId, after);

  final restored = create(store);
  await restored.preStart();

  final plain = _SnapshotStore()..append(persistenceId, [...before, ...after]);
  final replayed = create(plain);
  await replayed.preStart();
  return (restored, replayed);
}

void main() {
  group('M6: wallet snapshot', () {
    const walletId = 'snapshot-wallet';
    const persistenceId = 'BitcoinWallet_$walletId';

    List<WalletEvent> journal() {
      final j = WalletJournalBuilder(walletId)..created();
      j.address('mreceive1', 1, label: 'first');
      j.address('mchange1', 1, change: true);
      j.events.add(AddressDiscoveredEvent(
        walletId: walletId,
        address: 'mdiscovered7',
        derivationIndex: 7,
        chain: AddressChain.change,
        transactionCount: 2,
        version: j.events.length + 1,
        timestamp: DateTime.utc(2021, 5, 1),
      ));
      // A watch address (bead libspiffy-p4kv).
      j.events.add(WatchAddressAddedEvent(
        walletId: walletId,
        address: 'mwatched1',
        scriptType: 'p2pkh',
        label: 'cold',
        registeredAt: DateTime.utc(2021, 5, 2),
        version: j.events.length + 1,
        timestamp: DateTime.utc(2021, 5, 2),
      ));
      j.received(1, 0, sats: 5000, status: UTXOStatus.available, confirmations: 7);
      j.received(2, 1, sats: 3000, pluginMetadata: {
        'pluginId': 'tok',
        'scriptType': 'token',
        'amount': 12,
        'nested': {'owner': 'mreceive1', 'ids': [1, 2, 3]},
      });
      j.received(3, 0, sats: 2000);
      // Expires far in the future, so the reservation is live when the
      // restored wallet checks its priority.
      j.reserved(1, 0, by: 'pay-1', priority: 5, expiresAt: DateTime.utc(2999));
      j.reserved(3, 0, by: 'pay-2');
      j.imported(10);
      j.recorded(11);
      return j.events;
    }

    List<WalletEvent> tail(int firstVersion) {
      final j = WalletJournalBuilder(walletId, start: DateTime.utc(2022), firstVersion: firstVersion);
      j.confirmed(3, 0, 2);
      j.released(3, 0, restored: UTXOStatus.available);
      j.spent(2, 1);
      j.received(4, 0, sats: 700);
      j.txConfirmed(11);
      j.imported(12);
      return j.events;
    }

    test('restart from a snapshot equals a full replay', () async {
      final before = journal();
      final after = tail(before.length + 1);
      final secureStorage = InMemorySecureStorage();

      final (restored, replayed) = await _snapshotAndRestart<_Wallet>(
        persistenceId: persistenceId,
        before: before,
        after: after,
        create: (store) => _Wallet(store, secureStorage, walletId),
        snapshot: (w) => w.snapshotNow(),
      );

      expect(restored.currentState.isCreated, isTrue,
          reason: 'history before the snapshot must survive the restart');
      expect(restored.currentState.version, before.length + after.length);
      expect(restored.currentState.toMap(), replayed.currentState.toMap());
      expect(restored.currentState.watchAddresses, {'mwatched1': 'p2pkh'},
          reason: 'a watch address journaled before the snapshot survives the restart');

      final reserved =restored.currentState.utxos['${WalletJournalBuilder.txid(1)}:0']!;
      expect(reserved.status, UTXOStatus.reserved);
      expect(reserved.reservedByTxId, 'pay-1');
      expect(reserved.reservationPriority, 5);
      expect(reserved.reservationReason, 'reason pay-1');
      expect(reserved.reservationExpiresAt,
          before.whereType<UTXOReservedEvent>().first.expiresAt);
      expect(reserved.statusBeforeReservation, UTXOStatus.available);
      expect(restored.currentState.reservedBalance.getValue(),
          replayed.currentState.reservedBalance.getValue());

      // History survives: the spent UTXO with its spending transaction, and
      // both transaction logs.
      final spent = restored.currentState.utxos['${WalletJournalBuilder.txid(2)}:1']!;
      expect(spent.status, UTXOStatus.spent);
      expect(spent.toMap()['spentInTxId'], after.whereType<UTXOSpentEvent>().single.spentInTxId);
      expect(spent.pluginMetadata?['nested'], {'owner': 'mreceive1', 'ids': [1, 2, 3]});
      for (final log in ['importedTransactions', 'outgoingTransactions']) {
        expect((restored.currentState.metadata[log] as Map).keys.toList(),
            (replayed.currentState.metadata[log] as Map).keys.toList(),
            reason: '$log keeps every transaction, in journal order');
      }
      expect((restored.currentState.metadata['importedTransactions'] as Map).length, 2);
      expect(restored.currentState.utxos.keys.toList(), replayed.currentState.utxos.keys.toList());
      expect((restored.currentState.metadata['outgoingTransactions'] as Map)
          [WalletJournalBuilder.txid(11)]['status'], 'confirmed');
      expect(restored.currentState.utxos.length, 4);
    });

    test('a restored wallet enforces reservation priority and keeps the derivation records',
        () async {
      final before = journal();
      final secureStorage = InMemorySecureStorage();
      final (restored, _) = await _snapshotAndRestart<_Wallet>(
        persistenceId: persistenceId,
        before: before,
        after: const [],
        create: (store) => _Wallet(store, secureStorage, walletId),
        snapshot: (w) => w.snapshotNow(),
      );

      // Reserved at priority 5 before the snapshot: a priority-3 reservation
      // must still be refused after the restore.
      await expectLater(
        restored.commandHandler(ReserveUTXOCommand(
          walletId: walletId,
          utxoKey: '${WalletJournalBuilder.txid(1)}:0',
          reservedByTxId: 'late',
          priority: 3,
        )),
        throwsA(isA<StateError>()),
      );

      final metadata = restored.currentState.metadata;
      expect(metadata['address_indices'], {
        'mrootaddress0000000000000000000000': 0,
        'mreceive1': 1,
        'mchange1': 1,
        'mdiscovered7': 7,
      });
      // Each address's AddressChain.index (bead libspiffy-m8qu).
      expect(metadata['address_chains'], {
        'mrootaddress0000000000000000000000': AddressChain.receive.index,
        'mreceive1': AddressChain.receive.index,
        'mchange1': AddressChain.change.index,
        'mdiscovered7': AddressChain.change.index,
      });
      expect(restored.currentState.nextDerivationIndex, 8);
    });
  });

  group('M6: a snapshot that cannot be restored', () {
    // Eventador's default reaction was to continue from the empty state with
    // only the events after the snapshot: the history silently disappeared.
    Future<PersistentActor> recoverWithBadSnapshot(
        String persistenceId, PersistentActor Function(EventStore) create, List<Event> journal) async {
      final store = _SnapshotStore()..append(persistenceId, journal);
      await store.saveSnapshot(persistenceId, {'unexpected': 'shape'}, 1);
      final actor = create(store);
      await actor.preStart();
      return actor;
    }

    test('fails wallet recovery', () async {
      final j = WalletJournalBuilder('bad-wallet')..created();
      j.received(1, 0);
      final wallet = await recoverWithBadSnapshot('BitcoinWallet_bad-wallet',
          (store) => _Wallet(store, InMemorySecureStorage(), 'bad-wallet'), j.events);
      expect(wallet.isRecovered, isFalse);
      await expectLater(wallet.recoveryComplete, throwsA(isA<StateError>()));
    });

    test('fails invoice recovery', () async {
      final invoice = await recoverWithBadSnapshot('Invoice_bad-invoice',
          (store) => _Invoice(store, 'bad-invoice'), const []);
      expect(invoice.isRecovered, isFalse);
    });

    test('fails channel recovery', () async {
      final channel = await recoverWithBadSnapshot('PaymentChannel_bad-channel',
          (store) => _Channel(store, 'bad-channel'), const []);
      expect(channel.isRecovered, isFalse);
    });
  });

  group('M6: invoice snapshot', () {
    const invoiceId = 'snapshot-invoice';
    const persistenceId = 'Invoice_$invoiceId';

    test('restart from a snapshot equals a full replay', () async {
      final created = InvoiceCreatedEvent(
        invoiceId: invoiceId,
        walletId: 'w1',
        addresses: const ['maddr1', 'maddr2'],
        amount: BigInt.from(123456789),
        outputs: [
          P2PKHOutputSpec(address: 'maddr1', amount: BigInt.from(100000000), label: 'main'),
          OPReturnOutputSpec(dataChunks: const [[104, 101, 108, 108, 111]]),
        ],
        description: 'Coffee',
        expiresAt: DateTime.utc(2030, 1, 2, 3, 4, 5),
        invoiceMetadata: {'order': 'A-1', 'lines': [1, 2]},
        version: 1,
        timestamp: DateTime.utc(2025, 6, 1),
      );
      final paid = InvoicePaidEvent(
        invoiceId: invoiceId,
        walletId: 'w1',
        txid: 'ab' * 32,
        amountReceived: BigInt.from(123456790),
        addressesPaidTo: const ['maddr1'],
        paidAt: DateTime.utc(2025, 6, 2),
        version: 2,
        timestamp: DateTime.utc(2025, 6, 2, 0, 1),
      );

      final (restored, replayed) = await _snapshotAndRestart<_Invoice>(
        persistenceId: persistenceId,
        before: [created],
        after: [paid],
        create: (store) => _Invoice(store, invoiceId),
        snapshot: (i) => i.snapshotNow(),
      );

      expect(restored.currentState.isCreated, isTrue,
          reason: 'history before the snapshot must survive the restart');
      expect(_invoiceFields(restored.currentState), _invoiceFields(replayed.currentState));
      expect(restored.currentState.status, InvoiceStatus.paid);
    });
  });

  group('M6: payment channel snapshot', () {
    const channelId = 'snapshot-channel';
    const persistenceId = 'PaymentChannel_$channelId';

    test('restart from a snapshot equals a full replay', () async {
      final t0 = DateTime.utc(2025, 7, 1);
      final before = <Event>[
        ChannelRequestedEvent(
          channelId: channelId,
          walletId: 'w1',
          clientPeerId: 'client-peer',
          serverPeerId: 'server-peer',
          clientPubKeyHex: '02${'11' * 32}',
          clientAddressB58: 'mclient',
          derivationIndex: 4,
          fundingAmountSats: BigInt.from(50000),
          lockTimeUnix: 1900000000,
          context: 'ctx',
          version: 1,
          timestamp: t0,
        ),
        ServerAcceptanceRecordedEvent(
          channelId: channelId,
          serverPubKeyHex: '03${'22' * 32}',
          serverAddressB58: 'mserver',
          version: 2,
          timestamp: t0.add(const Duration(minutes: 1)),
        ),
        RefundBuiltEvent(
          channelId: channelId,
          fundingTxId: 'cd' * 32,
          fundingOutputIndex: 1,
          fundingTxHex: '0100',
          refundTxHex: '0200',
          clientSignatureHex: '3044',
          version: 3,
          timestamp: t0.add(const Duration(minutes: 2)),
        ),
        RefundCountersignedEvent(
          channelId: channelId,
          serverSignatureHex: '3045',
          version: 4,
          timestamp: t0.add(const Duration(minutes: 3)),
        ),
        ChannelOpenedEvent(
          channelId: channelId,
          fundingTxId: 'cd' * 32,
          fundingOutputIndex: 1,
          fundingTxHex: '0100',
          fundingAncestorTxids: ['ef' * 32],
          initialClientBalanceSats: BigInt.from(50000),
          initialServerBalanceSats: BigInt.zero,
          version: 5,
          timestamp: t0.add(const Duration(minutes: 4)),
        ),
      ];
      final after = <Event>[
        PaymentRecordedEvent(
          channelId: channelId,
          amountSats: BigInt.from(1000),
          newClientBalanceSats: BigInt.from(49000),
          newServerBalanceSats: BigInt.from(1000),
          sequenceNumber: 1,
          paymentTxHex: '0300',
          paymentTxId: '12' * 32,
          clientSignatureHex: '3046',
          version: 6,
          timestamp: t0.add(const Duration(minutes: 5)),
        ),
      ];

      final (restored, replayed) = await _snapshotAndRestart<_Channel>(
        persistenceId: persistenceId,
        before: before,
        after: after,
        create: (store) => _Channel(store, channelId),
        snapshot: (c) => c.snapshotNow(),
      );

      expect(restored.currentState.status, ChannelStatus.open,
          reason: 'history before the snapshot must survive the restart');
      expect(_channelFields(restored.currentState), _channelFields(replayed.currentState));
    });
  });
}

Map<String, dynamic> _invoiceFields(InvoiceState s) => {
      'invoiceId': s.invoiceId,
      'isCreated': s.isCreated,
      'walletId': s.walletId,
      'addresses': s.addresses,
      'amount': s.amount,
      'outputs': s.outputs?.map((o) => o.toMap()).toList(),
      'description': s.description,
      'status': s.status,
      'createdAt': s.createdAt,
      'expiresAt': s.expiresAt,
      'paidAt': s.paidAt,
      'paymentTxid': s.paymentTxid,
      'amountReceived': s.amountReceived,
      'metadata': s.metadata,
      'version': s.version,
      'lastModified': s.lastModified,
    };

Map<String, dynamic> _channelFields(ChannelState s) => {
      'channelId': s.channelId,
      'walletId': s.walletId,
      'status': s.status,
      'role': s.role,
      'clientPeerId': s.clientPeerId,
      'serverPeerId': s.serverPeerId,
      'clientPubKeyHex': s.clientPubKeyHex,
      'serverPubKeyHex': s.serverPubKeyHex,
      'clientAddressB58': s.clientAddressB58,
      'serverAddressB58': s.serverAddressB58,
      'derivationIndex': s.derivationIndex,
      'fundingAmountSats': s.fundingAmountSats,
      'fundingTxId': s.fundingTxId,
      'fundingTxHex': s.fundingTxHex,
      'fundingOutputIndex': s.fundingOutputIndex,
      'fundingAncestorTxids': s.fundingAncestorTxids,
      'lockTimeUnix': s.lockTimeUnix,
      'refundTxHex': s.refundTxHex,
      'refundClientSigHex': s.refundClientSigHex,
      'refundServerSigHex': s.refundServerSigHex,
      'clientBalanceSats': s.clientBalanceSats,
      'serverBalanceSats': s.serverBalanceSats,
      'latestSequenceNumber': s.latestSequenceNumber,
      'latestPaymentTxHex': s.latestPaymentTxHex,
      'latestPaymentTxId': s.latestPaymentTxId,
      'context': s.context,
      'createdAt': s.createdAt,
      'closedAt': s.closedAt,
      'version': s.version,
      'lastModified': s.lastModified,
    };
