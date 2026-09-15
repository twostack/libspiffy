/// Bead libspiffy-7p2: the wallet aggregate holds a deferred payment's inputs
/// until the network settles it, ARC reports it definitively failed, or it is
/// cancelled; nothing else (reservation expiry, cleanup, other reservations)
/// releases or takes them. Holds, failures and cancellations are journaled
/// and survive a replay and a snapshot; journals written before holds are
/// reconciled.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
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

    for (final status in [DeferredNetworkStatus.rejected, DeferredNetworkStatus.doubleSpendAttempted]) {
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
