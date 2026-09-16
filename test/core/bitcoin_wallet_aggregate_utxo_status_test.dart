/// UTXO status and reservation rules in [BitcoinWalletAggregate].
///
/// Covers audit findings (doc/audit-2026-09-14.md, section 7):
/// - M3 (libspiffy-qi5): `ReserveUTXOsCommand` / `ReleaseUTXOsCommand` were
///   no-ops, yet the payment and Benford coordinators release abandoned
///   reservations with `ReleaseUTXOsCommand`; those UTXOs stayed reserved
///   until the reservation expired.
/// - M4 (libspiffy-54o): reserving then releasing a pending UTXO promoted it
///   to available.
/// - M9 (libspiffy-0qf): recording the same outgoing transaction twice
///   re-emitted `UTXOReceivedEvent` for outputs the wallet already held, and
///   applying that event overwrote the existing UTXO (status and reservation
///   lost).
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _externalAddress = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF'; // testnet
const _walletId = 'wallet-utxo-status';

String _txid(String c) => List.filled(64, c).join();

void main() {
  late InMemoryEventStore store;
  late InMemorySecureStorage secureStorage;
  late DartSVCryptoService cryptoService;
  late BitcoinWalletAggregate wallet;
  late String address;
  late String scriptHex;

  BitcoinWalletAggregate newAggregate() => BitcoinWalletAggregate(
        aggregateId: _walletId,
        aggregateType: 'Wallet',
        eventStore: store,
        cryptoService: cryptoService,
        secureStorage: secureStorage,
      );

  setUp(() async {
    store = InMemoryEventStore();
    secureStorage = InMemorySecureStorage();
    cryptoService = DartSVCryptoService();
    wallet = newAggregate();
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(
      walletId: _walletId,
      walletName: 'UTXO status wallet',
      mnemonic: _mnemonic,
    ));
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId, label: 'a'));
    address = wallet.currentState.addresses.keys.last;
    scriptHex = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address))
        .getScriptPubkey()
        .toHex();
  });

  /// Receives a UTXO with [status] and returns its key.
  Future<String> receive(String txid, int vout,
      {UTXOStatus status = UTXOStatus.available, int sats = 10000}) async {
    await wallet.commandHandler(ReceiveUTXOCommand(
      walletId: _walletId,
      txid: txid,
      vout: vout,
      satoshis: BigInt.from(sats),
      scriptPubKey: scriptHex,
      address: address,
      initialStatus: status,
    ));
    return '$txid:$vout';
  }

  UTXOStatus statusOf(String key) => wallet.currentState.utxos[key]!.status;

  group('M3: ReserveUTXOsCommand / ReleaseUTXOsCommand', () {
    test('reserving two UTXOs reserves both; releasing the reservation makes both available',
        () async {
      final k1 = await receive(_txid('1'), 0);
      final k2 = await receive(_txid('2'), 1);

      await wallet.commandHandler(ReserveUTXOsCommand(
        walletId: _walletId,
        utxoKeys: [k1, k2],
        reservationId: 'payment-1',
      ));
      expect(statusOf(k1), UTXOStatus.reserved);
      expect(statusOf(k2), UTXOStatus.reserved);
      expect(wallet.currentState.utxos[k1]!.reservedByTxId, 'payment-1');
      expect(wallet.currentState.utxos[k2]!.reservedByTxId, 'payment-1');
      expect(store.allEvents.whereType<UTXOReservedEvent>().length, 2,
          reason: 'one UTXOReservedEvent per UTXO, so the read model is updated too');

      await wallet.commandHandler(ReleaseUTXOsCommand(
        walletId: _walletId,
        reservationId: 'payment-1',
      ));
      expect(statusOf(k1), UTXOStatus.available);
      expect(statusOf(k2), UTXOStatus.available);
      expect(wallet.currentState.utxos[k1]!.reservedByTxId, isNull);
      expect(store.allEvents.whereType<UTXOReleasedEvent>().length, 2);
    });

    test('ReleaseUTXOsCommand releases reservations placed one UTXO at a time (coordinator flow)',
        () async {
      final k1 = await receive(_txid('1'), 0);
      final k2 = await receive(_txid('2'), 0);
      final other = await receive(_txid('3'), 0);
      for (final k in [k1, k2]) {
        await wallet.commandHandler(ReserveUTXOCommand(
          walletId: _walletId,
          utxoKey: k,
          reservedByTxId: 'payment-2',
          reservationDuration: const Duration(minutes: 2),
        ));
      }
      await wallet.commandHandler(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: other,
        reservedByTxId: 'someone-else',
      ));

      await wallet.commandHandler(ReleaseUTXOsCommand(
        walletId: _walletId,
        reservationId: 'payment-2',
      ));
      expect(statusOf(k1), UTXOStatus.available);
      expect(statusOf(k2), UTXOStatus.available);
      expect(statusOf(other), UTXOStatus.reserved,
          reason: 'a reservation held by a different id must not be released');
    });

    test('ReserveUTXOsCommand is all-or-nothing: a spent key rejects the command', () async {
      final k1 = await receive(_txid('1'), 0);
      final k2 = await receive(_txid('2'), 0);
      await wallet.commandHandler(SpendUTXOCommand(
        walletId: _walletId,
        utxoKey: k2,
        spendingTxId: _txid('f'),
        fee: BigInt.zero,
      ));

      await expectLater(
        wallet.commandHandler(ReserveUTXOsCommand(
          walletId: _walletId,
          utxoKeys: [k1, k2],
          reservationId: 'payment-3',
        )),
        throwsA(isA<StateError>()),
      );
      expect(statusOf(k1), UTXOStatus.available);
      expect(store.allEvents.whereType<UTXOReservedEvent>(), isEmpty);
    });

    test('ReserveUTXOsCommand applies the priority rule to a live reservation', () async {
      final k1 = await receive(_txid('1'), 0);
      await wallet.commandHandler(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: k1,
        reservedByTxId: 'first',
      ));
      await expectLater(
        wallet.commandHandler(ReserveUTXOsCommand(
          walletId: _walletId,
          utxoKeys: [k1],
          reservationId: 'second',
        )),
        throwsA(isA<StateError>()),
      );
      expect(wallet.currentState.utxos[k1]!.reservedByTxId, 'first');
    });

    test('ReleaseUTXOsCommand for an unknown reservation is a no-op', () async {
      final k1 = await receive(_txid('1'), 0);
      final versionBefore = wallet.currentState.version;
      await wallet.commandHandler(ReleaseUTXOsCommand(
        walletId: _walletId,
        reservationId: 'nothing-reserved',
      ));
      expect(statusOf(k1), UTXOStatus.available);
      expect(wallet.currentState.version, versionBefore);
    });
  });

  group('M4: releasing a reservation restores the previous status', () {
    test('pending UTXO -> reserve -> release stays pending', () async {
      final k = await receive(_txid('1'), 0, status: UTXOStatus.pending);
      await wallet.commandHandler(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: k,
        reservedByTxId: 'payment',
      ));
      expect(statusOf(k), UTXOStatus.reserved);

      await wallet.commandHandler(ReleaseUTXOCommand(walletId: _walletId, utxoKey: k));
      expect(statusOf(k), UTXOStatus.pending);

      // The journal replays to the same state.
      final recovered = newAggregate();
      await recovered.preStart();
      expect(recovered.currentState.utxos[k]!.status, UTXOStatus.pending);
    });

    test('pending UTXO released by ReleaseUTXOsCommand stays pending', () async {
      final k = await receive(_txid('1'), 0, status: UTXOStatus.pending);
      await wallet.commandHandler(ReserveUTXOsCommand(
        walletId: _walletId,
        utxoKeys: [k],
        reservationId: 'payment',
      ));
      expect(statusOf(k), UTXOStatus.reserved);
      await wallet.commandHandler(ReleaseUTXOsCommand(walletId: _walletId, reservationId: 'payment'));
      expect(statusOf(k), UTXOStatus.pending);
    });

    test('pending UTXO whose reservation expires stays pending', () async {
      final k = await receive(_txid('1'), 0, status: UTXOStatus.pending);
      await wallet.commandHandler(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: k,
        reservedByTxId: 'payment',
        reservationDuration: const Duration(minutes: 2),
      ));
      await wallet.commandHandler(CleanupExpiredReservationsCommand(
        walletId: _walletId,
        cutoffTime: DateTime.now().add(const Duration(hours: 1)),
      ));
      expect(statusOf(k), UTXOStatus.pending);
    });

    test('available UTXO -> reserve -> release is available', () async {
      final k = await receive(_txid('1'), 0);
      await wallet.commandHandler(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: k,
        reservedByTxId: 'payment',
      ));
      await wallet.commandHandler(ReleaseUTXOCommand(walletId: _walletId, utxoKey: k));
      expect(statusOf(k), UTXOStatus.available);
    });

    test('a pending UTXO confirmed while reserved is available after release', () async {
      final k = await receive(_txid('1'), 0, status: UTXOStatus.pending);
      await wallet.commandHandler(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: k,
        reservedByTxId: 'payment',
      ));
      await wallet.commandHandler(UpdateUTXOConfirmationsCommand(
        walletId: _walletId,
        utxoKey: k,
        confirmations: 1,
        blockHeight: 800000,
      ));
      expect(statusOf(k), UTXOStatus.reserved, reason: 'confirmation must not drop the reservation');

      await wallet.commandHandler(ReleaseUTXOCommand(walletId: _walletId, utxoKey: k));
      expect(statusOf(k), UTXOStatus.available);
    });

    test('a pending UTXO marked available while reserved is available after release', () async {
      final k = await receive(_txid('1'), 0, status: UTXOStatus.pending);
      await wallet.commandHandler(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: k,
        reservedByTxId: 'payment',
      ));
      await wallet.commandHandler(MarkUTXOAvailableCommand(
        walletId: _walletId,
        txid: _txid('1'),
        vout: 0,
      ));
      expect(statusOf(k), UTXOStatus.reserved);

      await wallet.commandHandler(ReleaseUTXOCommand(walletId: _walletId, utxoKey: k));
      expect(statusOf(k), UTXOStatus.available);
    });

    test('a release event journaled before the fix still replays to available', () async {
      final k = await receive(_txid('1'), 0, status: UTXOStatus.pending);
      await wallet.commandHandler(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: k,
        reservedByTxId: 'payment',
      ));
      // Legacy UTXOReleasedEvent: no restoredStatus in its data.
      final legacy = UTXOReleasedEvent.fromMap({
        'walletId': _walletId,
        'txid': _txid('1'),
        'vout': 0,
        'releaseReason': 'legacy',
        'wasExpired': false,
        'version': wallet.currentState.version + 1,
      });
      expect(legacy.restoredStatus, isNull);
      wallet.eventHandler(legacy);
      expect(statusOf(k), UTXOStatus.available);
    });
  });

  group('M9: an already-known outpoint is never overwritten', () {
    /// Outgoing transaction paying [_externalAddress] with change back to
    /// the wallet at output 1.
    dartsv.Transaction outgoingTx() {
      final tx = dartsv.Transaction()
        ..version = 1
        ..nLockTime = 0;
      tx.inputs.add(dartsv.TransactionInput(_txid('a'), 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
      tx.outputs.add(dartsv.TransactionOutput(
          BigInt.from(5000),
          dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(_externalAddress))
              .getScriptPubkey()));
      tx.outputs.add(dartsv.TransactionOutput(BigInt.from(4000), dartsv.SVScript.fromHex(scriptHex)));
      return tx;
    }

    RecordOutgoingTransactionCommand record(dartsv.Transaction tx) => RecordOutgoingTransactionCommand(
          walletId: _walletId,
          txid: tx.id,
          rawHex: tx.serialize(),
          totalInputSats: 10000,
          totalOutputSats: 9000,
          fee: 1000,
          numInputs: 1,
          numOutputs: 2,
          txVersion: 1,
          txLockTime: 0,
          spentUtxoKeys: const [],
          recipientAddresses: const [_externalAddress],
          paymentAmount: BigInt.from(5000),
          deferSpend: true,
        );

    test('recording the same transaction twice creates no duplicate UTXO and keeps its status',
        () async {
      final tx = outgoingTx();
      final changeKey = '${tx.id}:1';

      await wallet.commandHandler(record(tx));
      expect(statusOf(changeKey), UTXOStatus.pending);

      // The change output is spent into a new payment: reserve it.
      await wallet.commandHandler(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: changeKey,
        reservedByTxId: 'next-payment',
      ));
      expect(statusOf(changeKey), UTXOStatus.reserved);

      // The same transaction is recorded again (retry, re-sync).
      await wallet.commandHandler(record(tx));

      expect(statusOf(changeKey), UTXOStatus.reserved,
          reason: 'a re-scan must not reset the UTXO to pending');
      expect(wallet.currentState.utxos[changeKey]!.reservedByTxId, 'next-payment');
      final received = store.allEvents
          .whereType<UTXOReceivedEvent>()
          .where((e) => e.txid == tx.id && e.vout == 1);
      expect(received.length, 1, reason: 'the journal must not hold a duplicate UTXOReceivedEvent');
    });

    test('applying a duplicate UTXOReceivedEvent (journaled by older code) keeps the existing UTXO',
        () async {
      final k = await receive(_txid('1'), 0, status: UTXOStatus.pending);
      await wallet.commandHandler(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: k,
        reservedByTxId: 'payment',
      ));

      wallet.eventHandler(UTXOReceivedEvent(
        walletId: _walletId,
        txid: _txid('1'),
        vout: 0,
        satoshis: 10000,
        scriptPubKey: scriptHex,
        address: address,
        initialStatus: UTXOStatus.pending,
        version: wallet.currentState.version + 1,
      ));

      expect(statusOf(k), UTXOStatus.reserved);
      expect(wallet.currentState.utxos[k]!.reservedByTxId, 'payment');
      expect(wallet.currentState.utxos.length, 1);
    });

    // Bead libspiffy-fggl: the second receipt used to throw. The senders of
    // the command tell() it with no sender to reply to, so the error was
    // dropped and only the sibling commands of the same receive ran; and a
    // counterparty handing back a BEEF with a transaction of ours in it
    // re-receives our own change output on the normal path. It is a no-op
    // now: the row is still never overwritten, and nothing is journaled.
    test('ReceiveUTXOCommand for a known outpoint journals nothing and keeps the row', () async {
      final k = await receive(_txid('1'), 0);
      final eventsBefore = store.allEvents.length;
      await receive(_txid('1'), 0, status: UTXOStatus.pending);
      expect(store.allEvents.length, eventsBefore);
      expect(statusOf(k), UTXOStatus.available);
    });
  });
}
