/// Audit 2026-09-14 M5 (libspiffy-9gv): the signed-transaction and
/// funding-transaction success replies were sent from inside
/// `handleCommand`, before the events were persisted. When persistence then
/// failed, the caller already held a signed transaction (and could broadcast
/// it) that the journal never recorded, followed by a contradictory failure
/// reply.
///
/// The fix sends those replies from `onCommandProcessed`, after the events
/// are journaled; a persist failure yields only the failure reply.
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/wallet_messages.dart';
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
const _walletId = 'wallet-m5';
const _aggregateType = 'BitcoinWallet';

void main() {
  late _SwitchableEventStore store;
  late InMemorySecureStorage secureStorage;
  late DartSVCryptoService cryptoService;
  late TestActorSystem system;
  late String utxoKey;
  late String walletAddress;

  setUp(() async {
    store = _SwitchableEventStore();
    secureStorage = InMemorySecureStorage();
    cryptoService = DartSVCryptoService();

    // Build the journal outside the actor system: a wallet with one
    // confirmed P2PKH UTXO.
    final setup = BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: _aggregateType,
      eventStore: store,
      cryptoService: cryptoService,
      secureStorage: secureStorage,
    );
    await setup.preStart();
    await setup.commandHandler(CreateWalletCommand(
      walletId: _walletId,
      walletName: 'M5 wallet',
      mnemonic: _mnemonic,
    ));
    await setup.commandHandler(GenerateAddressCommand(walletId: _walletId, label: 'funding'));
    walletAddress = setup.currentState.addresses.keys.last;
    final txid = List.filled(64, 'a').join();
    await setup.commandHandler(ReceiveUTXOCommand(
      walletId: _walletId,
      txid: txid,
      vout: 0,
      satoshis: BigInt.from(100000),
      scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(walletAddress))
          .getScriptPubkey()
          .toHex(),
      address: walletAddress,
      initialStatus: UTXOStatus.available,
      blockHeight: 800000,
      confirmations: 6,
    ));
    utxoKey = '$txid:0';

    system = TestActorSystem();
  });

  tearDown(() async {
    await system.shutdown();
  });

  Future<(ActorRef, _Probe)> spawnWallet() async {
    final probe = _Probe(store);
    final probeRef = await system.spawn('probe', () => probe);
    final walletRef = await system.spawn(
      'wallet-$_walletId',
      () => BitcoinWalletAggregate(
        aggregateId: _walletId,
        aggregateType: _aggregateType,
        eventStore: store,
        cryptoService: cryptoService,
        secureStorage: secureStorage,
      ),
    );
    return (walletRef, probe..self = probeRef);
  }

  String unsignedTx() {
    final parts = utxoKey.split(':');
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput(
        parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
    tx.outputs.add(dartsv.TransactionOutput(
        BigInt.from(99000),
        dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(_externalAddress))
            .getScriptPubkey()));
    return tx.serialize();
  }

  SignTransactionCommand signCommand() => SignTransactionCommand(
        walletId: _walletId,
        transactionId: 'm5-spend',
        rawTransaction: unsignedTx(),
        utxoKeys: [utxoKey],
        publicKeys: const [],
      );

  BuildFundingTransactionCommand fundingCommand() {
    final serverKey = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
    final clientKey = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
    return BuildFundingTransactionCommand(
      walletId: _walletId,
      correlationId: 'corr-m5',
      channelId: 'channel-m5',
      clientPubKeyHex: clientKey.publicKey.toHex(),
      serverPubKeyHex: serverKey.publicKey.toHex(),
      fundingAmountSats: 50000,
      changeAddressBase58: walletAddress,
    );
  }

  group('M5: signed-transaction reply', () {
    test('is not sent when the TransactionSignedEvent cannot be persisted', () async {
      final (walletRef, probe) = await spawnWallet();
      store.failPersist = true;

      walletRef.tell(signCommand(), sender: probe.self);
      await probe.waitFor<TransactionSignedResponse>((r) => !r.success);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final replies = probe.received.whereType<TransactionSignedResponse>().toList();
      expect(replies.where((r) => r.success), isEmpty,
          reason: 'the caller must not receive a signed transaction the journal never recorded');
      expect(replies.single.success, isFalse);
      expect(replies.single.error, contains('journal unavailable'));
      expect(store.allEvents.whereType<TransactionSignedEvent>(), isEmpty);
    });

    test('is sent after the TransactionSignedEvent is journaled, with the signed tx', () async {
      final (walletRef, probe) = await spawnWallet();
      store.persistDelay = const Duration(milliseconds: 200);

      walletRef.tell(signCommand(), sender: probe.self);
      final reply = await probe.waitFor<TransactionSignedResponse>((_) => true);

      expect(reply.success, isTrue);
      expect(reply.signedHex, isNotEmpty);
      expect(dartsv.Transaction.fromHex(reply.signedHex).id, reply.txid);
      expect(probe.journaledAtReceipt[reply], isTrue,
          reason: 'the TransactionSignedEvent must be journaled before the reply is sent');
      final event = store.allEvents.whereType<TransactionSignedEvent>().single;
      expect(event.txid, reply.txid);
      expect(event.signedRawHex, reply.signedHex);
    });
  });

  group('M5: funding-transaction reply', () {
    test('is not sent when the reservation events cannot be persisted', () async {
      final (walletRef, probe) = await spawnWallet();
      store.failPersist = true;

      walletRef.tell(fundingCommand(), sender: probe.self);
      await probe.waitFor<FundingTransactionBuiltResponse>((r) => !r.success);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final replies = probe.received.whereType<FundingTransactionBuiltResponse>().toList();
      expect(replies.where((r) => r.success), isEmpty,
          reason: 'the caller must not receive a funding tx whose inputs were never reserved');
      expect(replies.single.success, isFalse);
      expect(store.allEvents.whereType<UTXOReservedEvent>(), isEmpty);
    });

    test('is sent after the reservations are journaled, with the full payload', () async {
      final (walletRef, probe) = await spawnWallet();
      store.persistDelay = const Duration(milliseconds: 200);

      walletRef.tell(fundingCommand(), sender: probe.self);
      final reply = await probe.waitFor<FundingTransactionBuiltResponse>((_) => true);

      expect(reply.success, isTrue);
      expect(reply.correlationId_, 'corr-m5');
      expect(reply.channelId, 'channel-m5');
      expect(reply.spentUtxoKeys, [utxoKey]);
      expect(dartsv.Transaction.fromHex(reply.fundingTxHex).id, reply.fundingTxId);
      expect(reply.fee, greaterThan(0));
      expect(probe.journaledAtReceipt[reply], isTrue,
          reason: 'the reservation events must be journaled before the reply is sent');
      expect(store.allEvents.whereType<UTXOReservedEvent>().single.reservedByTxId,
          reply.fundingTxId);
    });
  });
}

/// Records every message; for each notes whether the journal already held
/// the events the reply reports.
class _Probe extends Actor {
  final InMemoryEventStore store;
  final List<dynamic> received = [];
  final Map<Object, bool> journaledAtReceipt = Map.identity();
  late ActorRef self;

  _Probe(this.store);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is TransactionSignedResponse) {
      journaledAtReceipt[message] = store.allEvents
          .whereType<TransactionSignedEvent>()
          .any((e) => e.txid == message.txid);
    } else if (message is FundingTransactionBuiltResponse) {
      journaledAtReceipt[message] = store.allEvents
          .whereType<UTXOReservedEvent>()
          .any((e) => e.reservedByTxId == message.fundingTxId);
    }
    received.add(message);
  }

  Future<T> waitFor<T>(bool Function(T) match) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      for (final m in received.whereType<T>()) {
        if (match(m)) return m;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no matching $T within 10 s; received: $received');
  }
}

/// In-memory journal whose writes can be made to fail.
class _SwitchableEventStore extends InMemoryEventStore {
  bool failPersist = false;

  /// Delay before a write lands, so a reply sent before persistence reaches
  /// the probe while the journal is still without the event.
  Duration persistDelay = Duration.zero;

  @override
  Future<void> persistEvents(
      String persistenceId, List<Event> events, int expectedVersion) async {
    if (persistDelay > Duration.zero) await Future<void>.delayed(persistDelay);
    if (failPersist) throw StateError('journal unavailable');
    await super.persistEvents(persistenceId, events, expectedVersion);
  }

  @override
  Future<void> persistEvent(
      String persistenceId, Event event, int expectedVersion) async {
    if (persistDelay > Duration.zero) await Future<void>.delayed(persistDelay);
    if (failPersist) throw StateError('journal unavailable');
    await super.persistEvent(persistenceId, event, expectedVersion);
  }
}
