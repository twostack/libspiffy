/// Bead libspiffy-7p2: the wallet aggregate holds a deferred payment's inputs
/// until the network settles it, ARC reports it definitively failed, or it is
/// cancelled; nothing else (reservation expiry, cleanup, other reservations)
/// releases or takes them. Holds, failures and cancellations are journaled
/// and survive a replay and a snapshot; journals written before holds are
/// reconciled.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/deferred_payment.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

const _w = 'deferred-wallet';
final _input = '${'a1' * 32}:0';
final _pendingInput = '${'b2' * 32}:1';
final _other = '${'c3' * 32}:2';

class _NoStore implements EventStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

BitcoinWalletAggregate _aggregate() => BitcoinWalletAggregate(
      aggregateId: _w,
      aggregateType: 'BitcoinWallet',
      eventStore: _NoStore(),
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );

/// A transaction spending [inputs] to a foreign address (outputs are not the
/// wallet's), as recorded by the payment coordinator.
String _paymentHex(List<String> inputs, {int sats = 1000}) {
  final tx = dartsv.Transaction();
  for (final key in inputs) {
    final parts = key.split(':');
    tx.addInput(dartsv.TransactionInput(parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
  }
  tx.addOutput(dartsv.TransactionOutput(
      BigInt.from(sats), dartsv.SVScript.fromHex('76a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac')));
  return tx.serialize();
}

/// A live aggregate: commands are handled against its state and their events
/// applied and kept as the journal.
class _Wallet {
  final BitcoinWalletAggregate aggregate = _aggregate();
  final List<Event> journal = [];

  _Wallet() {
    apply([
      WalletCreatedEvent(
        walletId: _w,
        walletName: 'w',
        rootAddress: 'mrootaddress0000000000000000000000',
        walletType: WalletType.hd,
        walletMetadata: {'network': 'testnet'},
        version: 1,
        timestamp: DateTime.utc(2026),
      ),
    ]);
    receive(_input, UTXOStatus.available, 20000);
    receive(_pendingInput, UTXOStatus.pending, 5000);
    receive(_other, UTXOStatus.available, 7000);
  }

  void apply(List<Event> events) {
    for (final e in events) {
      aggregate.eventHandler(e);
      journal.add(e);
    }
  }

  void receive(String key, UTXOStatus status, int sats) {
    final parts = key.split(':');
    apply([
      UTXOReceivedEvent(
        walletId: _w,
        txid: parts[0],
        vout: int.parse(parts[1]),
        satoshis: sats,
        scriptPubKey: '76a914${'00' * 20}88ac',
        address: 'mrootaddress0000000000000000000000',
        initialStatus: status,
        version: aggregate.currentState.version + 1,
        timestamp: DateTime.utc(2026),
      ),
    ]);
  }

  Future<List<Event>> handle(WalletCommand command) async {
    final events = await aggregate.handleCommand(aggregate.currentState, command);
    apply(events);
    return events;
  }

  BitcoinUtxo utxo(String key) => aggregate.currentState.utxos[key]!;

  Map deferred(String txid) => (aggregate.currentState.metadata['deferredSpends'] as Map)[txid] as Map;

  /// The coordinator's 2-minute payment reservation, then the recording.
  Future<String> pay(List<String> inputs, {int sats = 1000, bool reserve = true}) async {
    for (final key in inputs) {
      if (reserve && utxo(key).status == UTXOStatus.available) {
        await handle(ReserveUTXOCommand(
          walletId: _w,
          utxoKey: key,
          reservedByTxId: 'payment-inv-$sats',
          reservationDuration: const Duration(minutes: 2),
        ));
      }
    }
    final rawHex = _paymentHex(inputs, sats: sats);
    final txid = dartsv.Transaction.fromHex(rawHex).id;
    await handle(RecordOutgoingTransactionCommand(
      walletId: _w,
      txid: txid,
      rawHex: rawHex,
      totalInputSats: 25000,
      totalOutputSats: sats,
      fee: 100,
      numInputs: inputs.length,
      numOutputs: 1,
      txVersion: 1,
      txLockTime: 0,
      spentUtxoKeys: inputs,
      recipientAddresses: const ['muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg'],
      paymentAmount: BigInt.from(sats),
      deferSpend: true,
      invoiceId: 'inv-$sats',
      purpose: 'invoice-payment',
    ));
    return txid;
  }

  /// A fresh aggregate replaying [journal].
  BitcoinWalletAggregate replay() {
    final fresh = _aggregate();
    for (final e in journal) {
      fresh.eventHandler(e);
    }
    return fresh;
  }
}

void main() {
  group('hold', () {
    test('a deferred recording holds its unspent inputs: reserved by the txid, no expiry', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input, _pendingInput]);

      final hold = wallet.journal.whereType<TransactionSpendDeferredEvent>().single;
      expect(hold.txid, txid);
      expect(hold.heldUtxoKeys, [_input, _pendingInput]);
      expect(hold.invoiceId, 'inv-1000');
      for (final key in [_input, _pendingInput]) {
        final utxo = wallet.utxo(key);
        expect(utxo.status, UTXOStatus.reserved);
        expect(utxo.reservedByTxId, txid);
        expect(utxo.reservationExpiresAt, isNull);
      }
      expect(wallet.utxo(_pendingInput).statusBeforeReservation, UTXOStatus.pending);
      expect(wallet.deferred(txid)['state'], 'outstanding');
    });

    test('reservation expiry and CleanupExpiredReservations release nothing it holds', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      // An unrelated expired reservation is still cleaned up.
      await wallet.handle(ReserveUTXOCommand(
          walletId: _w, utxoKey: _other, reservedByTxId: 'x', reservationDuration: const Duration(minutes: 1)));

      final events = await wallet.handle(CleanupExpiredReservationsCommand(
          walletId: _w, cutoffTime: DateTime.now().add(const Duration(days: 30))));

      expect([for (final e in events.whereType<UTXOReleasedEvent>()) '${e.txid}:${e.vout}'], [_other]);
      expect(wallet.utxo(_input).status, UTXOStatus.reserved);
      expect(wallet.utxo(_input).reservedByTxId, txid);
    });

    test('no reservation of any priority takes a held input; release and renew are refused', () async {
      final wallet = _Wallet();
      await wallet.pay([_input]);

      expect(
          () => wallet.handle(ReserveUTXOCommand(
              walletId: _w, utxoKey: _input, reservedByTxId: 'thief', priority: 1 << 31)),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('held by deferred payment'))));
      expect(
          () => wallet.handle(ReserveUTXOsCommand(walletId: _w, utxoKeys: [_input, _other], reservationId: 'r')),
          throwsA(isA<StateError>()));
      expect(await wallet.handle(ReleaseUTXOsCommand(walletId: _w, reservationId: 'payment-inv-1000')), isEmpty);
      expect(() => wallet.handle(ReleaseUTXOCommand(walletId: _w, utxoKey: _input, releaseReason: 'r')),
          throwsA(isA<StateError>()));
      expect(
          () => wallet.handle(RenewUTXOReservationCommand(
              walletId: _w, utxoKey: _input, extensionDuration: const Duration(minutes: 1))),
          throwsA(isA<StateError>()));
      expect(wallet.utxo(_input).status, UTXOStatus.reserved);
    });

    test('the hold survives a journal replay and a snapshot round trip', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);

      final replayed = wallet.replay();
      expect(replayed.currentState.utxos[_input]!.reservedByTxId, txid);
      expect(() => replayed.handleCommand(replayed.currentState,
              ReserveUTXOCommand(walletId: _w, utxoKey: _input, reservedByTxId: 'thief', priority: 99)),
          throwsA(isA<StateError>()));

      final state = wallet.aggregate.currentState;
      final bytes = CborSerializer.serializeState(state);
      final restoredMap = CborSerializer.deserializeState(bytes, state.typeName);
      final restored = _aggregate();
      final restoredState = await restored.restoreStateFromMap(
          restoredMap is Map<String, dynamic> ? restoredMap : (restoredMap as dynamic).toMap() as Map<String, dynamic>,
          state.version);
      expect(() => restored.handleCommand(restoredState,
              ReserveUTXOCommand(walletId: _w, utxoKey: _input, reservedByTxId: 'thief', priority: 99)),
          throwsA(isA<StateError>()));
      final cleanup = await restored.handleCommand(restoredState,
          CleanupExpiredReservationsCommand(walletId: _w, cutoffTime: DateTime.now().add(const Duration(days: 1))));
      expect(cleanup, isEmpty);
    });
  });

  group('resolution', () {
    test('the transaction spending its inputs (SEEN_ON_NETWORK / MINED): spent once, payment seen', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);

      final spent = await wallet.handle(
          SpendUTXOCommand(walletId: _w, utxoKey: _input, spendingTxId: txid, fee: BigInt.zero));
      expect(spent.single, isA<UTXOSpentEvent>());
      expect(wallet.utxo(_input).status, UTXOStatus.spent);
      expect(wallet.deferred(txid)['state'], 'seen');
      expect((wallet.aggregate.currentState.metadata['deferredHolds'] as Map), isEmpty);
      expect(() => wallet.handle(SpendUTXOCommand(walletId: _w, utxoKey: _input, spendingTxId: txid, fee: BigInt.zero)),
          throwsA(isA<StateError>()), reason: 'spent once');

      await wallet.handle(ConfirmTransactionCommand(walletId: _w, txid: txid, blockHeight: 10, blockHash: 'h'));
      expect(wallet.deferred(txid)['state'], 'mined');
      await wallet.handle(RevertTransactionConfirmationCommand(walletId: _w, txid: txid, reason: 'reorg'));
      expect(wallet.deferred(txid)['state'], 'seen');
      expect(wallet.replay().currentState.metadata['deferredSpends'][txid]['state'], 'seen');
    });

    for (final status in [DeferredNetworkStatus.rejected]) {
      test('ARC $status: the payment fails and its inputs return to their previous status, journaled', () async {
        final wallet = _Wallet();
        final txid = await wallet.pay([_input, _pendingInput]);

        final events = await wallet.handle(RecordTransactionNetworkStatusCommand(
            walletId: _w, txid: txid, networkStatus: status, detail: 'arc says no'));

        expect(events.map((e) => e.runtimeType),
            [TransactionNetworkStatusCheckedEvent, DeferredTransactionFailedEvent]);
        final failed = events.last as DeferredTransactionFailedEvent;
        expect({for (final r in failed.releasedInputs) r.utxoKey: r.restoredStatus},
            {_input: UTXOStatus.available, _pendingInput: UTXOStatus.pending});
        expect(wallet.utxo(_input).status, UTXOStatus.available);
        expect(wallet.utxo(_pendingInput).status, UTXOStatus.pending);
        expect(wallet.deferred(txid)['state'], 'failed');

        final replayed = wallet.replay().currentState;
        expect(replayed.utxos[_input]!.status, UTXOStatus.available);
        expect(replayed.metadata['deferredSpends'][txid]['state'], 'failed');
        // Reservable again.
        await wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: _input, reservedByTxId: 'next'));
      });
    }

    group('ey2: DOUBLE_SPEND_ATTEMPTED is not final (ARC may still mine the payment)', () {
      test('recorded and journaled; the payment stays outstanding with its inputs held', () async {
        final wallet = _Wallet();
        final txid = await wallet.pay([_input, _pendingInput]);

        final events = await wallet.handle(RecordTransactionNetworkStatusCommand(
            walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.doubleSpendAttempted, detail: 'contested'));

        // Old code: [TransactionNetworkStatusCheckedEvent, DeferredTransactionFailedEvent], inputs released.
        expect(events.map((e) => e.runtimeType), [TransactionNetworkStatusCheckedEvent]);
        expect(wallet.utxo(_input).status, UTXOStatus.reserved);
        expect(wallet.utxo(_input).reservedByTxId, txid);
        expect(wallet.utxo(_pendingInput).status, UTXOStatus.reserved);
        expect(wallet.deferred(txid)['state'], 'outstanding');
        expect(wallet.deferred(txid)['lastNetworkStatus'], DeferredNetworkStatus.doubleSpendAttempted);
        expect(() => wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: _input, reservedByTxId: 'third')),
            throwsA(isA<StateError>()), reason: 'a contested input is not handed to a third spend');
        final replayed = wallet.replay().currentState;
        expect(replayed.utxos[_input]!.status, UTXOStatus.reserved);
        expect(replayed.metadata['deferredSpends'][txid]['state'], 'outstanding');
      });

      test('then ARC reports ours on the network: the spend applies (seen)', () async {
        final wallet = _Wallet();
        final txid = await wallet.pay([_input]);
        await wallet.handle(RecordTransactionNetworkStatusCommand(
            walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.doubleSpendAttempted));

        await wallet.handle(RecordTransactionNetworkStatusCommand(
            walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.mined));
        await wallet.handle(SpendUTXOCommand(walletId: _w, utxoKey: _input, spendingTxId: txid, fee: BigInt.zero));

        expect(wallet.utxo(_input).status, UTXOStatus.spent);
        expect(wallet.deferred(txid)['state'], 'seen');
      });

      test('then ARC reports ours REJECTED: failed, inputs released', () async {
        final wallet = _Wallet();
        final txid = await wallet.pay([_input]);
        await wallet.handle(RecordTransactionNetworkStatusCommand(
            walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.doubleSpendAttempted));

        final events = await wallet.handle(RecordTransactionNetworkStatusCommand(
            walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.rejected));

        expect(events.last, isA<DeferredTransactionFailedEvent>());
        expect(wallet.utxo(_input).status, UTXOStatus.available);
        expect(wallet.deferred(txid)['state'], 'failed');
      });

      test('the user may cancel a contested payment: inputs released', () async {
        final wallet = _Wallet();
        final txid = await wallet.pay([_input]);
        await wallet.handle(RecordTransactionNetworkStatusCommand(
            walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.doubleSpendAttempted));

        final events = await wallet.handle(CancelDeferredSpendCommand(
            walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.doubleSpendAttempted));

        expect(events.single, isA<DeferredTransactionCancelledEvent>());
        expect(wallet.utxo(_input).status, UTXOStatus.available);
        expect(DeferredNetworkStatus.allowsCancel(DeferredNetworkStatus.doubleSpendAttempted), isTrue);
      });

      test('pkum: ARC\'s competing txids are journaled with the status; a new competitor is journaled again, '
          'the same report is not; a replay keeps them', () async {
        final wallet = _Wallet();
        final txid = await wallet.pay([_input]);
        final rivalA = 'd4' * 32;
        final rivalB = 'e5' * 32;
        RecordTransactionNetworkStatusCommand contested(List<String> competing) => RecordTransactionNetworkStatusCommand(
            walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.doubleSpendAttempted, competingTxids: competing);

        final first = await wallet.handle(contested([rivalA]));
        expect((first.single as TransactionNetworkStatusCheckedEvent).competingTxids, [rivalA]);
        expect(await wallet.handle(contested([rivalA])), isEmpty, reason: 'the same report again: nothing new');
        final second = await wallet.handle(contested([rivalB, rivalA]));
        expect((second.single as TransactionNetworkStatusCheckedEvent).competingTxids, [rivalB, rivalA]);
        expect(wallet.deferred(txid)['competingTxids'], [rivalA, rivalB]);
        expect(wallet.deferred(txid)['state'], 'outstanding');
        expect(wallet.utxo(_input).status, UTXOStatus.reserved);

        // Through the journal's serialized form.
        final stored = [for (final e in wallet.journal) e is TransactionNetworkStatusCheckedEvent
            ? TransactionNetworkStatusCheckedEvent.fromMap(e.toMap()) : e];
        expect([for (final e in stored.whereType<TransactionNetworkStatusCheckedEvent>()) e.competingTxids],
            [[rivalA], [rivalB, rivalA]]);
        final fresh = _aggregate();
        for (final e in stored) {
          fresh.eventHandler(e);
        }
        expect(fresh.currentState.metadata['deferredSpends'][txid]['competingTxids'], [rivalA, rivalB]);
        expect(fresh.currentState.utxos[_input]!.status, UTXOStatus.reserved);
      });

      test('pkum: a status event journaled before competing txids existed replays with none', () async {
        final wallet = _Wallet();
        final txid = await wallet.pay([_input]);
        final at = DateTime.utc(2026, 3);
        final v = wallet.aggregate.currentState.version;
        final written = TransactionNetworkStatusCheckedEvent(
                walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.doubleSpendAttempted, source: 'arc',
                checkedAt: at, version: v + 1, timestamp: at)
            .toMap();
        expect(written.containsKey('competingTxids'), isFalse, reason: 'an event without any is written as before');
        // As the code before pkum wrote it.
        final old = Map<String, dynamic>.of(written)..remove('competingTxids');

        final event = TransactionNetworkStatusCheckedEvent.fromMap(old);
        expect(event.competingTxids, isEmpty);
        wallet.apply([event]);
        final replayed = wallet.replay().currentState;
        expect(replayed.metadata['deferredSpends'][txid]['lastNetworkStatus'], DeferredNetworkStatus.doubleSpendAttempted);
        expect(replayed.metadata['deferredSpends'][txid]['competingTxids'], isNull);
        expect(replayed.metadata['deferredSpends'][txid]['state'], 'outstanding');
        expect(replayed.utxos[_input]!.status, UTXOStatus.reserved);
        expect(replayed.version, v + 1);

        // ARC names the competitor later: journaled, although the status did not change.
        final named = await wallet.handle(RecordTransactionNetworkStatusCommand(
            walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.doubleSpendAttempted,
            competingTxids: ['f6' * 32]));
        expect((named.single as TransactionNetworkStatusCheckedEvent).competingTxids, ['f6' * 32]);
      });

      test('a journal where DOUBLE_SPEND_ATTEMPTED already failed the payment replays unchanged', () async {
        final wallet = _Wallet();
        final txid = await wallet.pay([_input]);
        final at = DateTime.utc(2026, 3);
        final v = wallet.aggregate.currentState.version;
        // Written by the code before ey2.
        wallet.apply([
          TransactionNetworkStatusCheckedEvent(
              walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.doubleSpendAttempted, source: 'arc',
              checkedAt: at, version: v + 1, timestamp: at),
          DeferredTransactionFailedEvent.fromMap(DeferredTransactionFailedEvent(
              walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.doubleSpendAttempted,
              reason: 'arc reported DOUBLE_SPEND_ATTEMPTED',
              releasedInputs: [ReleasedDeferredInput(utxoKey: _input, restoredStatus: UTXOStatus.available)],
              version: v + 2, timestamp: at).toMap()),
        ]);

        final replayed = wallet.replay().currentState;
        expect(replayed.utxos[_input]!.status, UTXOStatus.available);
        expect(replayed.metadata['deferredSpends'][txid]['state'], 'failed');
        expect(replayed.metadata['deferredSpends'][txid]['lastNetworkStatus'], DeferredNetworkStatus.doubleSpendAttempted);
        expect(replayed.version, v + 2);
      });
    });

    for (final status in [
      DeferredNetworkStatus.notFound,
      DeferredNetworkStatus.seenInOrphanMempool,
      'STORED',
      'UNKNOWN',
    ]) {
      test('$status is not definitive: recorded, the inputs stay held', () async {
        final wallet = _Wallet();
        final txid = await wallet.pay([_input]);

        final events = await wallet.handle(
            RecordTransactionNetworkStatusCommand(walletId: _w, txid: txid, networkStatus: status));

        expect(events.single, isA<TransactionNetworkStatusCheckedEvent>());
        expect(wallet.utxo(_input).status, UTXOStatus.reserved);
        expect(wallet.deferred(txid)['state'], 'outstanding');
        expect(wallet.deferred(txid)['lastNetworkStatus'], status);
      });
    }

    test('an unchanged status is journaled once unless explicit; other txids are ignored', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      final notFound =
          RecordTransactionNetworkStatusCommand(walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.notFound);
      expect(await wallet.handle(notFound), hasLength(1));
      expect(await wallet.handle(RecordTransactionNetworkStatusCommand(
          walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.notFound)), isEmpty);
      expect(await wallet.handle(RecordTransactionNetworkStatusCommand(
          walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.notFound, explicit: true)), hasLength(1));
      expect(await wallet.handle(RecordTransactionNetworkStatusCommand(
          walletId: _w, txid: 'ff' * 32, networkStatus: DeferredNetworkStatus.rejected)), isEmpty);
    });

    test('SEEN_ON_NETWORK recorded: the payment is seen (the spend follows from ARCActor)', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      await wallet.handle(RecordTransactionNetworkStatusCommand(
          walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.seenOnNetwork));
      expect(wallet.deferred(txid)['state'], 'seen');
      expect(() => wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid)), throwsA(isA<StateError>()));
    });
  });

  group('cancel', () {
    test('an outstanding payment the network does not know: cancelled, inputs released, journaled', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input, _pendingInput]);

      final events = await wallet.handle(CancelDeferredSpendCommand(
          walletId: _w, txid: txid, reason: 'recipient vanished', networkStatus: DeferredNetworkStatus.notFound));

      final cancelled = events.single as DeferredTransactionCancelledEvent;
      expect(cancelled.reason, 'recipient vanished');
      expect({for (final r in cancelled.releasedInputs) r.utxoKey: r.restoredStatus},
          {_input: UTXOStatus.available, _pendingInput: UTXOStatus.pending});
      expect(wallet.utxo(_input).status, UTXOStatus.available);
      expect(wallet.deferred(txid)['state'], 'cancelled');
      expect(wallet.replay().currentState.utxos[_input]!.status, UTXOStatus.available);

      expect(() => wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid)), throwsA(isA<StateError>()),
          reason: 'not outstanding any more');
    });

    test('refused when the network knows the transaction, or it is not a deferred payment', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      expect(
          () => wallet.handle(CancelDeferredSpendCommand(
              walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.mined)),
          throwsA(isA<StateError>()));
      expect(() => wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: 'ee' * 32)),
          throwsA(isA<StateError>()));
      expect(wallet.utxo(_input).status, UTXOStatus.reserved);
    });

    test('a cancelled payment the network reports later is seen, and its spend still applies', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid));

      await wallet.handle(SpendUTXOCommand(walletId: _w, utxoKey: _input, spendingTxId: txid, fee: BigInt.zero));

      expect(wallet.utxo(_input).status, UTXOStatus.spent);
      expect(wallet.deferred(txid)['state'], 'seen');
    });

    test('4r0: recorded again after cancellation: outstanding again, its inputs held, journaled', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input, _pendingInput]);
      await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid, reason: 'no answer'));

      final txid2 = await wallet.pay([_input, _pendingInput]);

      expect(txid2, txid);
      final hold = wallet.journal.whereType<TransactionSpendDeferredEvent>().last;
      expect(hold.reactivated, isTrue);
      expect(hold.heldUtxoKeys, [_input, _pendingInput]);
      expect(TransactionSpendDeferredEvent.fromMap(hold.toMap()).reactivated, isTrue);
      expect(wallet.journal.whereType<TransactionRecordedEvent>(), hasLength(1));
      expect(wallet.journal.whereType<DeferredTransactionCancelledEvent>(), hasLength(1));
      expect(wallet.deferred(txid)['state'], 'outstanding');
      expect(wallet.deferred(txid)['resolutionReason'], isNull);
      for (final key in [_input, _pendingInput]) {
        expect(wallet.utxo(key).reservedByTxId, txid);
        expect(wallet.utxo(key).reservationExpiresAt, isNull);
      }
      final replayed = wallet.replay();
      expect(replayed.currentState.utxos[_input]!.reservedByTxId, txid);

      final again = await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid));
      expect((again.single as DeferredTransactionCancelledEvent).releasedInputs.map((r) => r.restoredStatus),
          [UTXOStatus.available, UTXOStatus.pending]);
    });

    test('4r0: not re-activated when an input was spent or is held by another payment since', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input, _other]);
      await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid));
      await wallet.pay([_other], sats: 2000);

      await expectLater(wallet.pay([_input, _other]), throwsA(isA<StateError>()));
      expect(wallet.deferred(txid)['state'], 'cancelled');

      final spentWallet = _Wallet();
      final spentTxid = await spentWallet.pay([_input]);
      await spentWallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: spentTxid));
      await spentWallet.handle(
          SpendUTXOCommand(walletId: _w, utxoKey: _input, spendingTxId: 'ff' * 32, fee: BigInt.zero));
      await expectLater(spentWallet.handle(RecordOutgoingTransactionCommand(
        walletId: _w,
        txid: spentTxid,
        rawHex: _paymentHex([_input]),
        totalInputSats: 20000,
        totalOutputSats: 1000,
        fee: 100,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: [_input],
        recipientAddresses: const [],
        paymentAmount: BigInt.from(1000),
        deferSpend: true,
      )), throwsA(isA<StateError>()));
      expect(spentWallet.deferred(spentTxid)['state'], 'cancelled');
    });

    test('4r0: a failed payment recorded again is refused', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      await wallet.handle(RecordTransactionNetworkStatusCommand(
          walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.rejected, source: 'arc'));
      expect(wallet.deferred(txid)['state'], 'failed');

      await expectLater(wallet.pay([_input]), throwsA(isA<StateError>()));
      expect(wallet.utxo(_input).status, isNot(UTXOStatus.spent));
      expect(wallet.deferred(txid)['state'], 'failed');
    });
  });

  // hccp (libspiffy-hccp, from hg0/10r): a merkle proof that verifies
  // against the active header chain is authoritative. A payment ARC
  // reported REJECTED (stale, or a competing spend that lost) or that the
  // user cancelled was mined after all: its confirmation spends the inputs
  // the failure or cancellation released. Old code journaled only
  // TransactionConfirmedEvent and left them available to spend again.
  group('hccp: a confirmation of a failed or cancelled payment', () {
    for (final resolution in ['failed', 'cancelled']) {
      test('$resolution, then confirmed: the released inputs are spent by it, journaled, mined', () async {
        final wallet = _Wallet();
        final txid = await wallet.pay([_input, _pendingInput]);
        if (resolution == 'failed') {
          await wallet.handle(RecordTransactionNetworkStatusCommand(
              walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.rejected));
        } else {
          await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid));
        }
        expect(wallet.utxo(_input).status, UTXOStatus.available);
        expect(wallet.deferred(txid)['state'], resolution);

        final events = await wallet.handle(
            ConfirmTransactionCommand(walletId: _w, txid: txid, blockHeight: 10, blockHash: 'h', bumpHex: 'bump'));

        expect(
            [
              for (final e in events)
                switch (e) {
                  final UTXOSpentEvent s => 'spent ${s.txid}:${s.vout} in ${s.spentInTxId}',
                  final TransactionConfirmedEvent c => 'confirmed ${c.txid} h=${c.blockHeight} bump=${c.bumpHex}',
                  final other => other.runtimeType.toString(),
                },
            ],
            ['spent $_input in $txid', 'spent $_pendingInput in $txid', 'confirmed $txid h=10 bump=bump']);
        for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
          for (final key in [_input, _pendingInput]) {
            expect((state.utxos[key]!.status, state.utxos[key]!.spentInTxId), (UTXOStatus.spent, txid));
          }
          expect(state.metadata['deferredSpends'][txid]['state'], 'mined');
          expect(state.availableBalance, BigInt.from(7000), reason: 'only the untouched UTXO is spendable');
        }

        // Confirmed again (another proof report): nothing more to spend.
        final again = await wallet.handle(ConfirmTransactionCommand(walletId: _w, txid: txid, blockHeight: 10));
        expect(again.map((e) => e.runtimeType), [TransactionConfirmedEvent]);
      });
    }

    test('an input another transaction spent meanwhile is a double spend: logged severe, left as it is; '
        'an input another payment holds is spent by the mined one', () async {
      final wallet = _Wallet();
      final mined = await wallet.pay([_input, _other]);
      await wallet.handle(RecordTransactionNetworkStatusCommand(
          walletId: _w, txid: mined, networkStatus: DeferredNetworkStatus.rejected));
      // The released inputs were used again: _input by a payment the network
      // took, _other by a payment still outstanding.
      final spender = await wallet.pay([_input], sats: 2000);
      await wallet.handle(SpendUTXOCommand(walletId: _w, utxoKey: _input, spendingTxId: spender, fee: BigInt.zero));
      final holder = await wallet.pay([_other], sats: 3000);
      expect(wallet.utxo(_other).reservedByTxId, holder);

      final severe = <String>[];
      final sub = Logger.root.onRecord.where((r) => r.level >= Level.SEVERE).listen((r) => severe.add(r.message));
      final List<Event> events;
      try {
        events = await wallet.handle(ConfirmTransactionCommand(walletId: _w, txid: mined, blockHeight: 10));
      } finally {
        await sub.cancel();
      }

      expect([for (final e in events) e is UTXOSpentEvent ? 'spent ${e.txid}:${e.vout} in ${e.spentInTxId}' : '${e.runtimeType}'],
          ['spent $_other in $mined', 'TransactionConfirmedEvent']);
      for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
        expect((state.utxos[_input]!.status, state.utxos[_input]!.spentInTxId), (UTXOStatus.spent, spender),
            reason: 'the other spend is not rewritten');
        expect((state.utxos[_other]!.status, state.utxos[_other]!.spentInTxId), (UTXOStatus.spent, mined));
        expect(state.metadata['deferredSpends'][mined]['state'], 'mined');
        expect(state.metadata['deferredSpends'][spender]['state'], 'seen');
        expect(state.metadata['deferredSpends'][holder]['state'], 'outstanding',
            reason: 'it can no longer settle; its status comes from the network');
        expect((state.metadata['deferredHolds'] as Map).containsKey(_other), isFalse);
      }
      expect(severe, hasLength(2));
      expect(severe.firstWhere((m) => m.contains(_input)), allOf(contains(mined), contains(spender), contains('Double spend')));
      expect(severe.firstWhere((m) => m.contains(_other)), allOf(contains(mined), contains(holder)));
    });
  });

  // Bead libspiffy-87a: cancelling releases the inputs but leaves the signed
  // transaction the recipient holds spendable. A reclaim spends those inputs
  // back to the wallet, so that copy can no longer be mined.
  //
  // This is Bitcoin SV: first seen wins, so the self-spend pays the standard
  // policy fee and nothing more. Which of the two transactions is mined is
  // decided by which reached the network first.
  group('reclaim', () {
    /// The wallet's own self-spend of [inputs], paying [sats] back (the rest
    /// is the policy fee).
    (String, String) selfSpend(List<String> inputs, {required int sats}) {
      final rawHex = _paymentHex(inputs, sats: sats);
      return (dartsv.Transaction.fromHex(rawHex).id, rawHex);
    }

    Future<(String, String, String)> outstandingThenReclaim(_Wallet wallet, {String? reason}) async {
      final txid = await wallet.pay([_input]);
      final (reclaimTxid, rawHex) = selfSpend([_input], sats: 19900);
      await wallet.handle(ReclaimDeferredSpendCommand(
          walletId: _w, txid: txid, reclaimTxid: reclaimTxid, rawHex: rawHex,
          recipientAddresses: const ['mrootaddress0000000000000000000000'], reason: reason));
      return (txid, reclaimTxid, rawHex);
    }

    test('the self-spend is recorded and takes over the hold; the payment stays outstanding until the '
        'network has it', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      final (reclaimTxid, rawHex) = selfSpend([_input], sats: 19900);

      final events = await wallet.handle(ReclaimDeferredSpendCommand(
          walletId: _w, txid: txid, reclaimTxid: reclaimTxid, rawHex: rawHex,
          recipientAddresses: const ['mrootaddress0000000000000000000000'], reason: 'recipient vanished'));

      final recorded = events.whereType<TransactionRecordedEvent>().single;
      expect(recorded.txid, reclaimTxid);
      expect(recorded.spentUtxoKeys, [_input]);
      expect(recorded.fee, 100, reason: '20000 in, 19900 out: the policy fee, derived from the transaction');
      final hold = events.whereType<TransactionSpendDeferredEvent>().single;
      expect((hold.txid, hold.supersedes), (reclaimTxid, txid));
      expect(hold.heldUtxoKeys, [_input]);
      expect(hold.purpose, 'reclaim:$txid');
      final reclaimed = events.whereType<DeferredSpendReclaimedEvent>().single;
      expect((reclaimed.txid, reclaimed.reclaimTxid, reclaimed.reason), (txid, reclaimTxid, 'recipient vanished'));
      expect(reclaimed.reclaimedUtxoKeys, [_input]);
      expect(events.whereType<UTXOSpentEvent>(), isEmpty, reason: 'nothing is spent before the network has it');

      expect(wallet.utxo(_input).status, UTXOStatus.reserved);
      expect(wallet.utxo(_input).reservedByTxId, reclaimTxid, reason: 'the hold moved to the self-spend');
      expect(wallet.utxo(_input).reservationExpiresAt, isNull);
      expect(wallet.deferred(txid)['state'], 'outstanding', reason: 'not resolved at broadcast time');
      expect(wallet.deferred(txid)['reclaimTxid'], reclaimTxid);
      expect(wallet.deferred(reclaimTxid)['reclaimOf'], txid);
      expect((wallet.aggregate.currentState.metadata['deferredHolds'] as Map)[_input], reclaimTxid);
    });

    test('the payment is reclaimed once the network has the self-spend; the original payment is kept', () async {
      final wallet = _Wallet();
      final (txid, reclaimTxid, rawHex) = await outstandingThenReclaim(wallet, reason: 'recipient vanished');

      // ARC reports the self-spend, and ARCActor spends its inputs.
      await wallet.handle(
          SpendUTXOCommand(walletId: _w, utxoKey: _input, spendingTxId: reclaimTxid, fee: BigInt.zero));

      for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
        expect((state.utxos[_input]!.status, state.utxos[_input]!.spentInTxId), (UTXOStatus.spent, reclaimTxid));
        expect(state.metadata['deferredSpends'][txid]['state'], 'reclaimed');
        expect(state.metadata['deferredSpends'][txid]['resolutionReason'], contains(reclaimTxid));
        expect(state.metadata['deferredSpends'][reclaimTxid]['state'], 'seen');
        // Retention: the reclaimed payment keeps its record and its link.
        expect(state.metadata['deferredSpends'][txid]['txid'], txid);
        expect(state.metadata['deferredSpends'][txid]['reclaimTxid'], reclaimTxid);
      }
      expect(rawHex, isNotEmpty);
    });

    test('a status report of the self-spend reclaims the payment too', () async {
      final wallet = _Wallet();
      final (txid, reclaimTxid, _) = await outstandingThenReclaim(wallet);

      await wallet.handle(RecordTransactionNetworkStatusCommand(
          walletId: _w, txid: reclaimTxid, networkStatus: DeferredNetworkStatus.seenOnNetwork));

      expect(wallet.deferred(reclaimTxid)['state'], 'seen');
      expect(wallet.deferred(txid)['state'], 'reclaimed');
    });

    test('a self-spend that never reaches the network leaves the payment outstanding, its inputs held by '
        'the self-spend', () async {
      final wallet = _Wallet();
      final (txid, reclaimTxid, _) = await outstandingThenReclaim(wallet);

      expect(wallet.deferred(txid)['state'], 'outstanding');
      expect(wallet.utxo(_input).status, UTXOStatus.reserved);
      expect(wallet.utxo(_input).reservedByTxId, reclaimTxid);
      // No other payment can take the input while the reclaim is in flight:
      // only the two UTXOs the payment never touched are spendable.
      expect(wallet.aggregate.currentState.availableBalance, BigInt.from(7000));
    });

    test('cancelling a payment being reclaimed is refused', () async {
      final wallet = _Wallet();
      final (txid, reclaimTxid, _) = await outstandingThenReclaim(wallet);

      expect(() => wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid)),
          throwsA(isA<StateError>()));
      // And the reclaim itself cannot be cancelled: it is irreversible, and
      // releasing its inputs would strand the payment it reclaims.
      expect(() => wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: reclaimTxid)),
          throwsA(isA<StateError>()));
      expect(wallet.deferred(txid)['reclaimTxid'], reclaimTxid);
      expect(wallet.utxo(_input).status, UTXOStatus.reserved);
      expect(wallet.utxo(_input).reservedByTxId, reclaimTxid);
    });

    test('refused: an unknown payment, one not outstanding, one already being reclaimed', () async {
      final wallet = _Wallet();
      final (unknownTxid, unknownHex) = selfSpend([_input], sats: 19000);
      expect(
          () => wallet.handle(ReclaimDeferredSpendCommand(
              walletId: _w, txid: 'ee' * 32, reclaimTxid: unknownTxid, rawHex: unknownHex)),
          throwsA(isA<StateError>()));

      final wallet2 = _Wallet();
      final (txid, reclaimTxid, _) = await outstandingThenReclaim(wallet2);
      final (secondTxid, secondHex) = selfSpend([_input], sats: 19800);
      expect(
          () => wallet2.handle(ReclaimDeferredSpendCommand(
              walletId: _w, txid: txid, reclaimTxid: secondTxid, rawHex: secondHex)),
          throwsA(isA<StateError>()),
          reason: 'already being reclaimed by $reclaimTxid');

      final wallet3 = _Wallet();
      final cancelled = await wallet3.pay([_other], sats: 3000);
      await wallet3.handle(CancelDeferredSpendCommand(walletId: _w, txid: cancelled));
      final (afterCancel, afterCancelHex) = selfSpend([_other], sats: 6900);
      expect(
          () => wallet3.handle(ReclaimDeferredSpendCommand(
              walletId: _w, txid: cancelled, reclaimTxid: afterCancel, rawHex: afterCancelHex)),
          throwsA(isA<StateError>()),
          reason: 'cancelled, not outstanding');
    });

    test('refused: a transaction that does not spend exactly the held inputs, or pays no fee', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);

      final (wrongInputs, wrongInputsHex) = selfSpend([_input, _other], sats: 19900);
      expect(
          () => wallet.handle(ReclaimDeferredSpendCommand(
              walletId: _w, txid: txid, reclaimTxid: wrongInputs, rawHex: wrongInputsHex)),
          throwsA(isA<StateError>()),
          reason: 'it spends an input the payment does not hold');

      final (noFee, noFeeHex) = selfSpend([_input], sats: 20000);
      expect(
          () => wallet.handle(ReclaimDeferredSpendCommand(
              walletId: _w, txid: txid, reclaimTxid: noFee, rawHex: noFeeHex)),
          throwsA(isA<StateError>()),
          reason: 'it pays out everything and leaves no fee');

      final (real, realHex) = selfSpend([_input], sats: 19900);
      expect(
          () => wallet.handle(ReclaimDeferredSpendCommand(
              walletId: _w, txid: txid, reclaimTxid: 'ff' * 32, rawHex: realHex)),
          throwsA(isA<ArgumentError>()),
          reason: 'the named txid is not the transaction\'s own id');
      expect(real, isNotEmpty);
      expect(wallet.utxo(_input).reservedByTxId, txid, reason: 'nothing was journaled');
    });

    test('journals written before reclaims replay unchanged', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input, _pendingInput]);
      await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid));

      // Every hold in such a journal reads back with no superseded payment.
      for (final hold in wallet.journal.whereType<TransactionSpendDeferredEvent>()) {
        expect(hold.supersedes, isNull);
        final beforeReclaims = Map<String, dynamic>.from(hold.toMap())..remove('supersedes');
        expect(TransactionSpendDeferredEvent.fromMap(beforeReclaims).supersedes, isNull);
      }
      final replayed = wallet.replay().currentState;
      expect(replayed.metadata['deferredSpends'][txid]['state'], 'cancelled');
      expect(replayed.metadata['deferredSpends'][txid].containsKey('reclaimTxid'), isFalse);
      expect(replayed.utxos[_input]!.status, UTXOStatus.available);
      expect(replayed.utxos[_pendingInput]!.status, UTXOStatus.pending);
      expect(DeferredPayment.stateFromName('cancelled'), DeferredPaymentState.cancelled);
      expect(DeferredPayment.stateFromName(null), DeferredPaymentState.outstanding);
    });
  });

  group('journals written before holds', () {
    /// The old payment flow: 2-minute reservation (long expired), recording
    /// without a hold, and optionally the old cleanup's release.
    _Wallet legacyWallet({required bool released}) {
      final wallet = _Wallet();
      final rawHex = _paymentHex([_input]);
      final txid = dartsv.Transaction.fromHex(rawHex).id;
      final at = DateTime.utc(2026, 1, 2);
      final parts = _input.split(':');
      var v = wallet.aggregate.currentState.version;
      wallet.apply([
        UTXOReservedEvent(
            walletId: _w, txid: parts[0], vout: 0, reservedByTxId: 'payment-old',
            expiresAt: at.add(const Duration(minutes: 2)), version: ++v, timestamp: at),
        TransactionRecordedEvent(
            walletId: _w, txid: txid, rawHex: rawHex, totalInputSats: 20000, totalOutputSats: 1000, fee: 100,
            numInputs: 1, numOutputs: 1, txVersion: 1, txLockTime: 0, spentUtxoKeys: [_input],
            recipientAddresses: const ['muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg'], paymentAmount: '1000',
            version: ++v, timestamp: at),
        if (released)
          UTXOReleasedEvent(
              walletId: _w, txid: parts[0], vout: 0, releaseReason: 'Expired reservation cleanup',
              wasExpired: true, restoredStatus: UTXOStatus.available, version: ++v, timestamp: at),
      ]);
      return wallet;
    }

    for (final released in [false, true]) {
      final how = released ? 'already released' : 'expired';
      test('reconcile journals an inferred hold (reservation $how)', () async {
        final wallet = legacyWallet(released: released);
        final txid = wallet.journal.whereType<TransactionRecordedEvent>().single.txid;

        final events = await wallet.handle(ReconcileDeferredSpendsCommand(walletId: _w));

        final hold = events.single as TransactionSpendDeferredEvent;
        expect(hold.txid, txid);
        expect(hold.inferred, isTrue);
        expect(hold.heldUtxoKeys, [_input]);
        expect(hold.recordedAt, DateTime.utc(2026, 1, 2));
        expect(wallet.utxo(_input).reservedByTxId, txid);
        expect(wallet.utxo(_input).reservationExpiresAt, isNull);
        expect(await wallet.handle(ReconcileDeferredSpendsCommand(walletId: _w)), isEmpty, reason: 'once');
      });

      test('before any reconcile, cleanup and reservations already respect the hold (reservation $how)', () async {
        final wallet = legacyWallet(released: released);
        expect(
            () => wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: _input, reservedByTxId: 'thief')),
            throwsA(isA<StateError>()));
        final events = await wallet.handle(CleanupExpiredReservationsCommand(
            walletId: _w, cutoffTime: DateTime.now().add(const Duration(days: 1))));
        expect(events.whereType<UTXOReleasedEvent>(), isEmpty);
        expect(events.whereType<TransactionSpendDeferredEvent>().single.inferred, isTrue);
        expect(wallet.utxo(_input).status, UTXOStatus.reserved);
      });
    }

    for (final released in [false, true]) {
      final how = released ? 'already released' : 'expired';
      test('8j9w: before any reconcile, availableBalance and coin selection leave the held input out '
          '(reservation $how)', () async {
        final wallet = legacyWallet(released: released);
        final agg = wallet.aggregate;
        final state = agg.currentState;
        expect(wallet.journal.whereType<TransactionSpendDeferredEvent>(), isEmpty, reason: 'no hold journaled');

        // _input (20000) is held by the legacy payment, _pendingInput is
        // pending: only _other (7000) is spendable.
        expect(state.availableBalance, BigInt.from(7000));
        expect(agg.getAvailableUTXOs(state).map((u) => u.key), [_other]);
        expect(agg.hasSufficientBalance(state, BigInt.from(7001)), isFalse);
        expect(() => agg.selectUTXOsForAmount(state, BigInt.from(7001)), throwsA(isA<StateError>()));
        expect(state.availableUtxos.map((u) => u.key), [_other]);

        // The reconcile journals the hold; the spendable amount stays.
        await wallet.handle(ReconcileDeferredSpendsCommand(walletId: _w));
        expect(agg.currentState.availableBalance, BigInt.from(7000));
        expect(agg.getAvailableUTXOs(agg.currentState).map((u) => u.key), [_other]);
      });
    }

    test('8j9w: cancelling a legacy payment makes its input spendable again', () async {
      final wallet = legacyWallet(released: true);
      final txid = wallet.journal.whereType<TransactionRecordedEvent>().single.txid;
      expect(wallet.aggregate.currentState.availableBalance, BigInt.from(7000));
      await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid));
      expect(wallet.aggregate.currentState.availableBalance, BigInt.from(27000));
    });

    test('a recording that spent its inputs (no deferred spend) is not inferred', () async {
      final wallet = _Wallet();
      final rawHex = _paymentHex([_input]);
      await wallet.handle(RecordOutgoingTransactionCommand(
        walletId: _w,
        txid: dartsv.Transaction.fromHex(rawHex).id,
        rawHex: rawHex,
        totalInputSats: 20000,
        totalOutputSats: 1000,
        fee: 100,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: [_input],
        recipientAddresses: const ['x'],
        paymentAmount: BigInt.from(1000),
      ));
      expect(wallet.journal.whereType<TransactionSpendDeferredEvent>(), isEmpty);
      expect(await wallet.handle(ReconcileDeferredSpendsCommand(walletId: _w)), isEmpty);
    });
  });
}
