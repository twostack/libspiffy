/// Bead libspiffy-viy: which outputs are the wallet's own UTXOs, and
/// recording the same outgoing transaction twice.
///
/// Part 1: RecordOutgoingTransactionCommand treated a bare multisig output
/// as the wallet's as soon as one of its keys was a wallet key. A payment
/// channel's 2-of-2 funding output (client key + server key) became a
/// pending wallet UTXO that counted towards the balance and, once confirmed,
/// towards the payment UTXOs, although the wallet cannot spend it without
/// the server's signature. PaymentChannelManagerActor contained it with a
/// 100-year reservation. The wallet now owns a multisig output only when it
/// holds as many of its keys as the script requires.
///
/// Part 2: a RecordOutgoingTransactionCommand for a txid the wallet had
/// already recorded (a restart during channel funding re-sends it) journaled
/// a second TransactionRecordedEvent, which reset the history row (a
/// confirmed transaction went back to pending), and, without deferSpend,
/// spent the inputs again.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

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

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'wallet-output-ownership';

/// A key that is not the wallet's (the channel server's).
final _serverKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST);

String _txid(String c) => List.filled(64, c).join();

void main() {
  late InMemoryEventStore store;
  late InMemorySecureStorage secureStorage;
  late DartSVCryptoService cryptoService;
  late BitcoinWalletAggregate wallet;
  late String address;
  late String address2;
  late dartsv.SVPublicKey walletKey;
  late dartsv.SVPublicKey walletKey2;

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
      walletName: 'Output ownership wallet',
      mnemonic: _mnemonic,
    ));
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId, label: 'a', includePublicKey: true));
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId, label: 'b', includePublicKey: true));
    final generated = store.allEvents.whereType<AddressGeneratedEvent>().toList();
    address = generated[generated.length - 2].address;
    address2 = generated.last.address;
    walletKey = dartsv.SVPublicKey.fromHex(generated[generated.length - 2].publicKeyHex!);
    walletKey2 = dartsv.SVPublicKey.fromHex(generated.last.publicKeyHex!);
    expect(walletKey.toAddress(dartsv.NetworkType.TEST).toBase58(), address);
  });

  dartsv.SVScript p2pkh(String a) =>
      dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(a)).getScriptPubkey();

  dartsv.SVScript multisig(List<dartsv.SVPublicKey> keys, int threshold) =>
      dartsv.P2MSLockBuilder(keys, threshold, sorting: false).getScriptPubkey();

  /// A transaction spending [input] with [outputs] (amount, script).
  dartsv.Transaction txWith(List<(int, dartsv.SVScript)> outputs, {String input = 'a'}) {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput(_txid(input), 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    for (final (sats, script) in outputs) {
      tx.outputs.add(dartsv.TransactionOutput(BigInt.from(sats), script));
    }
    return tx;
  }

  RecordOutgoingTransactionCommand record(dartsv.Transaction tx,
          {List<String> spent = const [], bool deferSpend = true}) =>
      RecordOutgoingTransactionCommand(
        walletId: _walletId,
        txid: tx.id,
        rawHex: tx.serialize(),
        totalInputSats: 150200,
        totalOutputSats: 150000,
        fee: 200,
        numInputs: tx.inputs.length,
        numOutputs: tx.outputs.length,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: spent,
        recipientAddresses: const ['channel:c1'],
        paymentAmount: BigInt.from(100000),
        deferSpend: deferSpend,
      );

  /// Applies the whole journal, in order, to a fresh read model.
  Future<InMemoryWalletStorage> project() async {
    final storage = InMemoryWalletStorage();
    final projection = WalletProjection(
      projectionId: 'ownership-test',
      eventStore: store,
      storage: storage,
    );
    for (final event in store.allEvents) {
      await projection.handle(event);
    }
    return storage;
  }

  Future<String> receive(String txid, {int sats = 150200}) async {
    await wallet.commandHandler(ReceiveUTXOCommand(
      walletId: _walletId,
      txid: txid,
      vout: 0,
      satoshis: BigInt.from(sats),
      scriptPubKey: p2pkh(address).toHex(),
      address: address,
      initialStatus: UTXOStatus.available,
    ));
    return '$txid:0';
  }

  group('viy part 1: an output the wallet cannot spend alone is not a wallet UTXO', () {
    test(
        'recording a channel funding transaction: the 2-of-2 output holding a '
        'wallet key is no UTXO, the change is, and the transaction is kept whole',
        () async {
      final funding = txWith([
        (100000, multisig([walletKey, _serverKey.publicKey], 2)),
        (50000, p2pkh(address)),
      ]);

      await wallet.commandHandler(record(funding));

      final state = wallet.currentState;
      expect(state.utxos.containsKey('${funding.id}:0'), isFalse,
          reason: 'the channel output needs the server signature too');
      expect(state.utxos['${funding.id}:1']?.satoshis, BigInt.from(50000));
      expect(state.balance, BigInt.from(50000));
      expect(
          store.allEvents
              .whereType<UTXOReceivedEvent>()
              .where((e) => e.txid == funding.id)
              .map((e) => e.vout),
          [1]);

      final storage = await project();
      final rows = await storage.getUTXOs(_walletId, includeSpent: true);
      expect(rows.map((u) => u.key), ['${funding.id}:1']);
      final history = await storage.getTransaction(funding.id, walletId: _walletId);
      expect(history, isNotNull);
      expect(history!.rawHex, funding.serialize(),
          reason: 'the funding transaction stays recorded with its raw bytes');
      expect(dartsv.Transaction.fromHex(history.rawHex).outputs, hasLength(2));
    });

    test('a 2-of-2 whose keys are both the wallet\'s is a wallet UTXO', () async {
      final tx = txWith([(100000, multisig([walletKey, walletKey2], 2))]);
      await wallet.commandHandler(record(tx));
      expect(wallet.currentState.utxos.containsKey('${tx.id}:0'), isTrue);
    });

    test('a 1-of-2 holding one wallet key is a wallet UTXO', () async {
      final tx = txWith([(100000, multisig([_serverKey.publicKey, walletKey], 1))]);
      await wallet.commandHandler(record(tx));
      final utxo = wallet.currentState.utxos['${tx.id}:0'];
      expect(utxo, isNotNull);
      expect(utxo!.address, address);
    });

    test('a 2-of-3 holding one wallet key is not a wallet UTXO', () async {
      final other = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey;
      final tx = txWith([(100000, multisig([walletKey, _serverKey.publicKey, other], 2))]);
      await wallet.commandHandler(record(tx));
      expect(wallet.currentState.utxos.containsKey('${tx.id}:0'), isFalse);
    });

    test('ReceiveUTXOCommand attributing a 2-of-2 output to a wallet address is rejected',
        () async {
      final before = store.allEvents.length;
      await expectLater(
        wallet.commandHandler(ReceiveUTXOCommand(
          walletId: _walletId,
          txid: _txid('b'),
          vout: 0,
          satoshis: BigInt.from(100000),
          scriptPubKey: multisig([walletKey, _serverKey.publicKey], 2).toHex(),
          address: address,
          initialStatus: UTXOStatus.available,
        )),
        throwsA(isA<StateError>()),
      );
      expect(store.allEvents.length, before);
      expect(wallet.currentState.balance, BigInt.zero);
    });

    test(
        'a journal written before the fix (channel output received, then reserved '
        'for the channel) replays with the output reserved and outside the balance',
        () async {
      // Regression guard for replay: the events are facts and replay as
      // written; the reservation they carry keeps the output out of the
      // balance and the payment UTXOs.
      final funding = txWith([
        (100000, multisig([walletKey, _serverKey.publicKey], 2)),
        (50000, p2pkh(address)),
      ]);
      await wallet.commandHandler(record(funding));
      var version = wallet.currentState.version;
      final at = DateTime.utc(2026, 9, 1);
      await store.persistEvents(store.journal.keys.single, [
        UTXOReceivedEvent(
          walletId: _walletId,
          txid: funding.id,
          vout: 0,
          satoshis: 100000,
          scriptPubKey: funding.outputs[0].script.toHex(),
          address: address,
          confirmations: 0,
          initialStatus: UTXOStatus.pending,
          version: ++version,
          timestamp: at,
        ),
        UTXOReservedEvent(
          walletId: _walletId,
          txid: funding.id,
          vout: 0,
          reservedByTxId: 'channel:c1',
          reservationReason: 'Payment channel c1 2-of-2 funding output',
          expiresAt: at.add(const Duration(days: 365 * 100)),
          priority: 1000,
          version: ++version,
          timestamp: at,
        ),
        UTXOConfirmationUpdatedEvent(
          walletId: _walletId,
          txid: funding.id,
          vout: 0,
          blockHeight: 900,
          confirmations: 6,
          version: ++version,
          timestamp: at,
        ),
      ], 0);

      final replayed = newAggregate();
      await replayed.preStart();
      final channelOutput = replayed.currentState.utxos['${funding.id}:0'];
      expect(channelOutput?.status, UTXOStatus.reserved);
      expect(replayed.currentState.balance, BigInt.from(50000));

      final storage = await project();
      expect((await storage.getPaymentUTXOs(_walletId)).map((u) => u.key),
          isNot(contains('${funding.id}:0')));
      expect(await storage.getBalance(_walletId), BigInt.zero,
          reason: 'the change is still pending; the channel output is reserved');
    });
  });

  group('viy part 2: recording the same outgoing transaction again', () {
    test(
        'a record re-sent after a restart journals nothing and leaves the '
        'confirmed history row confirmed', () async {
      final input = await receive(_txid('c'));
      final funding = txWith([
        (100000, multisig([walletKey, _serverKey.publicKey], 2)),
        (50000, p2pkh(address)),
      ], input: 'c');
      await wallet.commandHandler(record(funding, spent: [input]));
      await wallet.commandHandler(SpendUTXOCommand(
          walletId: _walletId, utxoKey: input, spendingTxId: funding.id, fee: BigInt.from(200)));
      await wallet.commandHandler(ConfirmTransactionCommand(
          walletId: _walletId, txid: funding.id, blockHeight: 900, blockHash: 'ab' * 32));
      final balance = wallet.currentState.balance;
      final journalLength = store.allEvents.length;

      // Restart: a fresh aggregate over the same journal gets the same
      // command again.
      wallet = newAggregate();
      await wallet.preStart();
      await wallet.commandHandler(record(funding, spent: [input]));

      final storage = await project();
      final history = await storage.getTransactionHistory(_walletId);
      expect(history.where((t) => t.txid == funding.id), hasLength(1));
      final row = await storage.getTransaction(funding.id, walletId: _walletId);
      expect(row!.status, TransactionStatus.confirmed,
          reason: 'recording the transaction again must not reset its history row');
      expect(row.blockHeight, 900);

      expect(store.allEvents.length, journalLength,
          reason: 'the transaction was recorded already: nothing new to journal');
      expect(store.allEvents.whereType<TransactionRecordedEvent>(), hasLength(1));
      expect(wallet.currentState.balance, balance);
    });

    test(
        'rebuilding the read model from a journal holding a second '
        'TransactionRecordedEvent (written before the fix) keeps the row confirmed',
        () async {
      final tx = txWith([(150000, p2pkh(address2))], input: 'f');
      await wallet.commandHandler(record(tx));
      await wallet.commandHandler(ConfirmTransactionCommand(
          walletId: _walletId, txid: tx.id, blockHeight: 901, blockHash: 'cd' * 32));
      final first = store.allEvents.whereType<TransactionRecordedEvent>().single;
      await store.persistEvents(store.journal.keys.single, [
        TransactionRecordedEvent(
          walletId: _walletId,
          txid: tx.id,
          rawHex: first.rawHex,
          totalInputSats: first.totalInputSats,
          totalOutputSats: first.totalOutputSats,
          fee: first.fee,
          numInputs: first.numInputs,
          numOutputs: first.numOutputs,
          txVersion: first.txVersion,
          txLockTime: first.txLockTime,
          spentUtxoKeys: first.spentUtxoKeys,
          recipientAddresses: first.recipientAddresses,
          paymentAmount: first.paymentAmount,
          version: wallet.currentState.version + 1,
          timestamp: first.timestamp.add(const Duration(minutes: 5)),
        ),
      ], 0);

      final storage = await project();
      final row = await storage.getTransaction(tx.id, walletId: _walletId);
      expect(row!.status, TransactionStatus.confirmed);
      expect(row.blockHeight, 901);
      expect(row.createdAt, first.timestamp, reason: 'the first record time is kept');
      expect(row.rawHex, tx.serialize());
    });

    test('a duplicate record without deferSpend does not spend the inputs again', () async {
      final input = await receive(_txid('d'));
      final tx = txWith([(150000, p2pkh(address2))], input: 'd');

      await wallet.commandHandler(record(tx, spent: [input], deferSpend: false));
      expect(wallet.currentState.utxos[input]!.status, UTXOStatus.spent);
      await wallet.commandHandler(record(tx, spent: [input], deferSpend: false));

      expect(store.allEvents.whereType<UTXOSpentEvent>(), hasLength(1));
      expect(store.allEvents.whereType<TransactionRecordedEvent>(), hasLength(1));
      expect(store.allEvents.whereType<UTXOReceivedEvent>().where((e) => e.txid == tx.id),
          hasLength(1));
    });

    test('recorded with deferSpend, then again without: the inputs still held are spent',
        () async {
      final input = await receive(_txid('e'));
      await wallet.commandHandler(ReserveUTXOCommand(
          walletId: _walletId, utxoKey: input, reservedByTxId: 'payment'));
      final tx = txWith([(150000, p2pkh(address2))], input: 'e');

      await wallet.commandHandler(record(tx, spent: [input]));
      expect(wallet.currentState.utxos[input]!.status, UTXOStatus.reserved);
      await wallet.commandHandler(record(tx, spent: [input], deferSpend: false));

      expect(wallet.currentState.utxos[input]!.status, UTXOStatus.spent);
      expect(wallet.currentState.utxos[input]!.spentInTxId, tx.id);
      expect(store.allEvents.whereType<TransactionRecordedEvent>(), hasLength(1));
    });
  });

  group('viy part 3: the read model carries what the aggregate knows of a UTXO', () {
    test(
        'reservation (holder, reason, expiry, priority, renewal, status before '
        'reservation) and the spending transaction reach the read-model row',
        () async {
      final key = await receive(_txid('9'));
      await wallet.commandHandler(ReceiveUTXOCommand(
        walletId: _walletId,
        txid: _txid('8'),
        vout: 0,
        satoshis: BigInt.from(70000),
        scriptPubKey: p2pkh(address).toHex(),
        address: address,
        initialStatus: UTXOStatus.pending,
      ));
      final pendingKey = '${_txid('8')}:0';
      await wallet.commandHandler(ReserveUTXOCommand(
        walletId: _walletId,
        utxoKey: pendingKey,
        reservedByTxId: 'payment-1',
        reservationReason: 'pending payment',
        reservationDuration: const Duration(minutes: 10),
        priority: 5,
      ));
      await wallet.commandHandler(RenewUTXOReservationCommand(
        walletId: _walletId,
        utxoKey: pendingKey,
        extensionDuration: const Duration(minutes: 30),
        renewalReason: 'still signing',
      ));
      final tx = txWith([(150000, p2pkh(address2))], input: '9');
      await wallet.commandHandler(record(tx, spent: [key], deferSpend: false));

      final aggregateRow = wallet.currentState.utxos[pendingKey]!;
      final storage = await project();
      final rows = {
        for (final u in await storage.getUTXOs(_walletId, includeSpent: true)) u.key: u,
      };

      final reserved = rows[pendingKey]!;
      expect(reserved.status, UTXOStatus.reserved);
      expect(reserved.reservedByTxId, 'payment-1');
      expect(reserved.reservationPriority, 5);
      expect(reserved.reservationReason, 'still signing');
      expect(reserved.reservationExpiresAt, aggregateRow.reservationExpiresAt,
          reason: 'the renewed expiry');
      expect(reserved.statusBeforeReservation, UTXOStatus.pending);

      expect(rows[key]!.status, UTXOStatus.spent);
      expect(rows[key]!.spentInTxId, tx.id);
    });
  });
}
