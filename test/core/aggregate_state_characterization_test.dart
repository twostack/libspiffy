/// libspiffy-mmb characterization: the behaviour of the wallet, invoice and
/// payment channel aggregates that making their state objects immutable
/// (copy-on-write) must not change. Written against the in-place mutating
/// aggregates and kept passing after the conversion.
///
/// * Replay determinism: the journal a live aggregate wrote, replayed into a
///   fresh aggregate (and recovered from the event store), gives the state
///   the live aggregate holds, field for field.
/// * Snapshot round trip: the snapshot map, through eventador's CBOR
///   serializer and back through `restoreStateFromMap`, gives the same state.
/// * Rejected commands: a command the aggregate refuses leaves its state (and
///   its journal) exactly as it was.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_messages.dart' show InvoiceStatus;
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/channel_commands.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/channel_state.dart';
import 'package:libspiffy/src/core/invoice_aggregate.dart';
import 'package:libspiffy/src/core/invoice_commands.dart';
import 'package:libspiffy/src/core/payment_channel_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart' show UTXOSplitInitiatedEvent;
import 'package:libspiffy/src/models/bitcoin_transaction.dart' show TransactionStatus;
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/deferred_payment.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/models/invoice_state.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';
import 'package:libspiffy/src/models/fee_rate.dart';
import '../mocks/test_channel_timing.dart';

const _walletId = 'mmb-wallet';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _foreignAddress = 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg';

/// A wallet aggregate whose protected snapshot hooks the tests can reach.
class _Wallet extends BitcoinWalletAggregate {
  _Wallet(EventStore store, InMemorySecureStorage secureStorage)
      : super(
          aggregateId: _walletId,
          aggregateType: 'BitcoinWallet',
          eventStore: store,
          cryptoService: DartSVCryptoService(),
          secureStorage: secureStorage,
        );

  Future<dynamic> snapshotMap() => getSnapshotState();

  Future<WalletState> restore(Map<String, dynamic> map) => restoreStateFromMap(map, sequenceNumber);
}

class _Invoice extends InvoiceAggregate {
  _Invoice(EventStore store, String id) : super(aggregateId: id, aggregateType: 'Invoice', eventStore: store);

  Future<dynamic> snapshotMap() => getSnapshotState();

  Future<InvoiceState> restore(Map<String, dynamic> map) => restoreStateFromMap(map, sequenceNumber);
}

class _Channel extends PaymentChannelAggregate {
  _Channel(EventStore store, String id)
      : super(aggregateId: id, eventStore: store, cryptoService: DartSVCryptoService());

  Future<dynamic> snapshotMap() => getSnapshotState();

  Future<ChannelState> restore(Map<String, dynamic> map) => restoreStateFromMap(map, sequenceNumber);
}

/// [map] after eventador's CBOR snapshot round trip.
Map<String, dynamic> _cborRoundTrip(Object? map) =>
    Map<String, dynamic>.from(CborSerializer.deserializeState(CborSerializer.serializeState(map), 'state') as Map);

String _p2pkhScript(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

/// A transaction spending [inputs] to a foreign address.
String _paymentHex(List<String> inputs, {int sats = 1000}) {
  final tx = dartsv.Transaction();
  for (final key in inputs) {
    final parts = key.split(':');
    tx.addInput(dartsv.TransactionInput(parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
  }
  tx.addOutput(dartsv.TransactionOutput(BigInt.from(sats), dartsv.SVScript.fromHex(_p2pkhScript(_foreignAddress))));
  return tx.serialize();
}

RecordOutgoingTransactionCommand _outgoing(List<String> inputs, {required int sats, bool deferSpend = false}) {
  final rawHex = _paymentHex(inputs, sats: sats);
  return RecordOutgoingTransactionCommand(
    walletId: _walletId,
    txid: dartsv.Transaction.fromHex(rawHex).id,
    rawHex: rawHex,
    totalInputSats: sats + 100,
    totalOutputSats: sats,
    fee: 100,
    numInputs: inputs.length,
    numOutputs: 1,
    txVersion: 1,
    txLockTime: 0,
    spentUtxoKeys: inputs,
    recipientAddresses: const [_foreignAddress],
    paymentAmount: BigInt.from(sats),
    deferSpend: deferSpend,
    invoiceId: 'inv-$sats',
    purpose: 'invoice-payment',
  );
}

String _key(int n, int vout) => '${n.toRadixString(16).padLeft(64, '0')}:$vout';

/// A live wallet whose journal exercises every state collection: addresses
/// on both chains, a discovered and a watch address, configuration metadata,
/// UTXOs through every status, reservations, imported and outgoing
/// transactions, deferred payments (held, cancelled, failed, seen), a
/// confirmation and its reversal, and a split.
Future<(_Wallet, InMemoryEventStore, InMemorySecureStorage)> _liveWallet() async {
  final store = InMemoryEventStore();
  final secureStorage = InMemorySecureStorage();
  final wallet = _Wallet(store, secureStorage);
  await wallet.preStart();
  Future<void> run(WalletCommand command) => wallet.commandHandler(command);

  await run(CreateWalletCommand(
    walletId: _walletId,
    walletName: 'Characterized',
    mnemonic: _mnemonic,
    walletMetadata: {
      'network': 'testnet',
      'profile': {'owner': 'mmb', 'tags': ['a', 'b']},
    },
  ));
  final root = wallet.currentState.rootAddress!;
  await run(GenerateAddressCommand(walletId: _walletId, label: 'receive'));
  await run(GenerateAddressCommand(walletId: _walletId, purpose: BitcoinWalletAggregate.changePurpose));
  await run(UpdateAddressLabelCommand(walletId: _walletId, address: root, newLabel: 'root'));
  await run(RegisterDiscoveredAddressCommand(
      walletId: _walletId, address: 'mdiscovered7', derivationIndex: 7, isChange: true, transactionCount: 2));
  await run(AddWatchAddressCommand(walletId: _walletId, address: 'mwatched1', scriptType: 'p2pkh', label: 'cold'));
  await run(UpdateWalletConfigurationCommand(
      walletId: _walletId, newName: 'Renamed', newMetadata: {'theme': 'dark', 'limits': {'daily': 5}}));

  final script = _p2pkhScript(root);
  for (var i = 1; i <= 8; i++) {
    await run(ReceiveUTXOCommand(
      walletId: _walletId,
      txid: _key(i, 0).split(':').first,
      vout: 0,
      satoshis: BigInt.from(10000 * i),
      scriptPubKey: script,
      address: root,
      initialStatus: i.isEven ? UTXOStatus.available : UTXOStatus.pending,
      confirmations: i.isEven ? 7 : 0,
      pluginMetadata: i == 8 ? {'pluginId': 'tok', 'nested': {'ids': [1, 2]}} : null,
    ));
  }
  await run(MarkUTXOAvailableCommand(walletId: _walletId, txid: _key(1, 0).split(':').first, vout: 0));
  // Kept in the scenario for its event and apply path, and now pinned to the
  // rule it obeys since bead libspiffy-8oaq: a confirmation count and a height
  // a caller reports are recorded and change no status. This UTXO was received
  // pending and stays pending — it was promoted to available when this
  // scenario was first written, and that is the behaviour being reversed.
  await run(UpdateUTXOConfirmationsCommand(walletId: _walletId, utxoKey: _key(3, 0), confirmations: 2, blockHeight: 90));
  expect(wallet.currentState.utxos[_key(3, 0)]!.status, UTXOStatus.pending,
      reason: 'a reported count conjures no spendable funds');
  expect(wallet.currentState.utxos[_key(3, 0)]!.confirmations, 2, reason: 'the claim is still recorded');
  // Bead libspiffy-pq8p: the height the caller reported reaches no row.
  // `blockHeight != null` is what "confirmed" means (libspiffy-jc3h) and
  // this command holds no proof, so recording its height let an unproven
  // claim report as confirmed. The count above is still kept.
  expect(wallet.currentState.utxos[_key(3, 0)]!.blockHeight, isNull);
  await run(ReserveUTXOCommand(walletId: _walletId, utxoKey: _key(2, 0), reservedByTxId: 'res-1', priority: 3));
  await run(RenewUTXOReservationCommand(
      walletId: _walletId, utxoKey: _key(2, 0), extensionDuration: const Duration(minutes: 5)));
  await run(ReleaseUTXOCommand(walletId: _walletId, utxoKey: _key(2, 0), releaseReason: 'done'));
  await run(ReserveUTXOsCommand(walletId: _walletId, utxoKeys: [_key(4, 0), _key(6, 0)], reservationId: 'batch'));
  await run(ReleaseUTXOsCommand(walletId: _walletId, reservationId: 'batch'));
  await run(RecordImportedTransactionCommand(
    walletId: _walletId,
    txid: 'aa' * 32,
    rawHex: '00',
    blockHeight: 120,
    bumpProofHex: '',
    totalOutputSats: 1000,
    numInputs: 1,
    numOutputs: 1,
    txVersion: 1,
    txLockTime: 0,
    walletReceivingAddresses: [root],
    walletReceivedSats: 1000,
    totalInputSats: 1100,
    sendingAddresses: const [],
  ));

  // A plain payment (spends its input), a deferred one that is cancelled,
  // one that fails, one the network sees, and one left outstanding.
  final plain = _outgoing([_key(2, 0)], sats: 15000);
  await run(plain);
  final cancelled = _outgoing([_key(4, 0)], sats: 30000, deferSpend: true);
  await run(cancelled);
  await run(CancelDeferredSpendCommand(walletId: _walletId, txid: cancelled.txid, reason: 'changed mind'));
  final failed = _outgoing([_key(6, 0)], sats: 50000, deferSpend: true);
  await run(failed);
  await run(RecordTransactionNetworkStatusCommand(
      walletId: _walletId, txid: failed.txid, networkStatus: DeferredNetworkStatus.rejected));
  final seen = _outgoing([_key(1, 0)], sats: 9000, deferSpend: true);
  await run(seen);
  await run(RecordTransactionNetworkStatusCommand(
      walletId: _walletId, txid: seen.txid, networkStatus: DeferredNetworkStatus.seenOnNetwork));
  await run(SpendUTXOCommand(walletId: _walletId, utxoKey: _key(1, 0), spendingTxId: seen.txid, fee: BigInt.from(100)));
  await run(_outgoing([_key(3, 0)], sats: 25000, deferSpend: true));

  await run(ConfirmTransactionCommand(walletId: _walletId, txid: plain.txid, blockHeight: 130, blockHash: 'bb' * 32));
  await run(RevertTransactionConfirmationCommand(walletId: _walletId, txid: plain.txid, reason: 'reorg'));
  await run(ConfirmTransactionCommand(walletId: _walletId, txid: seen.txid, blockHeight: 131, blockHash: 'cc' * 32));
  await run(ReserveUTXOCommand(
      walletId: _walletId,
      utxoKey: _key(5, 0),
      reservedByTxId: 'stale',
      reservationDuration: const Duration(milliseconds: 1)));
  await run(CleanupExpiredReservationsCommand(
      walletId: _walletId, cutoffTime: DateTime.now().add(const Duration(hours: 1))));
  await run(UpdateTransactionStatusCommand(walletId: _walletId, txid: plain.txid, newStatus: TransactionStatus.broadcast));
  await run(BroadcastTransactionCommand(walletId: _walletId, transactionId: plain.txid, signedTransaction: '00'));
  // A split journaled by an earlier release. Nothing emits the event now
  // (bead libspiffy-lph4), but a journal may hold one, and it must replay.
  // ignore: deprecated_member_use_from_same_package
  final split = UTXOSplitInitiatedEvent(
    walletId: _walletId,
    utxoKeysToSplit: [_key(1, 0)],
    targetUtxoCount: 4,
    feeRate: BigInt.one,
    version: wallet.currentState.version + 1,
    timestamp: DateTime.utc(2026, 9, 1),
  );
  await store.persistEvents(wallet.persistenceId, [split], wallet.currentState.version);
  wallet.eventHandler(split);
  return (wallet, store, secureStorage);
}

void _expectSameWalletState(WalletState actual, WalletState expected, String what) {
  expect(actual.toMap(), expected.toMap(), reason: what);
  expect(actual.utxos.keys.toList(), expected.utxos.keys.toList(), reason: '$what: UTXO order');
  expect(actual.addresses.keys.toList(), expected.addresses.keys.toList(), reason: '$what: address order');
  for (final key in ['outgoingTransactions', 'importedTransactions', 'deferredSpends', 'deferredHolds']) {
    expect((actual.metadata[key] as Map?)?.keys.toList(), (expected.metadata[key] as Map?)?.keys.toList(),
        reason: '$what: $key order');
  }
  expect(actual.availableBalance, expected.availableBalance, reason: '$what: available balance');
}

/// A command the aggregate accepts and answers with no event, leaving the
/// state and the journal exactly as they were (bead libspiffy-fggl: a second
/// receipt of an outpoint the wallet already holds is a no-op, not an error —
/// the stored row, with its reservation and spending history, is never
/// overwritten).
Future<void> _expectNoOp(
  AggregateRoot aggregate,
  InMemoryEventStore store,
  Command command,
  Map<String, dynamic> Function() snapshot,
) async {
  final before = snapshot();
  final version = aggregate.currentState.version;
  final journalLength = store.allEvents.length;
  await aggregate.commandHandler(command);
  expect(snapshot(), before, reason: 'a no-op ${command.runtimeType} leaves the state unchanged');
  expect(aggregate.currentState.version, version);
  expect(store.allEvents.length, journalLength, reason: 'a no-op ${command.runtimeType} journals nothing');
}

Future<void> _expectRejected(
  AggregateRoot aggregate,
  InMemoryEventStore store,
  Command command,
  Map<String, dynamic> Function() snapshot,
) async {
  final before = snapshot();
  final version = aggregate.currentState.version;
  final journalLength = store.allEvents.length;
  await expectLater(aggregate.commandHandler(command), throwsA(anything),
      reason: '${command.runtimeType} must be rejected');
  expect(snapshot(), before, reason: 'a rejected ${command.runtimeType} leaves the state unchanged');
  expect(aggregate.currentState.version, version);
  expect(store.allEvents.length, journalLength, reason: 'a rejected ${command.runtimeType} journals nothing');
}

void main() {
  group('mmb characterization: wallet aggregate', () {
    test('the journal replayed and recovered gives the live state', () async {
      final (live, store, secureStorage) = await _liveWallet();
      final journal = store.journal['BitcoinWallet_$_walletId']!;
      expect(journal.length, greaterThan(40));
      expect(live.currentState.metadata['deferredSpends'], isA<Map>());

      final replayed = _Wallet(InMemoryEventStore(), secureStorage)..replay(journal);
      _expectSameWalletState(replayed.currentState, live.currentState, 'replay');

      final recovered = _Wallet(store, secureStorage);
      await recovered.preStart();
      _expectSameWalletState(recovered.currentState, live.currentState, 'recovery');

      final again = _Wallet(InMemoryEventStore(), secureStorage)..replay(journal);
      expect(again.currentState.toMap(), replayed.currentState.toMap(), reason: 'two replays agree');
    });

    test('the snapshot map survives the CBOR round trip and restores the live state', () async {
      final (live, _, _) = await _liveWallet();
      final snapshot = await live.snapshotMap();
      final restored = await live.restore(_cborRoundTrip(snapshot));
      _expectSameWalletState(restored, live.currentState, 'snapshot restore');

      // The snapshot taken earlier is not changed by later events.
      final frozen = _cborRoundTrip(snapshot);
      await live.commandHandler(GenerateAddressCommand(walletId: _walletId, label: 'after snapshot'));
      expect(_cborRoundTrip(snapshot), frozen);
    });

    test('rejected commands leave the state and the journal unchanged', () async {
      final (wallet, store, _) = await _liveWallet();
      Map<String, dynamic> snapshot() => wallet.currentState.toMap();
      final root = wallet.currentState.rootAddress!;
      final outstanding = (wallet.currentState.metadata['deferredSpends'] as Map)
          .entries
          .firstWhere((e) => (e.value as Map)['state'] == DeferredPaymentState.outstanding.name)
          .key as String;

      final rejected = <WalletCommand>[
        CreateWalletCommand(walletId: _walletId, walletName: 'again', mnemonic: _mnemonic),
        UpdateWalletConfigurationCommand(walletId: _walletId),
        ReceiveUTXOCommand(
            walletId: _walletId, txid: 'dd' * 32, vout: 0,
            satoshis: BigInt.zero, scriptPubKey: _p2pkhScript(root), address: root),
        MarkUTXOAvailableCommand(walletId: _walletId, txid: 'ee' * 32, vout: 0),
        SpendUTXOCommand(walletId: _walletId, utxoKey: _key(3, 0), spendingTxId: 'ff' * 32, fee: BigInt.one),
        UpdateUTXOConfirmationsCommand(walletId: _walletId, utxoKey: 'nope:0', confirmations: 1),
        // All or nothing: the first key is reservable, the second is spent.
        ReserveUTXOsCommand(walletId: _walletId, utxoKeys: [_key(5, 0), _key(1, 0)], reservationId: 'partial'),
        ReserveUTXOCommand(walletId: _walletId, utxoKey: _key(3, 0), reservedByTxId: 'steal', priority: 99),
        ReleaseUTXOCommand(walletId: _walletId, utxoKey: _key(3, 0)),
        ReleaseUTXOCommand(walletId: _walletId, utxoKey: _key(5, 0)),
        RenewUTXOReservationCommand(
            walletId: _walletId, utxoKey: _key(3, 0), extensionDuration: const Duration(hours: 1)),
        CancelDeferredSpendCommand(walletId: _walletId, txid: outstanding, networkStatus: 'SEEN_ON_NETWORK'),
        CancelDeferredSpendCommand(walletId: _walletId, txid: 'ab' * 32),
        // Fails once key derivation and signing are under way.
        SignTransactionCommand(
          walletId: _walletId,
          transactionId: 'unsigned',
          rawTransaction: _paymentHex([_key(5, 0)]),
          utxoKeys: [_key(5, 0)],
          publicKeys: const [],
          derivationIndices: const [3],
        ),
        BuildFundingTransactionCommand(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          walletId: _walletId,
          correlationId: 'c',
          channelId: 'ch',
          clientPubKeyHex: '02${'ab' * 32}',
          serverPubKeyHex: '03${'cd' * 32}',
          fundingAmountSats: 1 << 40,
          changeAddressBase58: root,
        ),
        _outgoing([_key(6, 0)], sats: 50000, deferSpend: true), // the failed payment again
      ];
      for (final command in rejected) {
        await _expectRejected(wallet, store, command, snapshot);
      }

      // Receiving an outpoint the wallet already holds is accepted and
      // journals nothing (bead libspiffy-fggl); it used to throw.
      await _expectNoOp(
          wallet,
          store,
          ReceiveUTXOCommand(
              walletId: _walletId, txid: _key(8, 0).split(':').first, vout: 0,
              satoshis: BigInt.one, scriptPubKey: _p2pkhScript(root), address: root),
          snapshot);

      await wallet.commandHandler(DeleteWalletCommand(walletId: _walletId, reason: 'done'));
      await _expectRejected(wallet, store, DeleteWalletCommand(walletId: _walletId), snapshot);
      await _expectRejected(
          wallet, store, AddWatchAddressCommand(walletId: _walletId, address: 'mlate', scriptType: 'p2pkh'), snapshot);
    });
  });

  group('mmb characterization: invoice aggregate', () {
    const invoiceId = 'mmb-invoice';

    Future<(_Invoice, InMemoryEventStore)> liveInvoice() async {
      final store = InMemoryEventStore();
      final invoice = _Invoice(store, invoiceId);
      await invoice.preStart();
      await invoice.commandHandler(CreateInvoiceCommand(
        invoiceId: invoiceId,
        walletId: 'w1',
        addresses: const ['maddr1', 'maddr2'],
        amount: BigInt.from(150000),
        outputs: [
          P2PKHOutputSpec(address: 'maddr1', amount: BigInt.from(100000), label: 'main'),
          P2MSOutputSpec(publicKeys: [for (final seed in ['11', '22']) dartsv.SVPrivateKey.fromHex(seed * 32, dartsv.NetworkType.TEST).publicKey.toHex()], threshold: 1, amount: BigInt.from(50000)),
          OPReturnOutputSpec(dataChunks: const [[104, 105]]),
        ],
        description: 'Coffee',
        expiresIn: const Duration(days: 1),
        invoiceMetadata: {'order': 'A-1', 'lines': [1, 2], 'customer': {'id': 7}},
      ));
      return (invoice, store);
    }

    test('the journal replayed and recovered gives the live state', () async {
      final (live, store) = await liveInvoice();
      await live.commandHandler(MarkInvoicePaidCommand(
          invoiceId: invoiceId, txid: 'ab' * 32, amountReceived: BigInt.from(150001), addressesPaidTo: ['maddr2']));
      final journal = store.journal['Invoice_$invoiceId']!;

      final replayed = _Invoice(InMemoryEventStore(), invoiceId)..replay(journal);
      expect(InvoiceAggregate.invoiceStateToMap(replayed.currentState),
          InvoiceAggregate.invoiceStateToMap(live.currentState));
      final recovered = _Invoice(store, invoiceId);
      await recovered.preStart();
      expect(InvoiceAggregate.invoiceStateToMap(recovered.currentState),
          InvoiceAggregate.invoiceStateToMap(live.currentState));
      expect(recovered.currentState.status, InvoiceStatus.paid);
    });

    test('the snapshot map survives the CBOR round trip and restores the live state', () async {
      final (live, _) = await liveInvoice();
      final snapshot = await live.snapshotMap();
      final restored = await live.restore(_cborRoundTrip(snapshot));
      expect(InvoiceAggregate.invoiceStateToMap(restored), InvoiceAggregate.invoiceStateToMap(live.currentState));
      expect(restored.outputs!.map((o) => o.toMap()).toList(),
          live.currentState.outputs!.map((o) => o.toMap()).toList());
    });

    test('rejected commands leave the state and the journal unchanged', () async {
      final (invoice, store) = await liveInvoice();
      Map<String, dynamic> snapshot() => InvoiceAggregate.invoiceStateToMap(invoice.currentState);
      MarkInvoicePaidCommand pay(List<String> to, int amount) => MarkInvoicePaidCommand(
          invoiceId: invoiceId, txid: 'cd' * 32, amountReceived: BigInt.from(amount), addressesPaidTo: to);

      for (final command in <Command>[
        CreateInvoiceCommand(invoiceId: invoiceId, walletId: 'w1', addresses: const ['m'], amount: BigInt.one),
        pay(['maddr1'], 1),
        pay(['elsewhere'], 150000),
        ExpireInvoiceCommand(invoiceId: invoiceId),
      ]) {
        await _expectRejected(invoice, store, command, snapshot);
      }
      await invoice.commandHandler(CancelInvoiceCommand(invoiceId: invoiceId, reason: 'no'));
      for (final command in <Command>[
        CancelInvoiceCommand(invoiceId: invoiceId),
        pay(['maddr1'], 150000),
      ]) {
        await _expectRejected(invoice, store, command, snapshot);
      }
    });
  });

  group('mmb characterization: payment channel aggregate', () {
    const channelId = 'mmb-channel';
    final funding = BigInt.from(100000);

    List<Event> journal() {
      final t0 = DateTime.utc(2025, 7, 1);
      DateTime at(int minutes) => t0.add(Duration(minutes: minutes));
      return [
        ChannelRequestedEvent(
          channelId: channelId,
          walletId: 'w1',
          clientPeerId: 'client-peer',
          serverPeerId: 'server-peer',
          clientPubKeyHex: '02${'11' * 32}',
          clientAddressB58: 'mclient',
          derivationIndex: 4,
          fundingAmountSats: funding,
          lockTimeUnix: 4000000000,
          context: 'ctx',
          version: 1,
          timestamp: at(0),
        ),
        ServerAcceptanceRecordedEvent(
            channelId: channelId, serverPubKeyHex: '03${'22' * 32}', serverAddressB58: 'mserver', version: 2, timestamp: at(1)),
        RefundBuiltEvent(
          channelId: channelId,
          fundingTxId: 'cd' * 32,
          fundingOutputIndex: 1,
          fundingTxHex: '0100',
          refundTxHex: '0200',
          clientSignatureHex: '3044',
          fundingInputSats: 100500,
          version: 3,
          timestamp: at(2),
        ),
        RefundCountersignedEvent(
            channelId: channelId, serverSignatureHex: '3045', signedRefundTxHex: '0201', version: 4, timestamp: at(3)),
        FundingBroadcastStartedEvent(channelId: channelId, fundingTxId: 'cd' * 32, attempt: 1, version: 5, timestamp: at(4)),
        FundingBroadcastFailedEvent(
            channelId: channelId, fundingTxId: 'cd' * 32, error: 'timeout', walletRecorded: false, version: 6, timestamp: at(5)),
        FundingBroadcastStartedEvent(channelId: channelId, fundingTxId: 'cd' * 32, attempt: 2, version: 7, timestamp: at(6)),
        FundingRecordedInWalletEvent(channelId: channelId, fundingTxId: 'cd' * 32, version: 8, timestamp: at(7)),
        ChannelOpenedEvent(
          channelId: channelId,
          fundingTxId: 'cd' * 32,
          fundingOutputIndex: 1,
          fundingTxHex: '0100',
          fundingAncestorTxids: ['ef' * 32, 'fe' * 32],
          fundingBeefHex: 'beef',
          initialClientBalanceSats: funding,
          initialServerBalanceSats: BigInt.zero,
          version: 9,
          timestamp: at(8),
        ),
        for (var i = 1; i <= 3; i++)
          PaymentRecordedEvent(
            channelId: channelId,
            amountSats: BigInt.from(1000),
            newClientBalanceSats: funding - BigInt.from(1000 * i),
            newServerBalanceSats: BigInt.from(1000 * i),
            sequenceNumber: i,
            paymentTxHex: '03$i',
            paymentTxId: '1$i' * 32,
            clientSignatureHex: '3046',
            version: 9 + i,
            timestamp: at(8 + i),
          ),
      ];
    }

    Future<(_Channel, InMemoryEventStore)> openChannel() async {
      final store = InMemoryEventStore()..journal['PaymentChannel_$channelId'] = journal();
      final channel = _Channel(store, channelId);
      await channel.preStart();
      return (channel, store);
    }

    test('the journal replayed and recovered gives the same state', () async {
      final (recovered, _) = await openChannel();
      final replayed = _Channel(InMemoryEventStore(), channelId)..replay(journal());
      expect(PaymentChannelAggregate.channelStateToMap(replayed.currentState),
          PaymentChannelAggregate.channelStateToMap(recovered.currentState));
      expect(recovered.currentState.status, ChannelStatus.open);
      expect(recovered.currentState.latestSequenceNumber, 3);
      expect(recovered.currentState.fundingAncestorTxids, ['ef' * 32, 'fe' * 32]);
    });

    test('the snapshot map survives the CBOR round trip and restores the live state', () async {
      final (channel, _) = await openChannel();
      final snapshot = await channel.snapshotMap();
      final restored = await channel.restore(_cborRoundTrip(snapshot));
      expect(PaymentChannelAggregate.channelStateToMap(restored),
          PaymentChannelAggregate.channelStateToMap(channel.currentState));
    });

    test('rejected commands leave the state and the journal unchanged', () async {
      final (channel, store) = await openChannel();
      Map<String, dynamic> snapshot() => PaymentChannelAggregate.channelStateToMap(channel.currentState);
      RecordPaymentCommand pay({required int amount, required int sequence, int? client}) => RecordPaymentCommand(timing: testChannelTiming, feeRate: const FeeRate(satoshis: 100, bytes: 1000),
            channelId: channelId,
            amountSats: BigInt.from(amount),
            sequenceNumber: sequence,
            paymentTxHex: '00',
            paymentTxId: '99' * 32,
            clientSignatureHex: '30',
            newClientBalanceSats: BigInt.from(client ?? 97000 - amount),
            newServerBalanceSats: BigInt.from(3000 + amount),
          );
      for (final command in <Command>[
        pay(amount: 1000000, sequence: 4),
        pay(amount: 1000, sequence: 3),
        pay(amount: 1000, sequence: 4, client: 1),
        AcceptChannelCommand(timing: testChannelTiming, 
          channelId: channelId,
          walletId: 'w1',
          clientPeerId: 'p',
          clientPubKeyHex: '02',
          clientAddressB58: 'm',
          serverPubKeyHex: '03',
          serverAddressB58: 'n',
          derivationIndex: 0,
          fundingAmountSats: funding,
          lockTimeUnix: 1,
        ),
        FinalizeCloseCommand(
            channelId: channelId,
            settlementTxId: 'aa' * 32,
            finalClientBalanceSats: BigInt.one,
            finalServerBalanceSats: BigInt.one,
            settlementTxHex: '00'),
        ClaimRefundCommand(channelId: channelId),
        ExpireChannelCommand(channelId: channelId, observedBy: 'test'),
        StartFundingBroadcastCommand(channelId: channelId, fundingTxId: 'cd' * 32),
      ]) {
        await _expectRejected(channel, store, command, snapshot);
      }
    });
  });
}
