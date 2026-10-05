/// Outputs a wallet held as unspent although a confirmed transaction spends
/// them, and the payments built from them.
///
/// The case behind it: an imported wallet recorded a parent after the two
/// transactions that spent its outputs (all three in one block), so both
/// outputs stayed available. A deferred payment later spent one; the
/// network never took it, ARC kept it SENT_TO_NETWORK, the payer offered a
/// reclaim and the payee showed it broadcasting for ever.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/deferred_payment.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/spent_output_repair.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

const _w = 'spent-elsewhere-wallet';
const _address = 'mrootaddress0000000000000000000000';
final _parent = 'a1' * 32;
final _spentOutput = '$_parent:0';
final _otherOutput = '$_parent:1';
final _received = 'd4' * 32;

String _spending(List<String> inputs, {int sats = 1000}) {
  final tx = dartsv.Transaction();
  for (final key in inputs) {
    final parts = key.split(':');
    tx.addInput(dartsv.TransactionInput(parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
  }
  tx.addOutput(dartsv.TransactionOutput(
      BigInt.from(sats), dartsv.SVScript.fromHex('76a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac')));
  return tx.serialize();
}

BitcoinTransaction _row(String rawHex, TransactionStatus status, {int? height}) => BitcoinTransaction(
      walletId: _w,
      txid: dartsv.Transaction.fromHex(rawHex).id,
      rawHex: rawHex,
      status: status,
      blockHeight: height,
      inputValue: BigInt.zero,
      outputValue: BigInt.from(1000),
      fee: BigInt.zero,
      receivingAddresses: const [],
      sendingAddresses: const [],
      netAmount: BigInt.zero,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

BitcoinUtxo _utxo(String key, UTXOStatus status, {String? reservedBy}) {
  final parts = key.split(':');
  return BitcoinUtxo(
    txid: parts[0],
    vout: int.parse(parts[1]),
    value: dartsv.Coin.ofSat(BigInt.from(13442179)),
    scriptPubKey: '76a914${'00' * 20}88ac',
    address: _address,
    status: status,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    reservedByTxId: reservedBy,
  );
}

class _NoStore implements EventStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
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

/// A live aggregate with the parent's two outputs available and an incoming
/// payment's output pending.
class _Wallet {
  final BitcoinWalletAggregate aggregate = BitcoinWalletAggregate(
    aggregateId: _w,
    aggregateType: 'BitcoinWallet',
    eventStore: _NoStore(),
    cryptoService: DartSVCryptoService(),
    secureStorage: InMemorySecureStorage(),
  );

  _Wallet() {
    apply([
      WalletCreatedEvent(
        walletId: _w,
        walletName: 'w',
        rootAddress: _address,
        walletType: WalletType.hd,
        walletMetadata: {'network': 'testnet'},
        version: 1,
        timestamp: DateTime.utc(2026),
      ),
    ]);
    receive(_spentOutput, UTXOStatus.available);
    receive(_otherOutput, UTXOStatus.available);
    receive('$_received:0', UTXOStatus.pending);
  }

  void apply(List<Event> events) {
    for (final e in events) {
      aggregate.eventHandler(e);
    }
  }

  void receive(String key, UTXOStatus status) {
    final parts = key.split(':');
    apply([
      UTXOReceivedEvent(
        walletId: _w,
        txid: parts[0],
        vout: int.parse(parts[1]),
        satoshis: 13442179,
        scriptPubKey: '76a914${'00' * 20}88ac',
        address: _address,
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

  /// A deferred (offline) payment spending [inputs].
  Future<String> payDeferred(List<String> inputs) async {
    final rawHex = _spending(inputs, sats: 5000);
    final txid = dartsv.Transaction.fromHex(rawHex).id;
    await handle(RecordOutgoingTransactionCommand(
      walletId: _w,
      txid: txid,
      rawHex: rawHex,
      totalInputSats: 13442179,
      totalOutputSats: 5000,
      fee: 100,
      numInputs: inputs.length,
      numOutputs: 1,
      txVersion: 1,
      txLockTime: 0,
      spentUtxoKeys: inputs,
      recipientAddresses: const ['muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg'],
      paymentAmount: BigInt.from(5000),
      deferSpend: true,
      invoiceId: 'inv',
      purpose: 'invoice-payment',
    ));
    return txid;
  }
}

void main() {
  group('SpentOutputRepair.find', () {
    test('an output a confirmed transaction spends is found; one only an unconfirmed one spends is not', () {
      final confirmed = _row(_spending([_spentOutput]), TransactionStatus.confirmed, height: 1730300);
      final seen = _row(_spending([_otherOutput]), TransactionStatus.seenOnNetwork);
      final findings = SpentOutputRepair.find(
        transactions: [confirmed, seen],
        utxos: [_utxo(_spentOutput, UTXOStatus.available), _utxo(_otherOutput, UTXOStatus.available)],
      );
      expect(findings, hasLength(1));
      expect(findings.single.utxoKey, _spentOutput);
      expect(findings.single.spentBy, confirmed.txid);
      expect(findings.single.blockHeight, 1730300);
      expect(findings.single.heldBy, isNull);
    });

    test('an output held for another transaction names that holder', () {
      final confirmed = _row(_spending([_spentOutput]), TransactionStatus.confirmed);
      final findings = SpentOutputRepair.find(
        transactions: [confirmed],
        utxos: [_utxo(_spentOutput, UTXOStatus.reserved, reservedBy: 'stuck-payment')],
      );
      expect(findings.single.heldBy, 'stuck-payment');
    });

    test('spent and voided outputs, and outputs nothing spends, are left alone', () {
      final confirmed = _row(_spending([_spentOutput]), TransactionStatus.confirmed);
      expect(
        SpentOutputRepair.find(
          transactions: [confirmed],
          utxos: [_utxo(_spentOutput, UTXOStatus.spent), _utxo(_otherOutput, UTXOStatus.available)],
        ),
        isEmpty,
      );
      expect(
        SpentOutputRepair.find(transactions: [confirmed], utxos: [_utxo(_spentOutput, UTXOStatus.voided)]),
        isEmpty,
      );
    });
  });

  group('SpentOutputRepair.run', () {
    test('a deferred payment holding the output fails first, its row fails, then the output is spent', () async {
      final storage = InMemoryWalletStorage();
      await storage.storeWallet(_w, 'W');
      final confirmed = _row(_spending([_spentOutput]), TransactionStatus.confirmed, height: 1730300);
      await storage.storeTransaction(_w, confirmed);
      await storage.upsertUTXO(_w, _utxo(_spentOutput, UTXOStatus.reserved, reservedBy: 'stuck-payment'));
      await storage.storeDeferredPayment(DeferredPayment(
        walletId: _w,
        txid: 'stuck-payment',
        amount: BigInt.from(5000),
        fee: BigInt.from(100),
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ));

      final sent = <WalletCommand>[];
      await SpentOutputRepair.run(walletId: _w, storage: storage, send: sent.add);

      expect(sent, hasLength(3));
      final failure = sent[0] as RecordTransactionNetworkStatusCommand;
      expect(failure.txid, 'stuck-payment');
      expect(failure.networkStatus, DeferredNetworkStatus.inputSpent);
      expect(failure.detail, contains(confirmed.txid));
      final row = sent[1] as UpdateTransactionStatusCommand;
      expect((row.txid, row.newStatus), ('stuck-payment', TransactionStatus.failed));
      final spend = sent[2] as SpendUTXOCommand;
      expect((spend.utxoKey, spend.spendingTxId, spend.blockHeight), (_spentOutput, confirmed.txid, 1730300));
    });

    test('a wallet with nothing to repair sends nothing', () async {
      final storage = InMemoryWalletStorage();
      await storage.storeWallet(_w, 'W');
      await storage.upsertUTXO(_w, _utxo(_spentOutput, UTXOStatus.available));
      final sent = <WalletCommand>[];
      await SpentOutputRepair.run(walletId: _w, storage: storage, send: sent.add);
      expect(sent, isEmpty);
    });
  });

  group('the aggregate', () {
    test('INPUT_SPENT fails an outstanding deferred payment and releases its inputs; the spend then applies',
        () async {
      final wallet = _Wallet();
      final stuck = await wallet.payDeferred([_spentOutput]);
      expect(wallet.utxo(_spentOutput).reservedByTxId, stuck);

      final events = await wallet.handle(RecordTransactionNetworkStatusCommand(
        walletId: _w,
        txid: stuck,
        networkStatus: DeferredNetworkStatus.inputSpent,
        source: 'wallet',
        explicit: true,
        detail: 'Input $_spentOutput is already spent by ${'e5' * 32}',
      ));
      final failed = events.whereType<DeferredTransactionFailedEvent>().single;
      expect(failed.reason, contains('already spent'));
      expect(wallet.utxo(_spentOutput).status, UTXOStatus.available);

      await wallet.handle(SpendUTXOCommand(
          walletId: _w, utxoKey: _spentOutput, spendingTxId: 'e5' * 32, fee: BigInt.zero, blockHeight: 1730300));
      expect(wallet.utxo(_spentOutput).status, UTXOStatus.spent);
      expect(wallet.utxo(_otherOutput).status, UTXOStatus.available);
    });

    test('voiding a transaction handed to the wallet voids its pending outputs, once', () async {
      final wallet = _Wallet();
      final command = VoidUnsettledTransactionCommand(
          walletId: _w, txid: _received, spentInput: _spentOutput, spentBy: 'e5' * 32);

      final events = await wallet.handle(command);
      expect(events.single, isA<TransactionVoidedEvent>());
      expect(wallet.utxo('$_received:0').status, UTXOStatus.voided);

      expect(await wallet.handle(command), isEmpty);
    });

    test('a deferred payment of the wallet is not voided: it fails through its network status', () async {
      final wallet = _Wallet();
      final stuck = await wallet.payDeferred([_spentOutput]);
      expect(
        () => wallet.handle(
            VoidUnsettledTransactionCommand(walletId: _w, txid: stuck, spentInput: _spentOutput, spentBy: 'e5' * 32)),
        throwsStateError,
      );
    });

    test('the voided event survives a round trip through its map', () {
      final event = TransactionVoidedEvent(
          walletId: _w, txid: _received, spentInput: _spentOutput, spentBy: 'e5' * 32, version: 7);
      final back = TransactionVoidedEvent.fromMap({...event.toMap(), 'walletId': _w});
      expect((back.txid, back.spentInput, back.spentBy), (_received, _spentOutput, 'e5' * 32));
    });
  });

  group('the read model', () {
    test('a voided transaction row fails and its pending output is voided', () async {
      final storage = InMemoryWalletStorage();
      await storage.storeWallet(_w, 'W');
      final received = _row(_spending([_spentOutput]), TransactionStatus.broadcast);
      await storage.storeTransaction(_w, received);
      await storage.upsertUTXO(_w, _utxo('${received.txid}:0', UTXOStatus.pending));
      final projection = WalletProjection(projectionId: 'p', eventStore: _NoopEventStore(), storage: storage);

      await projection.handle(TransactionVoidedEvent(
          walletId: _w, txid: received.txid, spentInput: _spentOutput, spentBy: 'e5' * 32, version: 9));

      expect((await storage.getTransaction(received.txid, walletId: _w))!.status, TransactionStatus.failed);
      expect((await storage.getUTXO(_w, received.txid, 0))!.status, UTXOStatus.voided);
    });
  });
}
